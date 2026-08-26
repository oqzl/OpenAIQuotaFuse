#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Use the curated default model order from model-selection.json.
# Pass explicit model IDs to override this order for a particular call.
exec "$ROOT/shell/openai-quota-fuse.sh" select 8000
