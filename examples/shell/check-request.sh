#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Check whether an estimated 8,000-token request fits before making inference.
exec "$ROOT/shell/openai-quota-fuse.sh" check gpt-5.6-sol 8000
