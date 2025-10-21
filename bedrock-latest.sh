#!/usr/bin/env bash
# Purpose: Unattended Bedrock invokes of Anthropic Claude Sonnet 4 until monthly target is hit.
# - Uses real spend from Cost Explorer (CE). If CE unavailable, falls back to local estimate.
# - Auto-stops at TARGET_USD or after DAYS.
# - Safe retries, log rotation.

set -euo pipefail

########################## CONFIG (env-overridable) ##########################
TARGET_USD="${TARGET_USD:-500}"                    # Stop when spend >= this (USD)
DAYS="${DAYS:-30}"                                 # Hard stop after N days
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

SLEEP_SECONDS="${SLEEP_SECONDS:-300}"              # Interval between invokes
MAX_RETRIES="${MAX_RETRIES:-5}"                    # Invoke retries w/ backoff

# Prompt & tokens (keep small to control cost)
PROMPT_TEXT="${PROMPT_TEXT:-"Reply with the single word: OK"}"
MAX_TOKENS="${MAX_TOKENS:-64}"

# Optional: pin a model ID to skip discovery
MODEL_ID="${MODEL_ID:-}"

# Fallback estimation when CE is unavailable
ESTIMATE_UNTIL_CE="${ESTIMATE_UNTIL_CE:-1}"        # 1=enable fallback, 0=disable
PRICE_IN_PER_1K="${PRICE_IN_PER_1K:-0}"            # e.g., 0.003  (USD per 1K)
PRICE_OUT_PER_1K="${PRICE_OUT_PER_1K:-0}"          # e.g., 0.015  (USD per 1K)
ESTIMATE_USD_PER_CALL="${ESTIMATE_USD_PER_CALL:-0}"# Used if usage tokens unavailable

# Logging
LOGDIR="${LOGDIR:-$HOME/bedrock-sonnet-logs}"
LOGFILE="$LOGDIR/run.log"
MAX_LOG_SIZE_BYTES="${MAX_LOG_SIZE_BYTES:-5242880}" # 5 MB
###############################################################################

banner(){ printf "\n========== %s ==========\n" "$*"; }
log(){ printf "[%s] %s\n" "$(date -Is)" "$*" | tee -a "$LOGFILE"; }
die(){ log "ERROR: $*"; exit 1; }
rotate_logs(){
  if [[ -f "$LOGFILE" ]] && (( $(wc -c < "$LOGFILE") > MAX_LOG_SIZE_BYTES )); then
    mv "$LOGFILE" "${LOGFILE}.$(date +%Y%m%d-%H%M%S)"
    : > "$LOGFILE"
    log "Rotated logs."
  fi
}

ensure_setup(){
  mkdir -p "$LOGDIR"
  : > "$LOGFILE"
  banner "Checking deps & creds"
  command -v aws >/dev/null || die "aws CLI not found"
  command -v jq  >/dev/null || die "jq not found"
  aws sts get-caller-identity >/dev/null || die "AWS credentials invalid"
  log "Region: $REGION | Target: \$$TARGET_USD | Sleep: ${SLEEP_SECONDS}s"
}

init_estimate_store(){
  [[ -f "$LOGDIR/estimate.json" ]] || echo '{"accumulated":0}' > "$LOGDIR/estimate.json"
}

add_estimated_cost(){
  # args: input_tokens output_tokens
  local in_toks="${1:-0}" out_toks="${2:-0}"
  local pin="$PRICE_IN_PER_1K" pout="$PRICE_OUT_PER_1K" flat="$ESTIMATE_USD_PER_CALL"
  local cost="0"

  # If pricing provided, use token-based; else flat per-call
  if [[ "$pin" != "0" || "$pout" != "0" ]]; then
    # cost=(in/1000)*pin + (out/1000)*pout  (use awk for float math)
    cost="$(awk -v i="$in_toks" -v o="$out_toks" -v pin="$pin" -v pout="$pout" 'BEGIN{printf "%.10f",(i/1000.0)*pin + (o/1000.0)*pout}')"
  else
    cost="$flat"
  fi

  init_estimate_store
  local curr next
  curr="$(jq -r '.accumulated // 0' "$LOGDIR/estimate.json")"
  next="$(awk -v a="$curr" -v b="$cost" 'BEGIN{printf "%.10f", a + b}')"
  jq --argjson v "$next" '.accumulated=$v' "$LOGDIR/estimate.json" > "$LOGDIR/estimate.json.tmp" && mv "$LOGDIR/estimate.json.tmp" "$LOGDIR/estimate.json"
  log "Estimated cost +\$${cost} (tokens in=$in_toks out=$out_toks) → total ≈ \$${next}"
}

discover_model_id(){
  aws bedrock list-foundation-models --region "$REGION" --output json \
  | jq -r '
      .modelSummaries[]
      | select(.providerName|test("(?i)anthropic"))
      | select(.modelName|test("(?i)sonnet"))
      | .modelId
    ' | head -n1
}

current_bedrock_cost_usd(){
  local start end
  start="$(date -u +%Y-%m-01)"
  end="$(date -u -d "$start +1 month" +%Y-%m-01)"
  if OUT=$(aws ce get-cost-and-usage \
        --region us-east-1 \
        --time-period Start="$start",End="$end" \
        --granularity MONTHLY \
        --metrics UnblendedCost \
        --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}' \
        --output json 2>&1); then
    echo "$OUT" | jq -r '.ResultsByTime[0].Total.UnblendedCost.Amount // "0"'
    return 0
  else
    if [[ "$ESTIMATE_UNTIL_CE" == "1" ]]; then
      jq -r '.accumulated // 0 | tostring' "$LOGDIR/estimate.json" 2>/dev/null || echo "0"
      return 0
    fi
    echo "$OUT" >&2
    return 1
  fi
}

invoke_once(){
  local model_id="$1"
  local body resp
  body=$(jq -n \
    --arg anthv "bedrock-2023-05-31" \
    --arg prompt "$PROMPT_TEXT" \
    --argjson max "$MAX_TOKENS" \
    '{
      "anthropic_version": $anthv,
      "max_tokens": $max,
      "messages":[{"role":"user","content":[{"type":"text","text":$prompt}]}]
    }')

  resp=$(aws bedrock-runtime invoke-model \
            --region "$REGION" \
            --model-id "$model_id" \
            --body "$body" \
            --cli-binary-format raw-in-base64-out \
            --output json)

  # When estimating, add cost using usage tokens if present
  if [[ "$ESTIMATE_UNTIL_CE" == "1" ]]; then
    local in_toks out_toks
    in_toks=$(echo "$resp" | jq -r '.usage.input_tokens // .usage.inputTokens // 0')
    out_toks=$(echo "$resp" | jq -r '.usage.output_tokens // .usage.outputTokens // 0')
    add_estimated_cost "${in_toks:-0}" "${out_toks:-0}"
  fi

  echo "$resp"
}

main(){
  ensure_setup
  init_estimate_store

  banner "Discovering Anthropic Sonnet model"
  if [[ -z "$MODEL_ID" ]]; then
    MODEL_ID="$(discover_model_id || true)"
  fi
  [[ -n "$MODEL_ID" ]] || die "Could not find an Anthropic Sonnet model in region $REGION. Ensure access or set MODEL_ID env var."

  log "Using model: $MODEL_ID"

  local start_ts deadline_ts now attempt OUT COST
  start_ts=$(date +%s)
  deadline_ts=$(( start_ts + DAYS*24*3600 ))

  while : ; do
    rotate_logs

    # 1) Check spend
    COST="$(current_bedrock_cost_usd)"
    log "Current month Bedrock cost (real or estimate): \$${COST}"

    # Stop if cost >= target (decimal compare via awk)
    awk -v c="$COST" -v t="$TARGET_USD" 'BEGIN{exit !(c>=t)}' && {
      log "Target reached (>= \$${TARGET_USD}). Stopping."
      break
    }

    # 2) Time cutoff
    now=$(date +%s)
    if (( now >= deadline_ts )); then
      log "Reached DAYS=${DAYS} window. Stopping."
      break
    }

    # 3) Invoke with retry/backoff
    attempt=0
    until (( attempt > MAX_RETRIES )); do
      if OUT="$(invoke_once "$MODEL_ID" 2>&1)"; then
        log "Invoke OK"
        break
      else
        log "Invoke failed (attempt $((attempt+1))/$MAX_RETRIES): $OUT"
        sleep $(( 2**attempt < 60 ? 2**attempt : 60 ))
        ((attempt++))
      fi
    done
    if (( attempt > MAX_RETRIES )); then
      log "Give up after $MAX_RETRIES retries; continuing loop."
    fi

    sleep "$SLEEP_SECONDS"
  done

  banner "Done"
}

main "$@"
