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
  printf '%s\n' '{"object":"page","data":[{"object":"bucket","results":[]}],"has_more":false,"next_page":null}'
elif [[ "$args" == *'/v1/responses'* ]]; then
  printf '%s\n' '{"output":[{"type":"message","content":[{"type":"output_text","text":"mock answer"}]}],"usage":{"input_tokens":7,"output_tokens":3,"total_tokens":10}}'
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
out="$TMP/out" err="$TMP/err"
"$ROOT/shell/openai-quota-fuse.sh" run -m gpt-5.6-luna -o 20 'hello' >"$out" 2>"$err"
grep -Fx 'mock answer' "$out" >/dev/null
grep -F 'quota: OK (input=7 + max_output=20 => reserve=27 tokens)' "$err" >/dev/null
grep -F 'usage: input=7 output=3 total=10' "$err" >/dev/null
printf 'ok: mocked run uses official input token count and reports actual usage\n'
