#!/usr/bin/env bash

set -euo pipefail

# bedrock-latest.sh
# Auto-selects a recent available Amazon Bedrock text model and runs a sample prompt
# Works well in AWS CloudShell (aws + jq are preinstalled). Requires Bedrock access in the region.

# Configurable via env vars:
#   AWS_REGION                - AWS region (defaults to current CLI config or us-east-1)
#   PREFERRED_PROVIDERS       - Comma-separated priority list (default: Anthropic,Mistral,Amazon,Meta,Cohere,AI21)
#   INFERENCE_TYPE            - on-demand or provisioned (default: on-demand)
#   PROMPT                    - Prompt to send (default: "Write a short haiku about the ocean.")
#   TEMPERATURE               - Temperature for sampling (used by converse) (default: 0.7)
#   MAX_TOKENS                - Max output tokens: number or 'auto' to infer
#   EXHAUST_MODE              - If 'true', encourage maximum-length output

AWS_REGION=${AWS_REGION:-$(aws configure get region || true)}
AWS_REGION=${AWS_REGION:-us-east-1}
PREFERRED_PROVIDERS=${PREFERRED_PROVIDERS:-Anthropic,Mistral,Amazon,Meta,Cohere,AI21}
INFERENCE_TYPE=${INFERENCE_TYPE:-on-demand}
PROMPT=${PROMPT:-"Write a short haiku about the ocean."}
TEMPERATURE=${TEMPERATURE:-0.7}
MAX_TOKENS=${MAX_TOKENS:-auto}
EXHAUST_MODE=${EXHAUST_MODE:-false}

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Error: '$1' is required but not found in PATH" >&2
		exit 1
	fi
}

require aws
require jq

echo "Using region: $AWS_REGION" >&2

# Fetch active text-capable models from Bedrock control plane
echo "Discovering Bedrock text models (inference: $INFERENCE_TYPE)..." >&2
MODEL_LIST_JSON=$(aws bedrock list-foundation-models \
	--region "$AWS_REGION" \
	--output json 2>/dev/null || true)

if [[ -z "$MODEL_LIST_JSON" || "$MODEL_LIST_JSON" == "null" ]]; then
	echo "Error: Unable to list Bedrock foundation models. Ensure your account has Bedrock access in $AWS_REGION." >&2
	exit 2
fi

# Filter models:
# - ACTIVE lifecycle
# - Supports TEXT output
# - Supports chosen inference type (ON_DEMAND or PROVISIONED)
# Normalize inference type to Bedrock's enum values
if [[ "$INFERENCE_TYPE" =~ ^(?i:on[\-_]?demand)$ ]]; then
	INFERENCE_ENUM="ON_DEMAND"
else
	INFERENCE_ENUM="PROVISIONED"
fi

FILTERED=$(echo "$MODEL_LIST_JSON" | jq \
	--arg inft "$INFERENCE_ENUM" \
	'(
		.modelSummaries // []
	) 
	| map(select((.modelLifecycle.status // "") == "ACTIVE")) 
	| map(select(((.outputModalities // []) | index("TEXT")) != null))
	| map(select(((.inferenceTypesSupported // []) | index($inft)) != null))
	| map({modelId, modelName, providerName, inputModalities, outputModalities})'
)

if [[ $(echo "$FILTERED" | jq 'length') -eq 0 ]]; then
	echo "No ACTIVE text models supporting $INFERENCE_ENUM found in $AWS_REGION." >&2
	echo "Tip: Try another region (e.g., us-east-1) or enable additional model access in the Bedrock console." >&2
	exit 3
fi

# Provider priority selection
IFS=',' read -r -a PROVIDER_PRIORITY <<< "$PREFERRED_PROVIDERS"

BEST_MODEL_JSON=""
for provider in "${PROVIDER_PRIORITY[@]}"; do
	CANDIDATE=$(echo "$FILTERED" | jq --arg p "$provider" \
		'sort_by(.modelId) | reverse | map(select((.providerName // "") == $p)) | .[0]')
	if [[ "$CANDIDATE" != "null" && -n "$CANDIDATE" ]]; then
		BEST_MODEL_JSON="$CANDIDATE"
		break
	fi
done

# If none matched preferred providers, pick the first by modelId desc
if [[ -z "$BEST_MODEL_JSON" || "$BEST_MODEL_JSON" == "null" ]]; then
	BEST_MODEL_JSON=$(echo "$FILTERED" | jq 'sort_by(.modelId) | reverse | .[0]')
fi

MODEL_ID=$(echo "$BEST_MODEL_JSON" | jq -r '.modelId')
MODEL_PROVIDER=$(echo "$BEST_MODEL_JSON" | jq -r '.providerName')
MODEL_NAME=$(echo "$BEST_MODEL_JSON" | jq -r '.modelName')

if [[ -z "$MODEL_ID" || "$MODEL_ID" == "null" ]]; then
	echo "Failed to select a model." >&2
	echo "Candidates were:" >&2
	echo "$FILTERED" | jq -r '.[].modelId' >&2
	exit 4
fi

echo "Selected model: $MODEL_ID ($MODEL_PROVIDER - $MODEL_NAME)" >&2

# Resolve max tokens
resolve_max_tokens() {
	local provider="$1"
	local desired="$2"
	if [[ "$desired" =~ ^[0-9]+$ ]]; then
		printf "%s" "$desired"
		return 0
	fi
	# Heuristic defaults by provider (conservative)
	case "$provider" in
		Anthropic)
			printf "8192";;
		Mistral)
			printf "4096";;
		Amazon)
			printf "8192";;
		Meta)
			printf "8192";;
		Cohere)
			printf "4096";;
		AI21)
			printf "2048";;
		*)
			printf "2048";;
	 esac
}

RESOLVED_MAX_TOKENS=$(resolve_max_tokens "$MODEL_PROVIDER" "$MAX_TOKENS")
echo "Using maxTokens: $RESOLVED_MAX_TOKENS" >&2

# Optionally amplify prompt to exhaust output length
FINAL_PROMPT="$PROMPT"
if [[ "${EXHAUST_MODE,,}" == "true" ]]; then
	FINAL_PROMPT+=$'\n\nGenerate the most comprehensive answer possible and continue until the maximum output length is reached. Do not stop early.'
fi

# Build Converse messages payload
MESSAGES_JSON=$(jq -n \
	--arg prompt "$FINAL_PROMPT" \
	'[{
	  "role": "user",
	  "content": [ { "text": $prompt } ]
	}]')

# Some models may require a guardrail or system prompt; omitted by default.

PARAMS_JSON=$(jq -n \
	--argjson temperature "$TEMPERATURE" \
	--argjson maxTokens "$RESOLVED_MAX_TOKENS" \
	'{
	  "temperature": $temperature,
	  "maxTokens": $maxTokens
	}')

echo "Invoking with Bedrock Converse API..." >&2

set +e
RAW_RESPONSE=$(aws bedrock-runtime converse \
	--region "$AWS_REGION" \
	--model-id "$MODEL_ID" \
	--messages "$MESSAGES_JSON" \
	--inference-config "$PARAMS_JSON" \
	--output json 2>/dev/null)
STATUS=$?
set -e

if [[ $STATUS -ne 0 || -z "$RAW_RESPONSE" ]]; then
	echo "Converse API failed or is unsupported for this model. Attempting fallback invocation..." >&2
	# Minimal generic fallback via invoke-model using an Anthropic-compatible body.
	# This will work for Anthropic models; for others, prefer adjusting to provider schema.
	FALLBACK_BODY=$(jq -n \
		--arg prompt "$FINAL_PROMPT" \
		--argjson max_tokens "$RESOLVED_MAX_TOKENS" \
		--argjson temperature "$TEMPERATURE" \
		'{
		  "anthropic_version": "bedrock-2023-05-31",
		  "max_tokens": $max_tokens,
		  "temperature": $temperature,
		  "messages": [ { "role": "user", "content": [ { "type": "text", "text": $prompt } ] } ]
		}')

	set +e
	RAW_RESPONSE=$(aws bedrock-runtime invoke-model \
		--region "$AWS_REGION" \
		--model-id "$MODEL_ID" \
		--content-type application/json \
		--accept application/json \
		--body "$FALLBACK_BODY" \
		--output json 2>/dev/null)
	STATUS=$?
	set -e

	if [[ $STATUS -ne 0 || -z "$RAW_RESPONSE" ]]; then
		echo "Invocation failed. Verify model access permissions and region, or try a different provider/region." >&2
		exit 5
	fi

	# Try to extract text from common Anthropic response shape
	TEXT=$(echo "$RAW_RESPONSE" | jq -r 'try (.content[0].text) // try (.output_text) // try (.results[0].outputText) // .')
else
	# Extract text from Converse response
	TEXT=$(echo "$RAW_RESPONSE" | jq -r 'try (.output.message.content[0].text) // try (.output_text) // .')
fi

echo "" >&2
echo "=== Model Response (model: $MODEL_ID) ===" >&2
echo "$TEXT"

exit 0


