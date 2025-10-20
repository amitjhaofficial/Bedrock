#!/usr/bin/env bash

set -euo pipefail

# bedrock-spend.sh
# Repeatedly invoke an Amazon Bedrock model and stop before a target USD budget.
# Requires: aws, jq, Bedrock access to the selected model.

# Required env vars (no sensible defaults – you must set these):
#   BUDGET_USD                       - Total spend cap, e.g., 500
#   PRICE_IN_USD_PER_MTOKENS         - Input price per 1,000,000 tokens (e.g., 3.00)
#   PRICE_OUT_USD_PER_MTOKENS        - Output price per 1,000,000 tokens (e.g., 15.00)
#
# Common optional vars:
#   AWS_REGION                       - Default us-east-1
#   FORCE_MODEL_ID                   - Model to use (e.g., anthropic.claude-sonnet-4-5-20250929-v1:0)
#   PROMPT                           - Text prompt for each call
#   TEMPERATURE                      - Default 0.7
#   MAX_TOKENS                       - Output cap per call (number)
#   EXHAUST_MODE                     - true/false; append instruction to use max length
#   SLEEP_SECONDS_BETWEEN_CALLS      - Default 0 (no pause)
#   SAFETY_MARGIN_USD                - Default 2.00 – stop early to avoid crossing budget

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Error: '$1' is required but not found in PATH" >&2
		exit 1
	fi
}

require aws
require jq

AWS_REGION=${AWS_REGION:-us-east-1}
FORCE_MODEL_ID=${FORCE_MODEL_ID:-}
PROMPT=${PROMPT:-"Write a long essay about the ocean and climate."}
TEMPERATURE=${TEMPERATURE:-0.7}
MAX_TOKENS=${MAX_TOKENS:-8192}
EXHAUST_MODE=${EXHAUST_MODE:-true}
SLEEP_SECONDS_BETWEEN_CALLS=${SLEEP_SECONDS_BETWEEN_CALLS:-0}
SAFETY_MARGIN_USD=${SAFETY_MARGIN_USD:-2.00}

# Required pricing/budget vars
if [[ -z "${BUDGET_USD:-}" || -z "${PRICE_IN_USD_PER_MTOKENS:-}" || -z "${PRICE_OUT_USD_PER_MTOKENS:-}" ]]; then
	echo "Set BUDGET_USD, PRICE_IN_USD_PER_MTOKENS, PRICE_OUT_USD_PER_MTOKENS." >&2
	echo "Example for Claude Sonnet 4.5 (replace with your actual rates):" >&2
	echo "BUDGET_USD=500 PRICE_IN_USD_PER_MTOKENS=3 PRICE_OUT_USD_PER_MTOKENS=15 \" >&2
	echo "AWS_REGION=us-east-1 FORCE_MODEL_ID=anthropic.claude-sonnet-4-5-20250929-v1:0 ./bedrock-spend.sh" >&2
	exit 2
fi

if [[ -z "$FORCE_MODEL_ID" ]]; then
	echo "FORCE_MODEL_ID must be set to a specific model id for accurate pricing." >&2
	exit 3
fi

echo "Region: $AWS_REGION" >&2
echo "Model:  $FORCE_MODEL_ID" >&2
echo "Budget: $BUDGET_USD USD (safety margin: $SAFETY_MARGIN_USD)" >&2
echo "Pricing: in=$PRICE_IN_USD_PER_MTOKENS/USD per 1M, out=$PRICE_OUT_USD_PER_MTOKENS/USD per 1M" >&2

# Compose prompt
FINAL_PROMPT="$PROMPT"
if [[ "${EXHAUST_MODE,,}" == "true" ]]; then
	FINAL_PROMPT+=$'\n\nGenerate as much as possible and continue until the maximum output length is reached. Do not stop early.'
fi

MESSAGES_JSON=$(jq -n \
	--arg prompt "$FINAL_PROMPT" \
	'[{
	  "role": "user",
	  "content": [ { "text": $prompt } ]
	}]')

PARAMS_JSON=$(jq -n \
	--argjson temperature "$TEMPERATURE" \
	--argjson maxTokens "$MAX_TOKENS" \
	'{
	  "temperature": $temperature,
	  "maxTokens": $maxTokens
	}')

total_input_tokens=0
total_output_tokens=0
total_usd=0
iteration=0

calc_cost() {
	local in_tokens="$1"; local out_tokens="$2"
	# USD = (tokens / 1e6) * price
	awk -v in_t="$in_tokens" -v out_t="$out_tokens" \
	    -v p_in="$PRICE_IN_USD_PER_MTOKENS" -v p_out="$PRICE_OUT_USD_PER_MTOKENS" 'BEGIN {
	      in_usd = (in_t/1000000.0) * p_in;
	      out_usd = (out_t/1000000.0) * p_out;
	      printf "%.6f\n", (in_usd + out_usd);
	    }'
}

while :; do
	iteration=$((iteration+1))
	echo "--- Iteration $iteration ---" >&2

	set +e
	RESP=$(aws bedrock-runtime converse \
		--region "$AWS_REGION" \
		--model-id "$FORCE_MODEL_ID" \
		--messages "$MESSAGES_JSON" \
		--inference-config "$PARAMS_JSON" \
		--output json 2>/dev/null)
	STATUS=$?
	set -e

	if [[ $STATUS -ne 0 || -z "$RESP" ]]; then
		echo "Converse failed; exiting." >&2
		exit 10
	fi

	in_tokens=$(echo "$RESP" | jq -r 'try .usage.inputTokens // 0')
	out_tokens=$(echo "$RESP" | jq -r 'try .usage.outputTokens // 0')
	cost=$(calc_cost "$in_tokens" "$out_tokens")
	# Predict next call at similar cost; stop if would exceed budget minus safety
	projected=$(awk -v t="$total_usd" -v c="$cost" 'BEGIN { printf "%.6f\n", t + c }')
	limit=$(awk -v b="$BUDGET_USD" -v m="$SAFETY_MARGIN_USD" 'BEGIN { printf "%.6f\n", b - m }')

	if awk -v p="$projected" -v l="$limit" 'BEGIN { exit !(p > l) }'; then
		echo "Reached budget limit (projected $projected >= $limit). Stopping." >&2
		break
	fi

	total_input_tokens=$((total_input_tokens + in_tokens))
	total_output_tokens=$((total_output_tokens + out_tokens))
	total_usd=$(awk -v t="$total_usd" -v c="$cost" 'BEGIN { printf "%.6f\n", t + c }')

	echo "This call: in_tokens=$in_tokens out_tokens=$out_tokens cost=">$cost >&2
	echo "Cumulative: in=$total_input_tokens out=$total_output_tokens spend=$total_usd USD" >&2

	# Print model text to stdout
	echo "$RESP" | jq -r 'try .output.message.content[0].text // ""'

	if [[ "$SLEEP_SECONDS_BETWEEN_CALLS" != "0" ]]; then
		sleep "$SLEEP_SECONDS_BETWEEN_CALLS"
	fi
done

echo "" >&2
echo "=== Summary ===" >&2
echo "Model:          $FORCE_MODEL_ID" >&2
echo "Calls:          $iteration" >&2
echo "Input tokens:   $total_input_tokens" >&2
echo "Output tokens:  $total_output_tokens" >&2
echo "Estimated USD:  $total_usd" >&2

exit 0


