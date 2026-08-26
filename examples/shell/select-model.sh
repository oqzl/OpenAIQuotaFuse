#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Choose the first candidate that can fit inside the remaining complimentary quota.
# Preference order is user-defined: sol > luna > terra.
exec "$ROOT/shell/openai-quota-fuse.sh" select 8000 \
  gpt-5.6-sol \
  gpt-5.6-luna \
  gpt-5.6-terra
