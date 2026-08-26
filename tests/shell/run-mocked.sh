#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
[[ -n "${MOCK_CURL_LOG:-}" ]] && printf '%s\n' "$args" >>"$MOCK_CURL_LOG"
if [[ "$args" == *'/responses/input_tokens'* ]]; then
  printf '%s\n' '{"object":"response.input_tokens","input_tokens":7}'
elif [[ "$args" == *'/organization/usage/completions'* ]]; then
  if [[ "${MOCK_USAGE_EXHAUSTED:-0}" == 1 ]]; then
    printf '%s\n' '{"object":"page","data":[{"object":"bucket","results":[{"model":"gpt-5.6-luna","input_tokens":2500000,"output_tokens":0},{"model":"gpt-5.6-sol","input_tokens":250000,"output_tokens":0}]}],"has_more":false,"next_page":null}'
  else
    printf '%s\n' '{"object":"page","data":[{"object":"bucket","results":[]}],"has_more":false,"next_page":null}'
  fi
elif [[ "$args" == *'/organization/costs'* ]]; then
  printf '%s\n' "{\"object\":\"page\",\"data\":[{\"object\":\"bucket\",\"results\":[{\"object\":\"organization.costs.result\",\"amount\":{\"value\":${MOCK_OFFICIAL_COSTS_USD:-0},\"currency\":\"usd\"}}]}],\"has_more\":false,\"next_page\":null}"
elif [[ "$args" == *'/v1/responses'* ]]; then
  if [[ "$args" == *'Classify the user'"'"'s task difficulty for model routing'* ]]; then
    result="${MOCK_CLASSIFIER_RESULT:-low}"
    printf '%s\n' "{\"id\":\"resp_classifier\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"$result\"}]}],\"usage\":{\"input_tokens\":7,\"output_tokens\":1,\"total_tokens\":8}}"
    exit 0
  fi
  if [[ "${MOCK_EXPECT_EFFORT:-}" != "" && "$args" != *"\"effort\": \"${MOCK_EXPECT_EFFORT}\""* && "$args" != *"\"effort\":\"${MOCK_EXPECT_EFFORT}\""* ]]; then
    echo "expected reasoning effort ${MOCK_EXPECT_EFFORT}; args=$args" >&2
    exit 91
  fi
  printf '%s\n' '{"id":"resp_mock","output":[{"type":"message","content":[{"type":"output_text","text":"mock answer"}]}],"usage":{"input_tokens":7,"output_tokens":3,"total_tokens":10}}'
else
  echo "unexpected curl call: $args" >&2
  exit 90
fi
MOCK
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export OPENAI_ADMIN_KEY=test-admin
export OPENAI_API_KEY=test-api
export OPENAI_USAGE_TIER=1
export OPENAI_QUOTA_RESERVE_PERCENT=0
export OPENAI_ANNUAL_PAID_BUDGET_USD=5
export OPENAI_QUOTA_FUSE_PAID_LEDGER="$TMP/paid.json"
export MOCK_CURL_LOG="$TMP/curl.log"

out="$TMP/out" err="$TMP/err"
export MOCK_EXPECT_EFFORT=high
"$ROOT/shell/openai-quota-fuse.sh" run -e high -m gpt-5.6-luna -o 20 -i 'hello' >"$out" 2>"$err"
grep -Fx 'mock answer' "$out" >/dev/null
grep -F 'quota: OK (input=7 + max_output=20 => reserve=27 tokens)' "$err" >/dev/null
grep -F 'reasoning effort: high' "$err" >/dev/null
grep -F 'usage: input=7 output=3 total=10' "$err" >/dev/null
if grep -F 'Classify the user' "$MOCK_CURL_LOG" >/dev/null; then
  echo 'explicit model must bypass auto quality classifier' >&2
  exit 1
fi
unset MOCK_EXPECT_EFFORT

: >"$MOCK_CURL_LOG"
export MOCK_CLASSIFIER_RESULT=high
"$ROOT/shell/openai-quota-fuse.sh" run -o 20 -i 'design and implement a multi-step repository refactor' >"$out" 2>"$err"
grep -Fx 'mock answer' "$out" >/dev/null
grep -F 'quality: auto -> high' "$err" >/dev/null
grep -F 'classifier: gpt-5.6-luna' "$err" >/dev/null
grep -F 'model: gpt-5.6-sol' "$err" >/dev/null
grep -F 'Classify the user' "$MOCK_CURL_LOG" >/dev/null
unset MOCK_CLASSIFIER_RESULT

: >"$MOCK_CURL_LOG"
"$ROOT/shell/openai-quota-fuse.sh" run -q low -o 20 -i 'explicit low' >"$out" 2>"$err"
grep -F 'model: gpt-5.6-terra' "$err" >/dev/null
if grep -F 'Classify the user' "$MOCK_CURL_LOG" >/dev/null; then
  echo 'explicit quality must bypass auto quality classifier' >&2
  exit 1
fi

printf 'hello from stdin' | "$ROOT/shell/openai-quota-fuse.sh" run -m gpt-5.6-luna -o 20 >"$out" 2>"$err"
grep -Fx 'mock answer' "$out" >/dev/null

"$ROOT/shell/openai-quota-fuse.sh" run -r -m gpt-5.6-luna -o 20 -i 'raw' >"$out" 2>"$err"
jq -e '.id == "resp_mock" and .usage.total_tokens == 10' "$out" >/dev/null

export MOCK_OFFICIAL_COSTS_USD=0.25
"$ROOT/shell/openai-quota-fuse.sh" costs >"$out" 2>"$err"
grep -Fx 'official_costs_usd=0.25' "$out" >/dev/null
grep -Fx 'effective_budget_spend_usd=0.25' "$out" >/dev/null

export MOCK_USAGE_EXHAUSTED=1
export MOCK_EXPECT_EFFORT=low
"$ROOT/shell/openai-quota-fuse.sh" run -e low -q low -o 20 -i 'paid' >"$out" 2>"$err"
grep -Fx 'mock answer' "$out" >/dev/null
grep -F 'paid fallback reserved' "$err" >/dev/null
grep -F 'model: gpt-5.6-luna' "$err" >/dev/null
grep -F 'reasoning effort: low' "$err" >/dev/null
jq -e '.schema_version == 2 and (.requests | length == 1) and .requests[0].state == "completed" and .requests[0].actual_usd > 0' "$OPENAI_QUOTA_FUSE_PAID_LEDGER" >/dev/null
unset MOCK_EXPECT_EFFORT

rm -f "$OPENAI_QUOTA_FUSE_PAID_LEDGER"
export MOCK_OFFICIAL_COSTS_USD=4.99999
export OPENAI_ANNUAL_PAID_BUDGET_USD=5
if "$ROOT/shell/openai-quota-fuse.sh" run -q low -o 20 -i 'blocked by direct spend' >"$out" 2>"$err"; then
  echo 'expected Costs API spend to block paid fallback' >&2
  exit 1
fi
grep -F 'paid fallback blocked' "$err" >/dev/null

export MOCK_OFFICIAL_COSTS_USD=0
export OPENAI_ANNUAL_PAID_BUDGET_USD=0
if "$ROOT/shell/openai-quota-fuse.sh" run -q low -o 20 -i 'blocked' >"$out" 2>"$err"; then
  echo 'expected zero paid budget to block fallback' >&2
  exit 1
fi
grep -F 'paid fallback blocked' "$err" >/dev/null

printf 'ok: mocked run covers auto quality, explicit overrides, effort, input/stdin/raw, Costs API, and hard-capped paid fallback\n'
