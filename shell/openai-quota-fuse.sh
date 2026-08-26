#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.2.0-dev"
readonly USAGE_URL="https://api.openai.com/v1/organization/usage/completions"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly DEFAULT_MODELS_FILE="$REPO_ROOT/models.json"

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
  OPENAI_QUOTA_FUSE_MODELS_FILE  Optional model-registry path (default: repo models.json)

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
  value="$(trim_quotes "${line#*=}")"
  printf -v "$key" '%s' "$value"
  export "$key"
}

load_env_file() {
  local file="${OPENAI_QUOTA_FUSE_ENV_FILE:-.env}"
  load_env_key "$file" OPENAI_ADMIN_KEY
  load_env_key "$file" OPENAI_USAGE_TIER
  load_env_key "$file" OPENAI_QUOTA_RESERVE_PERCENT
  load_env_key "$file" OPENAI_QUOTA_FUSE_MODELS_FILE
}

models_file() {
  printf '%s\n' "${OPENAI_QUOTA_FUSE_MODELS_FILE:-$DEFAULT_MODELS_FILE}"
}

validate_registry() {
  local file
  file="$(models_file)"
  [[ -r "$file" ]] || {
    echo "error: model registry not readable: $file" >&2
    exit 2
  }
  jq -e '
    .schema_version == 1 and
    (.quota_groups | type == "object") and
    ([.quota_groups[] | (.models | type == "array") and (.limits.tier_1_2 | type == "number") and (.limits.tier_3_5 | type == "number")] | all)
  ' "$file" >/dev/null || {
    echo "error: invalid model registry: $file" >&2
    exit 2
  }
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
  validate_registry
}

quota_for_group() {
  local group="$1" key file
  file="$(models_file)"
  if (( OPENAI_USAGE_TIER <= 2 )); then key="tier_1_2"; else key="tier_3_5"; fi
  jq -er --arg group "$group" --arg key "$key" '.quota_groups[$group].limits[$key]' "$file"
}

model_group() {
  local model="$1" file
  file="$(models_file)"
  jq -er --arg model "$model" '
    .quota_groups | to_entries[] | select(.value.models | index($model)) | .key
  ' "$file" | head -n 1
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
  local json="$1" file
  file="$(models_file)"
  jq -r --slurpfile registry "$file" '
    ($registry[0].quota_groups) as $groups |
    reduce (.data[].results[]? // empty) as $r
      ({};
        ($r.model // "") as $model |
        ([ $groups | to_entries[] | select(.value.models | index($model)) | .key ][0] // null) as $group |
        if $group == null then .
        else .[$group] = ((.[$group] // 0) + (($r.input_tokens // 0) + ($r.output_tokens // 0)))
        end
      ) |
    reduce ($groups | keys[]) as $g (. ; .[$g] = (.[$g] // 0))
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
  local raw_flag="${1:-}" raw summary group used quota available
  raw="$(fetch_usage "$(utc_day_start_epoch)")"
  if [[ "$raw_flag" == "--raw" ]]; then
    jq . <<<"$raw"
    return 0
  fi
  summary="$(summarize_usage "$raw")"

  printf 'OpenAIQuotaFuse status (UTC day)\n'
  printf 'Usage tier: %s | Safety reserve: %s%%\n' "$OPENAI_USAGE_TIER" "$OPENAI_QUOTA_RESERVE_PERCENT"
  printf 'Registry: %s (reviewed %s)\n\n' "$(models_file)" "$(jq -r '.last_reviewed' "$(models_file)")"
  printf '%-16s %12s %12s %12s\n' 'Group' 'Used' 'Quota' 'Available*'
  while IFS= read -r group; do
    used="$(jq -r --arg g "$group" '.[$g]' <<<"$summary")"
    quota="$(quota_for_group "$group")"
    available="$(available_for_group "$group" "$used")"
    printf '%-16s %12d %12d %12d\n' "$group" "$used" "$quota" "$available"
  done < <(jq -r '.quota_groups | keys[]' "$(models_file)")
  printf '\n* Available subtracts the configured safety reserve.\n'
  printf '  Accounting is conservative: all usage on registered models is counted.\n'
  printf '  Reset: 00:00 UTC.\n'
}

check_model() {
  local model="$1" tokens="$2" raw summary group used available
  [[ "$tokens" =~ ^[0-9]+$ ]] || { echo "error: TOKENS must be a non-negative integer" >&2; exit 2; }
  group="$(model_group "$model")" || {
    echo "error: model is not in models.json: $model" >&2
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
  [[ "$tokens" =~ ^[0-9]+$ ]] || { echo "error: TOKENS must be a non-negative integer" >&2; exit 2; }
  (( $# > 0 )) || { echo "error: select requires at least one MODEL" >&2; exit 2; }

  raw="$(fetch_usage "$(utc_day_start_epoch)")"
  summary="$(summarize_usage "$raw")"

  for model in "$@"; do
    if ! group="$(model_group "$model")"; then
      printf 'SKIP  %s reason=not-in-model-registry\n' "$model" >&2
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
  jq -r '
    "Registry reviewed: \(.last_reviewed)\nSource: \(.source)\n",
    (.quota_groups | to_entries[] | "\(.key):\n" + (.value.models | map("  " + .) | join("\n")) + "\n")
  ' "$(models_file)"
}

main() {
  need_command curl
  need_command jq
  load_env_file

  case "${1:-}" in
    status)
      validate_config; shift
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
      shift; select_model "$@"
      ;;
    models)
      validate_registry; print_models
      ;;
    version|--version|-v)
      printf '%s\n' "$VERSION"
      ;;
    help|--help|-h|'')
      usage
      ;;
    *)
      usage >&2; exit 2
      ;;
  esac
}

main "$@"
