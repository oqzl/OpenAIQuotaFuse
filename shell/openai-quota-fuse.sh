#!/usr/bin/env bash
set -euo pipefail
readonly VERSION="0.6.0-dev"
readonly USAGE_URL="https://api.openai.com/v1/organization/usage/completions"
readonly RESPONSES_URL="https://api.openai.com/v1/responses"
readonly INPUT_TOKENS_URL="https://api.openai.com/v1/responses/input_tokens"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly DEFAULT_MODELS_FILE="$REPO_ROOT/models.json"
readonly DEFAULT_SELECTION_FILE="$REPO_ROOT/model-selection.json"
usage() { cat <<'USAGE'
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
USAGE
}
need_command(){ command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 2; }; }
trim_quotes(){ local v="$1"; [[ "$v" == \"*\" && "$v" == *\" ]] && v="${v:1:${#v}-2}"; [[ "$v" == \'*\' && "$v" == *\' ]] && v="${v:1:${#v}-2}"; printf '%s' "$v"; }
load_env_key(){ local f="$1" k="$2" l v; [[ -f "$f" ]] || return 0; [[ -n "${!k:-}" ]] && return 0; l="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${k}=" "$f" | tail -n1 || true)"; [[ -n "$l" ]] || return 0; l="${l#export }"; v="$(trim_quotes "${l#*=}")"; printf -v "$k" '%s' "$v"; export "$k"; }
load_env_file(){ local f="${OPENAI_QUOTA_FUSE_ENV_FILE:-.env}" k; for k in OPENAI_ADMIN_KEY OPENAI_API_KEY OPENAI_USAGE_TIER OPENAI_QUOTA_RESERVE_PERCENT OPENAI_QUOTA_FUSE_MODELS_FILE OPENAI_QUOTA_FUSE_SELECTION_FILE; do load_env_key "$f" "$k"; done; }
models_file(){ printf '%s\n' "${OPENAI_QUOTA_FUSE_MODELS_FILE:-$DEFAULT_MODELS_FILE}"; }
selection_file(){ printf '%s\n' "${OPENAI_QUOTA_FUSE_SELECTION_FILE:-$DEFAULT_SELECTION_FILE}"; }
validate_registry(){ local f; f="$(models_file)"; [[ -r "$f" ]] || { echo "error: model registry not readable: $f" >&2; exit 2; }; jq -e '.schema_version == 1 and (.quota_groups|type=="object")' "$f" >/dev/null || { echo "error: invalid model registry: $f" >&2; exit 2; }; }
validate_selection(){ local f; f="$(selection_file)"; [[ -r "$f" ]] || { echo "error: selection policy not readable: $f" >&2; exit 2; }; jq -e '.schema_version == 1 and (.quality_profiles|type=="object")' "$f" >/dev/null || { echo "error: invalid selection policy: $f" >&2; exit 2; }; }
validate_config(){ [[ -n "${OPENAI_ADMIN_KEY:-}" ]] || { echo 'error: OPENAI_ADMIN_KEY is not set (environment or .env)' >&2; exit 2; }; OPENAI_USAGE_TIER="${OPENAI_USAGE_TIER:-1}"; OPENAI_QUOTA_RESERVE_PERCENT="${OPENAI_QUOTA_RESERVE_PERCENT:-5}"; [[ "$OPENAI_USAGE_TIER" =~ ^[1-5]$ ]] || exit 2; [[ "$OPENAI_QUOTA_RESERVE_PERCENT" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || exit 2; validate_registry; }
validate_run_config(){ validate_config; [[ -n "${OPENAI_API_KEY:-}" ]] || { echo 'error: OPENAI_API_KEY is not set (environment or .env)' >&2; exit 2; }; }
quota_for_group(){ local g="$1" k; (( OPENAI_USAGE_TIER <= 2 )) && k=tier_1_2 || k=tier_3_5; jq -er --arg g "$g" --arg k "$k" '.quota_groups[$g].daily_token_limits[$k]' "$(models_file)"; }
model_group(){ jq -er --arg m "$1" '.quota_groups|to_entries[]|select(.value.models|index($m))|.key' "$(models_file)" | head -n1; }
utc_day_start_epoch(){ if date -u -j -f '%Y-%m-%d %H:%M:%S' "$(date -u '+%Y-%m-%d') 00:00:00" '+%s' >/dev/null 2>&1; then date -u -j -f '%Y-%m-%d %H:%M:%S' "$(date -u '+%Y-%m-%d') 00:00:00" '+%s'; else date -u -d "$(date -u '+%Y-%m-%d') 00:00:00" '+%s'; fi; }
fetch_usage(){ curl --fail-with-body --silent --show-error --get "$USAGE_URL" -H "Authorization: Bearer $OPENAI_ADMIN_KEY" -H 'Content-Type: application/json' --data-urlencode "start_time=$1" --data-urlencode bucket_width=1d --data-urlencode limit=1 --data-urlencode group_by=model --data-urlencode group_by=service_tier; }
summarize_usage(){ jq -r --slurpfile registry "$(models_file)" '($registry[0].quota_groups) as $gs|reduce(.data[].results[]? // empty) as $r ({};($r.model//"") as $m|([$gs|to_entries[]|select(.value.models|index($m))|.key][0]//null) as $g|if $g==null then . else .[$g]=((.[$g]//0)+(($r.input_tokens//0)+($r.output_tokens//0))) end)|reduce($gs|keys[]) as $g (.;.[$g]=(.[$g]//0))' <<<"$1"; }
available_for_group(){ local q r a; q="$(quota_for_group "$1")"; r=$((q*OPENAI_QUOTA_RESERVE_PERCENT/100)); a=$((q-$2-r)); ((a<0))&&a=0; printf '%s\n' "$a"; }
print_status(){ local raw s g u q a; raw="$(fetch_usage "$(utc_day_start_epoch)")"; [[ "${1:-}" =~ ^(--raw|-r)$ ]] && { jq . <<<"$raw"; return; }; s="$(summarize_usage "$raw")"; printf 'OpenAIQuotaFuse status (UTC day)\n'; while IFS= read -r g; do u="$(jq -r --arg g "$g" '.[$g]' <<<"$s")"; q="$(quota_for_group "$g")"; a="$(available_for_group "$g" "$u")"; printf '%s used=%s quota=%s available=%s\n' "$g" "$u" "$q" "$a"; done < <(jq -r '.quota_groups|keys[]' "$(models_file)"); }
check_model(){ local g raw s u a; [[ "$2" =~ ^[0-9]+$ ]] || exit 2; g="$(model_group "$1")" || { echo "error: model is not in models.json: $1" >&2; return 3; }; raw="$(fetch_usage "$(utc_day_start_epoch)")"; s="$(summarize_usage "$raw")"; u="$(jq -r --arg g "$g" '.[$g]' <<<"$s")"; a="$(available_for_group "$g" "$u")"; (( $2 <= a )) && { printf 'ALLOW %s group=%s requested=%d available=%d\n' "$1" "$g" "$2" "$a"; return 0; }; printf 'BLOCK %s group=%s requested=%d available=%d\n' "$1" "$g" "$2" "$a"; return 4; }
selection_candidates(){ local q="$1" f; f="$(selection_file)"; validate_selection; [[ -n "$q" ]] || q="$(jq -r '.default_quality' "$f")"; jq -er --arg q "$q" '.quality_profiles[$q][]' "$f" 2>/dev/null || { echo "error: unknown quality profile: $q" >&2; return 2; }; }
select_model(){ local tokens="$1" quality="$2" raw s m g u a; shift 2; local c=(); if (($#==0)); then while IFS= read -r m; do c+=("$m"); done < <(selection_candidates "$quality"); set -- "${c[@]}"; fi; raw="$(fetch_usage "$(utc_day_start_epoch)")"; s="$(summarize_usage "$raw")"; for m in "$@"; do g="$(model_group "$m")" || continue; u="$(jq -r --arg g "$g" '.[$g]' <<<"$s")"; a="$(available_for_group "$g" "$u")"; ((tokens<=a)) && { printf '%s\n' "$m"; return; }; done; echo 'error: no candidate model has enough complimentary quota' >&2; return 4; }
count_input_tokens(){ local payload response count; payload="$(jq -n --arg model "$1" --arg input "$2" '{model:$model,input:$input}')"; response="$(curl --fail-with-body --silent --show-error "$INPUT_TOKENS_URL" -H "Authorization: Bearer $OPENAI_API_KEY" -H 'Content-Type: application/json' -d "$payload")" || return $?; count="$(jq -er '.input_tokens|select(type=="number" and .>=0)' <<<"$response")" || { echo 'error: invalid response from /responses/input_tokens' >&2; return 5; }; printf '%d\n' "$count"; }
run_prompt(){ local prompt="$1" quality="$2" explicit="$3" max="$4" first model input required payload response; [[ "$max" =~ ^[1-9][0-9]*$ ]] || exit 2; if [[ -n "$explicit" ]]; then first="$explicit"; else first="$(selection_candidates "$quality"|head -n1)"; fi; input="$(count_input_tokens "$first" "$prompt")" || return $?; required=$((input+max)); if [[ -n "$explicit" ]]; then check_model "$first" "$required" >/dev/null || return $?; model="$first"; else model="$(select_model "$required" "$quality")" || return $?; if [[ "$model" != "$first" ]]; then input="$(count_input_tokens "$model" "$prompt")" || return $?; required=$((input+max)); check_model "$model" "$required" >/dev/null || return $?; fi; fi; printf 'quota: OK (input=%d + max_output=%d => reserve=%d tokens)\nmodel: %s\n\n' "$input" "$max" "$required" "$model" >&2; payload="$(jq -n --arg model "$model" --arg input "$prompt" --argjson max "$max" '{model:$model,input:$input,max_output_tokens:$max}')"; response="$(curl --fail-with-body --silent --show-error "$RESPONSES_URL" -H "Authorization: Bearer $OPENAI_API_KEY" -H 'Content-Type: application/json' -d "$payload")" || return $?; printf 'usage: input=%s output=%s total=%s\n' "$(jq -r '.usage.input_tokens//"?"'<<<"$response")" "$(jq -r '.usage.output_tokens//"?"'<<<"$response")" "$(jq -r '.usage.total_tokens//"?"'<<<"$response")" >&2; jq -r '[.output[]?|select(.type=="message")|.content[]?|select(.type=="output_text")|.text]|join("\n")' <<<"$response"; }
print_models(){ jq -r '.quota_groups|to_entries[]|"\(.key): \(.value.models|join(", "))"' "$(models_file)"; validate_selection; printf 'Default quality: %s\n' "$(jq -r '.default_quality' "$(selection_file)")"; }
parse_check(){ local m="" t=""; if [[ $# -eq 2 && "$1" != -* ]]; then check_model "$1" "$2"; return; fi; while (($#)); do case "$1" in -m|--model)m="$2";shift 2;;-t|--estimated-tokens)t="$2";shift 2;;*)usage >&2;exit 2;;esac; done; [[ -n "$m" && -n "$t" ]]||exit 2; check_model "$m" "$t"; }
parse_select(){ local t="" q=""; local ms=(); if (($#>=1))&&[[ "$1" != -* ]]; then t="$1";shift;select_model "$t" "" "$@";return;fi; while (($#));do case "$1" in -t|--estimated-tokens)t="$2";shift 2;;-q|--quality)q="$2";shift 2;;-m|--model)ms+=("$2");shift 2;;*)exit 2;;esac;done;[[ -n "$t" ]]||exit 2;select_model "$t" "$q" "${ms[@]}"; }
parse_run(){ local q="" m="" o=1024;local p=();while (($#));do case "$1" in -q|--quality)q="$2";shift 2;;-m|--model)m="$2";shift 2;;-o|--max-output-tokens)o="$2";shift 2;;--)shift;p+=("$@");break;;-*)exit 2;;*)p+=("$1");shift;;esac;done;((${#p[@]}))||{ echo 'error: run requires a prompt' >&2;exit 2;};run_prompt "${p[*]}" "$q" "$m" "$o"; }
main(){ need_command curl;need_command jq;load_env_file;case "${1:-}" in run)validate_run_config;shift;parse_run "$@";;status)validate_config;shift;print_status "${1:-}";;check)validate_config;shift;parse_check "$@";;select)validate_config;shift;parse_select "$@";;models)validate_registry;print_models;;version|--version|-v)printf '%s\n' "$VERSION";;help|--help|-h|'')usage;;*)usage >&2;exit 2;;esac; }
main "$@"
