#!/usr/bin/env bash
set -euo pipefail

########################## CONFIG ##########################
# Target budget for THIS month (USD). Script stops when cost >= this.
TARGET_USD="${TARGET_USD:-500}"

# Max runtime window (days). Acts as safety cutoff.
DAYS="${DAYS:-30}"

# Where to run
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# How aggressively to invoke (tune to control spend rate)
SLEEP_SECONDS="${SLEEP_SECONDS:-300}"           # 1 call / 5 minutes by default
MAX_RETRIES="${MAX_RETRIES:-5}"

# Prompt to send each call (keep simple; tokens = cost)
PROMPT_TEXT="${PROMPT_TEXT:-"Reply with the single word: OK"}"
MAX_TOKENS="${MAX_TOKENS:-64}"                  # model output cap

# Logging
LOGDIR="${LOGDIR:-$HOME/bedrock-sonnet-logs}"
LOGFILE="$LOGDIR/run.log"
MAX_LOG_SIZE_BYTES="${MAX_LOG_SIZE_BYTES:-5242880}"  # 5 MB
############################################################

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

# Find latest Anthropic Sonnet model ID in Bedrock
discover_model_id(){
  aws bedrock list-foundation-models --region "$REGION" --output json \
  | jq -r '
      .modelSummaries[]
      | select(.providerName|test("(?i)anthropic"))
      | select(.modelName|test("(?i)sonnet"))
      | .modelId
    ' \
  | head -n1
}

# Cost Explorer: this month’s Amazon Bedrock cost (USD)
current_bedrock_cost_usd(){
  local start end
  start="$(date -u +%Y-%m-01)"
  end="$(date -u -d "$start +1 month" +%Y-%m-01)"
  aws ce get-cost-and-usage \
    --region us-east-1 \
    --time-period Start="$start",End="$end" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}' \
    --output json \
  | jq -r '.ResultsByTime[0].Total.UnblendedCost.Amount // "0"'
}

invoke_once(){
  local model_id="$1"
  local body
  body=$(jq -n \
    --arg anthv "bedrock-2023-05-31" \
    --arg prompt "$PROMPT_TEXT" \
    --argjson max "$MAX_TOKENS" \
    '{
      "anthropic_version": $anthv,
      "max_tokens": $max,
      "messages":[{"role":"user","content":[{"type":"text","text":$prompt}]}]
    }')
  aws bedrock-runtime invoke-model \
      --region "$REGION" \
      --model-id "$model_id" \
      --body "$body" \
      --cli-binary-format raw-in-base64-out \
      --output json
}

main(){
  ensure_setup
  banner "Discovering Anthropic Sonnet model"
  MODEL_ID="$(discover_model_id || true)"
  if [[ -z "${MODEL_ID:-}" ]]; then
    die "Could not find an Anthropic Sonnet model in this region. Enable access or choose another region."
  fi
  log "Using model: $MODEL_ID"

  local start_ts deadline_ts
  start_ts=$(date +%s)
  deadline_ts=$(( start_ts + DAYS*24*3600 ))

  while : ; do
    rotate_logs
    # 1) Check spend
    COST="$(current_bedrock_cost_usd)"
    log "Current month Bedrock cost: \$${COST}"
    # numeric compare (handle decimals)
    awk -v c="$COST" -v t="$TARGET_USD" 'BEGIN{exit !(c>=t)}' && {
      log "Target reached (>= \$${TARGET_USD}). Stopping."
      break
    }

    # 2) Check deadline
    now=$(date +%s)
    if (( now >= deadline_ts )); then
      log "Reached DAYS=${DAYS} window. Stopping."
      break
    fi

    # 3) Invoke with retry/backoff
    attempt=0
    until (( attempt > MAX_RETRIES )); do
      if OUT="$(invoke_once "$MODEL_ID" 2>&1)"; then
        # Optionally parse usage tokens if the provider returns them
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
