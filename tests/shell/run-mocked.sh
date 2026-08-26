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
if [[ "$args" == *'/responses/input_tokens'* ]]; then
  printf '%s\n' '{"object":"response.input_tokens","input_tokens":7}'
elif [[ "$args" == *'/organization/usage/completions'* ]]; then
  if [[ "${MOCK_USAGE_EXHAUSTED:-0}" == 1 ]]; then
    printf '%s\n' '{"object":"page","data":[{"object":"bucket","results":[{"model":"gpt-5.6-luna","input_tokens":2500000,"output_tokens":0},{"model":"gpt-5.6-sol","input_tokens":250000,"output_tokens":0}]}],"has_more":false,"next_page":null}'
  else
    printf '%s\n' '{"object":"page","data":[{"object":"bucket","results":[]}],"has_more":false,"next_page":null}'
  fi
elif [[ "$args" == *'/v1/responses'* ]]; then
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

out="$TMP/out" err="$TMP/err"
"$ROOT/shell/openai-quota-fuse.sh" run -m gpt-5.6-luna -o 20 -i 'hello' >"$out" 2>"$err"
grep -Fx 'mock answer' "$out" >/dev/null
grep -F 'quota: OK (input=7 + max_output=20 => reserve=27 tokens)' "$err" >/dev/null
grep -F 'usage: input=7 output=3 total=10' "$err" >/dev/null

printf 'hello from stdin' | "$ROOT/shell/openai-quota-fuse.sh" run -m gpt-5.6-luna -o 20 >"$out" 2>"$err"
grep -Fx 'mock answer' "$out" >/dev/null

"$ROOT/shell/openai-quota-fuse.sh" run -r -m gpt-5.6-luna -o 20 -i 'raw' >"$out" 2>"$err"
jq -e '.id == "resp_mock" and .usage.total_tokens == 10' "$out" >/dev/null

export MOCK_USAGE_EXHAUSTED=1
"$ROOT/shell/openai-quota-fuse.sh" run -q low -o 20 -i 'paid' >"$out" 2>"$err"
grep -Fx 'mock answer' "$out" >/dev/null
grep -F 'paid fallback reserved' "$err" >/dev/null
grep -F 'model: gpt-5.6-luna' "$err" >/dev/null
jq -e '[.events[].usd] | add > 0 and add < 5' "$OPENAI_QUOTA_FUSE_PAID_LEDGER" >/dev/null

export OPENAI_ANNUAL_PAID_BUDGET_USD=0
if "$ROOT/shell/openai-quota-fuse.sh" run -q low -o 20 -i 'blocked' >"$out" 2>"$err"; then
  echo 'expected zero paid budget to block fallback' >&2
  exit 1
fi
grep -F 'paid fallback blocked' "$err" >/dev/null

printf 'ok: mocked run covers input/stdin/raw and hard-capped paid fallback\n'
