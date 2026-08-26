#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON:-python3}"

command -v "$PYTHON_BIN" >/dev/null 2>&1 || {
  echo "error: Python 3 is required: $PYTHON_BIN" >&2
  exit 2
}

exec "$PYTHON_BIN" "$SCRIPT_DIR/../python/openai_quota_fuse.py" "$@"
