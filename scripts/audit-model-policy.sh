#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$ROOT/models.json"
SELECTION="$ROOT/model-selection.json"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: missing command: $1" >&2; exit 2; }; }
need jq
need date

for file in "$REGISTRY" "$SELECTION"; do
  [[ -r "$file" ]] || { echo "error: missing policy file: $file" >&2; exit 2; }
done

jq -e '.schema_version == 1 and (.quota_groups | type == "object")' "$REGISTRY" >/dev/null
jq -e '.schema_version == 1 and (.default_candidates | type == "array") and (.review_interval_days | type == "number")' "$SELECTION" >/dev/null

# Every automatic-selection candidate must also be present in the accounting registry.
missing="$(jq -rn --slurpfile registry "$REGISTRY" --slurpfile selection "$SELECTION" '
  [ $registry[0].quota_groups[].models[] ] as $registered |
  [ $selection[0].default_candidates[] as $candidate |
    select(($registered | index($candidate)) == null) |
    $candidate
  ] |
  .[]?
')"
if [[ -n "$missing" ]]; then
  echo "error: selection candidates missing from models.json:" >&2
  printf '%s\n' "$missing" >&2
  exit 1
fi

reviewed="$(jq -r '.last_reviewed' "$SELECTION")"
interval="$(jq -r '.review_interval_days' "$SELECTION")"

if reviewed_epoch="$(date -u -j -f '%Y-%m-%d' "$reviewed" '+%s' 2>/dev/null)"; then
  now_epoch="$(date -u '+%s')"
else
  reviewed_epoch="$(date -u -d "$reviewed" '+%s')"
  now_epoch="$(date -u '+%s')"
fi
age_days=$(( (now_epoch - reviewed_epoch) / 86400 ))

printf 'Model policy reviewed: %s (%d days ago)\n' "$reviewed" "$age_days"
printf 'Review interval: %d days\n' "$interval"

if (( age_days > interval )); then
  cat >&2 <<EOF
error: model-selection policy is stale.

Review these items against current OpenAI primary sources:
- data-sharing incentive eligibility and quota groups
- current model availability and deprecation status
- current API pricing
- whether each default candidate still has a reason to exist
- whether a newer model dominates an older candidate on quality/cost for the same quota group

Then update models.json / model-selection.json and their last_reviewed fields.
EOF
  exit 1
fi

printf 'Default candidates:\n'
jq -r '.default_candidates[] | "  " + .' "$SELECTION"
printf 'Policy audit: OK\n'
