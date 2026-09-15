#!/usr/bin/env bash
set -euo pipefail

REVISION="${WORKERS_CI_COMMIT_SHA:-${CF_PAGES_COMMIT_SHA:-$(git rev-parse HEAD)}}"

while IFS= read -r -d '' file; do
  sed -i "s/__COMMIT_SHA__/${REVISION}/g" "$file"
done < <(grep -rlZ '__COMMIT_SHA__' web || true)

echo "Stamped web/ with commit ${REVISION}"
