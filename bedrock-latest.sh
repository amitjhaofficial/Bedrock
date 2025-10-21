#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bedrock Claude Sonnet 4 Auto-Invoker
# ---------------------------------------------------------------------------
# • Calls Anthropic Claude Sonnet 4 repeatedly.
# • Tracks monthly spend with Cost Explorer; falls back to local estimate.
# • Stops automatically at TARGET_USD or after DAYS limit.
# • Safe retries, log rotation, zero manual input.
# ---------------------------------------------------------------------------

set -euo pipefail

# ====================== CONFIG (override via env vars) =====================
TARGET_USD="${TARGET_USD:-500}"                 # stop at this spend (USD)
DAYS="${DAYS:-30}"                              # hard stop after N days
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
SLEEP_SECONDS="${SLEEP_SECONDS:-300}"           # interval between invokes (sec)
MAX_RETRIES="${MAX_RETRIES:-5}"                 # retry attempts
PROMPT_TEXT="${PROMPT_TEXT:-"Reply with the single word: OK"}"
MAX_TOKENS="${MAX_TOKENS:-64}"

# optional: pin model id (skip discovery)
MODEL_ID="${MODEL_ID:-}"

# Fallback cost estimation when CE unavailable
ESTIMATE_UNTIL_CE="${ESTIMATE_UNTIL_CE:-1}"     # 1=enable fallback
PRICE_IN_PER_1K="${PRICE_IN_PER_1K:-0.003}"     # USD per 1K input tokens
PRICE_OUT_PER_1K="${PRICE_OUT_PER_1K:-0.015}"   # USD per 1K output tokens
ESTIMATE_USD_PER_CALL="${ESTIMATE_USD_PER_CALL:-0}"  # used if token data missing

# Logging
LOGDIR="${LOGDIR:-$HOME/bedrock-sonnet-logs}"
LOGFILE="$LOGDIR/run.log"
MAX_LOG_SIZE_BYTES="${MAX_LOG_SIZE_BYTES:-5242880}"   # 5 MB
# ===========================================================================

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
  banner "Checking dependencies"
  command -v aws >/dev/null || die "AWS CLI not found"
  command -v jq  >/dev/null || die "jq not found"
  aws sts get-caller-identity >/dev/null || die "AWS credentials invalid"
  log "Region: $REGION | Target: \$$TARGET_USD | Interval: ${SLEEP_SECONDS}s"
}

init_estimate_store(){
  [[ -f "$LOGDIR/estimate.json" ]] || echo '{"accumulated":0}' > "$LOGDIR/estimate.json"
}

add_estimated_cost(){
  local in_toks="${1:-0}" out_toks="${2:-0}"
  local pin="$PRICE_IN_PER_1K" pout="$PRICE_OUT_PER_1K" flat="$ESTIMATE_USD_PER_CALL"
  local cost
  if [[ "$pin" != "0" || "$pout" != "0" ]]; then
    cost=$(awk -v i="$in_toks" -v o="$out_toks" -v pin="$pin" -v pout="$pout" \
           'BEGIN{printf "%.10f",(i/1000.0)*pin + (o/1000.0)*pout}')
  else
    cost="$flat"
  fi
  init_estimate_store
  local curr next
  curr="$(jq -r '.accumulated // 0' "$LOGDIR/estimate.json")"
  next="$(awk -v a="$curr" -v b="$cost" 'BEGIN{printf "%.10f", a + b}')"
  jq --argjson v "$next" '.accumulated=$v' "$LOGDIR/estimate.json" \
      > "$LOGDIR/estimate.json.tmp" && mv "$LOGDIR/estimate.json.tmp" "$LOGDIR/estimate.json"
  log "Estimated cost +\$${cost} (tokens in=$in_toks out=$out_toks) → total ≈ \$${next}"
}

discover_model_id(){
  aws bedrock list-foundation-models --region "$REGION" --output json \
  | jq -r '
      .modelSummaries[]
      | select(.providerName|test("(?i)anthropic"))
      | select(.modelName|test("(?i)sonnet"))
      | .modelId' | head -n1
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
  else
    if [[ "$ESTIMATE_UNTIL_CE" == "1" ]]; then
      jq -r '.accumulated // 0' "$LOGDIR/estimate.json" 2>/dev/null || echo "0"
    else
      echo "$OUT" >&2
      return 1
    fi
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
  [[ -n "$MODEL_ID" ]] || MODEL_ID="$(discover_model_id || true)"
  [[ -n "$MODEL_ID" ]] || die "Claude Sonnet model not found in region $REGION."
  log "Using model: $MODEL_ID"

  local start_ts deadline_ts now COST attempt OUT
  start_ts=$(date +%s)
  deadline_ts=$(( start_ts + DAYS*24*3600 ))

  while : ; do
    rotate_logs
    COST="$(current_bedrock_cost_usd)"
    log "Current month Bedrock cost (real or estimate): \$${COST}"

    # stop when cost >= target
    awk -v c="$COST" -v t="$TARGET_USD" 'BEGIN{exit !(c>=t)}' && {
      log "Target reached (>= \$${TARGET_USD}). Stopping."
      break
    }

    now=$(date +%s)
    (( now >= deadline_ts )) && { log "Reached ${DAYS}-day window. Exiting."; break; }

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
    (( attempt > MAX_RETRIES )) && log "Max retries reached; continuing loop."

    sleep "$SLEEP_SECONDS"
  done

  banner "Done"
}

main "$@"
