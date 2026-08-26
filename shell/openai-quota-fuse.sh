#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.1.0-dev"
readonly USAGE_URL="https://api.openai.com/v1/organization/usage/completions"

# Current complimentary-token eligibility groups published by OpenAI.
# Keep in sync with spec/QUOTA_POLICY.md and the OpenAI data-sharing incentive docs.
readonly LARGE_MODELS=$'gpt-5.6-sol\ngpt-5.5-2026-04-23\ngpt-5.4-2026-03-05\ngpt-5.2-2025-12-11\ngpt-5.1-2025-11-13\ngpt-5.1-codex\ngpt-5-codex\ngpt-5-2025-08-07\ngpt-5-chat-latest\ngpt-4.1-2025-04-14\ngpt-4o-2024-05-13\ngpt-4o-2024-08-06\ngpt-4o-2024-11-20\no3-2025-04-16\no1-preview-2024-09-12\no1-2024-12-17'
readonly SMALL_MODELS=$'gpt-5.6-terra\ngpt-5.6-luna\ngpt-5.4-mini-2026-03-17\ngpt-5.4-nano-2026-03-17\ngpt-5.1-codex-mini\ngpt-5-mini-2025-08-07\ngpt-5-nano-2025-08-07\ngpt-4.1-mini-2025-04-14\ngpt-4.1-nano-2025-04-14\ngpt-4o-mini-2024-07-18\no4-mini-2025-04-16\no1-mini-2024-09-12\ncodex-mini-latest'

usage() {
  cat <<'USAGE'
OpenAIQuotaFuse (Shell MVP)

Usage:
  openai-quota-fuse.sh status [--raw]
  openai-quota-fuse.sh check MODEL TOKENS
  openai-quota-fuse.sh select TOKENS MODEL [MODEL ...]
  openai-quota-fuse.sh models
  openai-quota-fuse.sh version

Environment:
  OPENAI_ADMIN_KEY               Admin key for Organization Usage API (required)
  OPENAI_USAGE_TIER              OpenAI usage tier 1..5 (default: 1, conservative)
  OPENAI_QUOTA_RESERVE_PERCENT   Safety reserve percentage (default: 5)
  OPENAI_QUOTA_FUSE_ENV_FILE     Optional env file path (default: ./.env if present)

Examples:
  ./shell/openai-quota-fuse.sh status
  ./shell/openai-quota-fuse.sh status --raw
  ./shell/openai-quota-fuse.sh check gpt-5.6-sol 8000
  ./shell/openai-quota-fuse.sh select 8000 gpt-5.6-sol gpt-5.6-luna gpt-5.6-terra
USAGE
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 2
  }
}

trim_quotes() {
  local value="$1"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

load_env_key() {
  local file="$1" key="$2" line value
  [[ -f "$file" ]] || return 0
  [[ -n "${!key:-}" ]] && return 0

  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  line="${line#export }"
  value="${line#*=}"
  value="$(trim_quotes "$value")"
  printf -v "$key" '%s' "$value"
  export "$key"
}

load_env_file() {
  local file="${OPENAI_QUOTA_FUSE_ENV_FILE:-.env}"
  load_env_key "$file" OPENAI_ADMIN_KEY
  load_env_key "$file" OPENAI_USAGE_TIER
  load_env_key "$file" OPENAI_QUOTA_RESERVE_PERCENT
}

validate_config() {
  [[ -n "${OPENAI_ADMIN_KEY:-}" ]] || {
    echo "error: OPENAI_ADMIN_KEY is not set (environment or .env)" >&2
    exit 2
  }

  OPENAI_USAGE_TIER="${OPENAI_USAGE_TIER:-1}"
  OPENAI_QUOTA_RESERVE_PERCENT="${OPENAI_QUOTA_RESERVE_PERCENT:-5}"

  [[ "$OPENAI_USAGE_TIER" =~ ^[1-5]$ ]] || {
    echo "error: OPENAI_USAGE_TIER must be 1..5" >&2
    exit 2
  }
  [[ "$OPENAI_QUOTA_RESERVE_PERCENT" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || {
    echo "error: OPENAI_QUOTA_RESERVE_PERCENT must be an integer 0..100" >&2
    exit 2
  }
}

quota_for_group() {
  local group="$1"
  if (( OPENAI_USAGE_TIER <= 2 )); then
    [[ "$group" == "large" ]] && printf '250000\n' || printf '2500000\n'
  else
    [[ "$group" == "large" ]] && printf '1000000\n' || printf '10000000\n'
  fi
}

model_group() {
  local model="$1"
  if grep -Fqx -- "$model" <<<"$LARGE_MODELS"; then
    printf 'large\n'
  elif grep -Fqx -- "$model" <<<"$SMALL_MODELS"; then
    printf 'small\n'
  else
    return 1
  fi
}

utc_day_start_epoch() {
  if date -u -j -f '%Y-%m-%d %H:%M:%S' "$(date -u '+%Y-%m-%d') 00:00:00" '+%s' >/dev/null 2>&1; then
    date -u -j -f '%Y-%m-%d %H:%M:%S' "$(date -u '+%Y-%m-%d') 00:00:00" '+%s'
  else
    date -u -d "$(date -u '+%Y-%m-%d') 00:00:00" '+%s'
  fi
}

fetch_usage() {
  local start_epoch="$1"
  curl --fail-with-body --silent --show-error --get "$USAGE_URL" \
    -H "Authorization: Bearer $OPENAI_ADMIN_KEY" \
    -H 'Content-Type: application/json' \
    --data-urlencode "start_time=$start_epoch" \
    --data-urlencode 'bucket_width=1d' \
    --data-urlencode 'limit=1' \
    --data-urlencode 'group_by=model' \
    --data-urlencode 'group_by=service_tier'
}

summarize_usage() {
  local json="$1"
  jq -r --arg large "$LARGE_MODELS" --arg small "$SMALL_MODELS" '
    ($large | split("\n")) as $largeModels |
    ($small | split("\n")) as $smallModels |
    [ .data[].results[]? |
      . as $r |
      (($r.input_tokens // 0) + ($r.output_tokens // 0)) as $tokens |
      if ($largeModels | index($r.model)) != null then {group:"large", tokens:$tokens}
      elif ($smallModels | index($r.model)) != null then {group:"small", tokens:$tokens}
      else empty end
    ] |
    {
      large: ([.[] | select(.group == "large") | .tokens] | add // 0),
      small: ([.[] | select(.group == "small") | .tokens] | add // 0)
    }
  ' <<<"$json"
}

available_for_group() {
  local group="$1" used="$2" quota reserve available
  quota="$(quota_for_group "$group")"
  reserve=$(( quota * OPENAI_QUOTA_RESERVE_PERCENT / 100 ))
  available=$(( quota - used - reserve ))
  (( available < 0 )) && available=0
  printf '%s\n' "$available"
}

print_status() {
  local raw_flag="${1:-}" raw summary large_used small_used large_quota small_quota large_avail small_avail
  raw="$(fetch_usage "$(utc_day_start_epoch)")"
  summary="$(summarize_usage "$raw")"

  if [[ "$raw_flag" == "--raw" ]]; then
    jq . <<<"$raw"
    return 0
  fi

  large_used="$(jq -r '.large' <<<"$summary")"
  small_used="$(jq -r '.small' <<<"$summary")"
  large_quota="$(quota_for_group large)"
  small_quota="$(quota_for_group small)"
  large_avail="$(available_for_group large "$large_used")"
  small_avail="$(available_for_group small "$small_used")"

  printf 'OpenAIQuotaFuse status (UTC day)\n'
  printf 'Usage tier: %s | Safety reserve: %s%%\n\n' "$OPENAI_USAGE_TIER" "$OPENAI_QUOTA_RESERVE_PERCENT"
  printf '%-12s %12s %12s %12s\n' 'Group' 'Used' 'Quota' 'Available*'
  printf '%-12s %12d %12d %12d\n' 'large' "$large_used" "$large_quota" "$large_avail"
  printf '%-12s %12d %12d %12d\n' 'small' "$small_used" "$small_quota" "$small_avail"
  printf '\n* Available subtracts the configured safety reserve.\n'
  printf '  Accounting is conservative: all usage on eligible models is counted.\n'
  printf '  Reset: 00:00 UTC.\n'
}

check_model() {
  local model="$1" tokens="$2" raw summary group used available
  [[ "$tokens" =~ ^[0-9]+$ ]] || {
    echo "error: TOKENS must be a non-negative integer" >&2
    exit 2
  }
  group="$(model_group "$model")" || {
    echo "error: model is not in the current complimentary-token registry: $model" >&2
    exit 3
  }
  raw="$(fetch_usage "$(utc_day_start_epoch)")"
  summary="$(summarize_usage "$raw")"
  used="$(jq -r --arg g "$group" '.[$g]' <<<"$summary")"
  available="$(available_for_group "$group" "$used")"

  if (( tokens <= available )); then
    printf 'ALLOW %s group=%s requested=%d available=%d\n' "$model" "$group" "$tokens" "$available"
    return 0
  fi
  printf 'BLOCK %s group=%s requested=%d available=%d\n' "$model" "$group" "$tokens" "$available"
  return 4
}

select_model() {
  local tokens="$1"; shift
  local raw summary model group used available
  [[ "$tokens" =~ ^[0-9]+$ ]] || {
    echo "error: TOKENS must be a non-negative integer" >&2
    exit 2
  }
  (( $# > 0 )) || {
    echo "error: select requires at least one MODEL" >&2
    exit 2
  }

  raw="$(fetch_usage "$(utc_day_start_epoch)")"
  summary="$(summarize_usage "$raw")"

  for model in "$@"; do
    if ! group="$(model_group "$model")"; then
      printf 'SKIP  %s reason=not-in-complimentary-registry\n' "$model" >&2
      continue
    fi
    used="$(jq -r --arg g "$group" '.[$g]' <<<"$summary")"
    available="$(available_for_group "$group" "$used")"
    if (( tokens <= available )); then
      printf '%s\n' "$model"
      return 0
    fi
    printf 'SKIP  %s group=%s requested=%d available=%d\n' "$model" "$group" "$tokens" "$available" >&2
  done

  echo 'error: no candidate model has enough complimentary quota' >&2
  return 4
}

print_models() {
  printf 'large group:\n%s\n\nsmall group:\n%s\n' "$LARGE_MODELS" "$SMALL_MODELS"
}

main() {
  need_command curl
  need_command jq
  load_env_file

  case "${1:-}" in
    status)
      validate_config
      shift
      [[ $# -le 1 ]] || { usage >&2; exit 2; }
      [[ $# -eq 0 || "$1" == "--raw" ]] || { usage >&2; exit 2; }
      print_status "${1:-}"
      ;;
    check)
      validate_config
      [[ $# -eq 3 ]] || { usage >&2; exit 2; }
      check_model "$2" "$3"
      ;;
    select)
      validate_config
      [[ $# -ge 3 ]] || { usage >&2; exit 2; }
      shift
      select_model "$@"
      ;;
    models)
      print_models
      ;;
    version|--version|-v)
      printf '%s\n' "$VERSION"
      ;;
    help|--help|-h|'')
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
