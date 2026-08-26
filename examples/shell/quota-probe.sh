#!/usr/bin/env bash
set -euo pipefail

MODEL="${MODEL:-gpt-5.6-luna}"
INPUT="${INPUT:-Reply with exactly: quota probe ok}"
RESPONSE_FILE="$(mktemp)"

cleanup() {
  rm -f "$RESPONSE_FILE"
}
trap cleanup EXIT

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${OPENAI_ADMIN_KEY:?OPENAI_ADMIN_KEY is required}"
: "${OPENAI_API_KEY:?OPENAI_API_KEY is required}"

echo "== before =="
./shell/openai-quota-fuse.sh status --raw

echo
echo "== probe request: $MODEL =="

request_body="$(
  jq -n \
    --arg model "$MODEL" \
    --arg input "$INPUT" \
    '{
      model: $model,
      input: $input,
      reasoning: {
        effort: "none"
      },
      max_output_tokens: 32
    }'
)"

http_code="$(
  curl \
    --silent \
    --show-error \
    --output "$RESPONSE_FILE" \
    --write-out '%{http_code}' \
    https://api.openai.com/v1/responses \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$request_body"
)"

echo "HTTP $http_code"

if jq empty "$RESPONSE_FILE" >/dev/null 2>&1; then
  jq . "$RESPONSE_FILE"
else
  cat "$RESPONSE_FILE"
  echo
fi

if [[ "$http_code" != 2* ]]; then
  echo
  echo "Probe failed. Check the error body above."
  exit 1
fi

echo
echo "== response summary =="

jq '{
  id,
  model,
  status,
  output_text,
  usage
}' "$RESPONSE_FILE"

echo
echo "== after =="
./shell/openai-quota-fuse.sh status --raw
