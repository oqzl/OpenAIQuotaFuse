#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.5.0-dev"
readonly USAGE_URL="https://api.openai.com/v1/organization/usage/completions"
readonly RESPONSES_URL="https://api.openai.com/v1/responses"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly DEFAULT_MODELS_FILE="$REPO_ROOT/models.json"
readonly DEFAULT_SELECTION_FILE="$REPO_ROOT/model-selection.json"

usage() {
  cat <<'USAGE'
OpenAIQuotaFuse

Usage:
  openai-quota-fuse.sh run [--quality PROFILE] [--model MODEL] [--max-output-tokens TOKENS] PROMPT
  openai-quota-fuse.sh status [--raw|-r]
  openai-quota-fuse.sh check --model MODEL --estimated-tokens TOKENS
  openai-quota-fuse.sh select --estimated-tokens TOKENS [--quality PROFILE] [--model MODEL ...]
  openai-quota-fuse.sh models
  openai-quota-fuse.sh version

Compatibility forms:
  openai-quota-fuse.sh check MODEL TOKENS
  openai-quota-fuse.sh select TOKENS [MODEL ...]

Options:
  -m, --model MODEL              Model to use/check or explicit selection candidate
  -t, --estimated-tokens TOKENS Conservative token requirement for check/select
  -o, --max-output-tokens TOKENS Maximum output tokens for run (default: 1024)
  -q, --quality PROFILE          Selection profile: high, normal, low
  -r, --raw                      Print raw Usage API response where supported
  -h, --help                     Show help
  -v, --version                  Show version

Environment:
  OPENAI_ADMIN_KEY                  Admin key for Organization Usage API
  OPENAI_API_KEY                    Normal API key for inference (run only)
  OPENAI_USAGE_TIER                 OpenAI usage tier 1..5 (default: 1, conservative)
  OPENAI_QUOTA_RESERVE_PERCENT      Safety reserve percentage (default: 5)
  OPENAI_QUOTA_FUSE_ENV_FILE        Optional env file path (default: ./.env if present)
  OPENAI_QUOTA_FUSE_MODELS_FILE     Optional accounting registry path
  OPENAI_QUOTA_FUSE_SELECTION_FILE  Optional curated selection policy path

Examples:
  ./shell/openai-quota-fuse.sh run "Why is the sky blue?"
  ./shell/openai-quota-fuse.sh run -q low "Summarize this in one sentence"
  ./shell/openai-quota-fuse.sh run -m gpt-5.6-luna -o 512 "Say hello"
  ./shell/openai-quota-fuse.sh status
  ./shell/openai-quota-fuse.sh select -t 8000
USAGE
}

need_command() { command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 2; }; }
trim_quotes() { local value="$1"; if [[ "$value" == \"*\" && "$value" == *\" ]]; then value="${value:1:${#value}-2}"; elif [[ "$value" == \'*\' && "$value" == *\' ]]; then value="${value:1:${#value}-2}"; fi; printf '%s' "$value"; }
load_env_key() { local file="$1" key="$2" line value; [[ -f "$file" ]] || return 0; [[ -n "${!key:-}" ]] && return 0; line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -n 1 || true)"; [[ -n "$line" ]] || return 0; line="${line#export }"; value="$(trim_quotes "${line#*=}")"; printf -v "$key" '%s' "$value"; export "$key"; }
load_env_file() { local file="${OPENAI_QUOTA_FUSE_ENV_FILE:-.env}"; load_env_key "$file" OPENAI_ADMIN_KEY; load_env_key "$file" OPENAI_API_KEY; load_env_key "$file" OPENAI_USAGE_TIER; load_env_key "$file" OPENAI_QUOTA_RESERVE_PERCENT; load_env_key "$file" OPENAI_QUOTA_FUSE_MODELS_FILE; load_env_key "$file" OPENAI_QUOTA_FUSE_SELECTION_FILE; }
models_file() { printf '%s\n' "${OPENAI_QUOTA_FUSE_MODELS_FILE:-$DEFAULT_MODELS_FILE}"; }
selection_file() { printf '%s\n' "${OPENAI_QUOTA_FUSE_SELECTION_FILE:-$DEFAULT_SELECTION_FILE}"; }

validate_registry() { local file; file="$(models_file)"; [[ -r "$file" ]] || { echo "error: model registry not readable: $file" >&2; exit 2; }; jq -e '.schema_version == 1 and (.quota_groups | type == "object") and ([.quota_groups[] | (.models | type == "array") and (.daily_token_limits.tier_1_2 | type == "number") and (.daily_token_limits.tier_3_5 | type == "number")] | all)' "$file" >/dev/null || { echo "error: invalid model registry: $file" >&2; exit 2; }; }
validate_selection() { local file; file="$(selection_file)"; [[ -r "$file" ]] || { echo "error: selection policy not readable: $file" >&2; exit 2; }; jq -e '.schema_version == 1 and (.default_candidates | type == "array") and (.default_candidates | length > 0) and (.default_quality | type == "string") and (.quality_profiles | type == "object") and (.quality_profiles[.default_quality] | type == "array")' "$file" >/dev/null || { echo "error: invalid selection policy: $file" >&2; exit 2; }; }
validate_config() { [[ -n "${OPENAI_ADMIN_KEY:-}" ]] || { echo "error: OPENAI_ADMIN_KEY is not set (environment or .env)" >&2; exit 2; }; OPENAI_USAGE_TIER="${OPENAI_USAGE_TIER:-1}"; OPENAI_QUOTA_RESERVE_PERCENT="${OPENAI_QUOTA_RESERVE_PERCENT:-5}"; [[ "$OPENAI_USAGE_TIER" =~ ^[1-5]$ ]] || { echo "error: OPENAI_USAGE_TIER must be 1..5" >&2; exit 2; }; [[ "$OPENAI_QUOTA_RESERVE_PERCENT" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || { echo "error: OPENAI_QUOTA_RESERVE_PERCENT must be an integer 0..100" >&2; exit 2; }; validate_registry; }
validate_run_config() { validate_config; [[ -n "${OPENAI_API_KEY:-}" ]] || { echo "error: OPENAI_API_KEY is not set (environment or .env)" >&2; exit 2; }; }
quota_for_group() { local group="$1" key file; file="$(models_file)"; if (( OPENAI_USAGE_TIER <= 2 )); then key="tier_1_2"; else key="tier_3_5"; fi; jq -er --arg group "$group" --arg key "$key" '.quota_groups[$group].daily_token_limits[$key]' "$file"; }
model_group() { local model="$1" file; file="$(models_file)"; jq -er --arg model "$model" '.quota_groups | to_entries[] | select(.value.models | index($model)) | .key' "$file" | head -n 1; }
utc_day_start_epoch() { if date -u -j -f '%Y-%m-%d %H:%M:%S' "$(date -u '+%Y-%m-%d') 00:00:00" '+%s' >/dev/null 2>&1; then date -u -j -f '%Y-%m-%d %H:%M:%S' "$(date -u '+%Y-%m-%d') 00:00:00" '+%s'; else date -u -d "$(date -u '+%Y-%m-%d') 00:00:00" '+%s'; fi; }
fetch_usage() { local start_epoch="$1"; curl --fail-with-body --silent --show-error --get "$USAGE_URL" -H "Authorization: Bearer $OPENAI_ADMIN_KEY" -H 'Content-Type: application/json' --data-urlencode "start_time=$start_epoch" --data-urlencode 'bucket_width=1d' --data-urlencode 'limit=1' --data-urlencode 'group_by=model' --data-urlencode 'group_by=service_tier'; }
summarize_usage() { local json="$1" file; file="$(models_file)"; jq -r --slurpfile registry "$file" '($registry[0].quota_groups) as $groups | reduce (.data[].results[]? // empty) as $r ({}; ($r.model // "") as $model | ([ $groups | to_entries[] | select(.value.models | index($model)) | .key ][0] // null) as $group | if $group == null then . else .[$group] = ((.[$group] // 0) + (($r.input_tokens // 0) + ($r.output_tokens // 0))) end) | reduce ($groups | keys[]) as $g (. ; .[$g] = (.[$g] // 0))' <<<"$json"; }
available_for_group() { local group="$1" used="$2" quota reserve available; quota="$(quota_for_group "$group")"; reserve=$(( quota * OPENAI_QUOTA_RESERVE_PERCENT / 100 )); available=$(( quota - used - reserve )); (( available < 0 )) && available=0; printf '%s\n' "$available"; }

print_status() { local raw_flag="${1:-}" raw summary group used quota available; raw="$(fetch_usage "$(utc_day_start_epoch)")"; if [[ "$raw_flag" == "--raw" || "$raw_flag" == "-r" ]]; then jq . <<<"$raw"; return 0; fi; summary="$(summarize_usage "$raw")"; printf 'OpenAIQuotaFuse status (UTC day)\n'; printf 'Usage tier: %s | Safety reserve: %s%%\n' "$OPENAI_USAGE_TIER" "$OPENAI_QUOTA_RESERVE_PERCENT"; printf 'Registry: %s (reviewed %s)\n\n' "$(models_file)" "$(jq -r '.last_reviewed' "$(models_file)")"; printf '%-16s %12s %12s %12s\n' 'Group' 'Used' 'Quota' 'Available*'; while IFS= read -r group; do used="$(jq -r --arg g "$group" '.[$g]' <<<"$summary")"; quota="$(quota_for_group "$group")"; available="$(available_for_group "$group" "$used")"; printf '%-16s %12d %12d %12d\n' "$group" "$used" "$quota" "$available"; done < <(jq -r '.quota_groups | keys[]' "$(models_file)"); printf '\n* Available subtracts the configured safety reserve.\n  Accounting is conservative: all usage on registered models is counted.\n  Reset: 00:00 UTC.\n'; }
check_model() { local model="$1" tokens="$2" raw summary group used available; [[ "$tokens" =~ ^[0-9]+$ ]] || { echo "error: TOKENS must be a non-negative integer" >&2; exit 2; }; group="$(model_group "$model")" || { echo "error: model is not in models.json: $model" >&2; exit 3; }; raw="$(fetch_usage "$(utc_day_start_epoch)")"; summary="$(summarize_usage "$raw")"; used="$(jq -r --arg g "$group" '.[$g]' <<<"$summary")"; available="$(available_for_group "$group" "$used")"; if (( tokens <= available )); then printf 'ALLOW %s group=%s requested=%d available=%d\n' "$model" "$group" "$tokens" "$available"; return 0; fi; printf 'BLOCK %s group=%s requested=%d available=%d\n' "$model" "$group" "$tokens" "$available"; return 4; }
selection_candidates() { local quality="${1:-}" file; file="$(selection_file)"; validate_selection; if [[ -z "$quality" ]]; then quality="$(jq -r '.default_quality' "$file")"; fi; jq -er --arg quality "$quality" '.quality_profiles[$quality][]' "$file" 2>/dev/null || { echo "error: unknown quality profile: $quality" >&2; return 2; }; }
select_model() { local tokens="$1" quality="$2"; shift 2; local raw summary model group used available; local candidates=(); [[ "$tokens" =~ ^[0-9]+$ ]] || { echo "error: TOKENS must be a non-negative integer" >&2; exit 2; }; if (( $# == 0 )); then while IFS= read -r model; do candidates+=("$model"); done < <(selection_candidates "$quality"); (( ${#candidates[@]} > 0 )) || return 2; set -- "${candidates[@]}"; fi; raw="$(fetch_usage "$(utc_day_start_epoch)")"; summary="$(summarize_usage "$raw")"; for model in "$@"; do if ! group="$(model_group "$model")"; then printf 'SKIP  %s reason=not-in-model-registry\n' "$model" >&2; continue; fi; used="$(jq -r --arg g "$group" '.[$g]' <<<"$summary")"; available="$(available_for_group "$group" "$used")"; if (( tokens <= available )); then printf '%s\n' "$model"; return 0; fi; printf 'SKIP  %s group=%s requested=%d available=%d\n' "$model" "$group" "$tokens" "$available" >&2; done; echo 'error: no candidate model has enough complimentary quota' >&2; return 4; }

estimate_input_tokens() { local text="$1" bytes; bytes="$(printf '%s' "$text" | wc -c | tr -d ' ')"; printf '%d\n' $(( (bytes + 2) / 3 + 32 )); }
run_prompt() { local prompt="$1" quality="$2" explicit_model="$3" max_output="$4" input_estimate required model payload response; [[ "$max_output" =~ ^[1-9][0-9]*$ ]] || { echo "error: max output tokens must be a positive integer" >&2; exit 2; }; input_estimate="$(estimate_input_tokens "$prompt")"; required=$(( input_estimate + max_output )); if [[ -n "$explicit_model" ]]; then check_model "$explicit_model" "$required" >/dev/null || return $?; model="$explicit_model"; else model="$(select_model "$required" "$quality")" || return $?; fi; printf 'quota: OK (conservative estimate %d tokens)\nmodel: %s\n\n' "$required" "$model" >&2; payload="$(jq -n --arg model "$model" --arg input "$prompt" --argjson max "$max_output" '{model:$model,input:$input,max_output_tokens:$max}')"; response="$(curl --fail-with-body --silent --show-error "$RESPONSES_URL" -H "Authorization: Bearer $OPENAI_API_KEY" -H 'Content-Type: application/json' -d "$payload")" || return $?; jq -r '[.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("\n")' <<<"$response"; }
print_models() { jq -r '"Registry reviewed: \(.last_reviewed)\nSource: \(.source)\n", (.quota_groups | to_entries[] | "\(.key):\n" + (.value.models | map("  " + .) | join("\n")) + "\n")' "$(models_file)"; if [[ -r "$(selection_file)" ]]; then validate_selection; printf 'Default quality: %s\n' "$(jq -r '.default_quality' "$(selection_file)")"; printf 'Quality profiles (reviewed %s):\n' "$(jq -r '.last_reviewed' "$(selection_file)")"; jq -r '.quality_profiles | to_entries[] | "  \(.key): \(.value | join(", "))"' "$(selection_file)"; fi; }
parse_check() { local model="" tokens=""; if [[ $# -eq 2 && "$1" != -* ]]; then check_model "$1" "$2"; return; fi; while (( $# > 0 )); do case "$1" in -m|--model) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; model="$2"; shift 2 ;; -t|--estimated-tokens) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; tokens="$2"; shift 2 ;; -h|--help) usage; return ;; *) echo "error: unknown check option: $1" >&2; usage >&2; exit 2 ;; esac; done; [[ -n "$model" && -n "$tokens" ]] || { usage >&2; exit 2; }; check_model "$model" "$tokens"; }
parse_select() { local tokens="" quality=""; local models=(); if (( $# >= 1 )) && [[ "$1" != -* ]]; then tokens="$1"; shift; select_model "$tokens" "" "$@"; return; fi; while (( $# > 0 )); do case "$1" in -t|--estimated-tokens) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; tokens="$2"; shift 2 ;; -q|--quality) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; quality="$2"; shift 2 ;; -m|--model) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; models+=("$2"); shift 2 ;; -h|--help) usage; return ;; *) echo "error: unknown select option: $1" >&2; usage >&2; exit 2 ;; esac; done; [[ -n "$tokens" ]] || { usage >&2; exit 2; }; select_model "$tokens" "$quality" "${models[@]}"; }
parse_run() { local quality="" model="" max_output="1024"; local prompt_parts=(); while (( $# > 0 )); do case "$1" in -q|--quality) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; quality="$2"; shift 2 ;; -m|--model) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; model="$2"; shift 2 ;; -o|--max-output-tokens) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; max_output="$2"; shift 2 ;; -h|--help) usage; return ;; --) shift; prompt_parts+=("$@"); break ;; -*) echo "error: unknown run option: $1" >&2; usage >&2; exit 2 ;; *) prompt_parts+=("$1"); shift ;; esac; done; (( ${#prompt_parts[@]} > 0 )) || { echo 'error: run requires a prompt' >&2; usage >&2; exit 2; }; run_prompt "${prompt_parts[*]}" "$quality" "$model" "$max_output"; }

main() { need_command curl; need_command jq; load_env_file; case "${1:-}" in run) validate_run_config; shift; parse_run "$@" ;; status) validate_config; shift; [[ $# -le 1 ]] || { usage >&2; exit 2; }; [[ $# -eq 0 || "$1" == "--raw" || "$1" == "-r" ]] || { usage >&2; exit 2; }; print_status "${1:-}" ;; check) validate_config; shift; parse_check "$@" ;; select) validate_config; shift; parse_select "$@" ;; models) validate_registry; print_models ;; version|--version|-v) printf '%s\n' "$VERSION" ;; help|--help|-h|'') usage ;; *) usage >&2; exit 2 ;; esac; }
main "$@"
