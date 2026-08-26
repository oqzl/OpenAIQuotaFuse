# OpenAIQuotaFuse

[日本語](README-ja.md)

OpenAIQuotaFuse is an OpenAI-specific quota guard intended to keep API usage inside the complimentary daily token quota available to eligible data-sharing traffic.

The project will provide aligned implementations for Shell, Python 3, and Swift 6. The Shell CLI is the first reference implementation.

OpenAI's eligible models and quota-group limits change over time. They therefore live in the shared machine-readable `models.json` registry instead of being hard-coded independently in each implementation. `models.json` stays broad for accounting, while `model-selection.json` holds the smaller curated set actually used for automatic model selection.

Quota groups describe complimentary quota capacity. They are not model-quality or task-difficulty profiles. OpenAIQuotaFuse keeps those concepts separate.

## Shell MVP

Requirements:

- Bash
- curl
- jq
- an OpenAI Admin API key with access to the Organization Usage API

Create the Admin key from the OpenAI Platform organization Admin Keys page. Admin keys are organization-level credentials and should be kept separate from normal inference API keys. `OPENAI_ADMIN_KEY` is used only for Usage API access; the planned `run` command will use a separate `OPENAI_API_KEY` for inference.

Setup:

    cp .env.example .env
    $EDITOR .env

Check current conservative quota availability:

    ./shell/openai-quota-fuse.sh status

Inspect the raw Usage API response:

    ./shell/openai-quota-fuse.sh status --raw
    ./shell/openai-quota-fuse.sh status -r

Show the bundled accounting registry and current default selection order:

    ./shell/openai-quota-fuse.sh models

Check whether an estimated request fits:

    ./shell/openai-quota-fuse.sh check --model gpt-5.6-sol --estimated-tokens 8000
    ./shell/openai-quota-fuse.sh check -m gpt-5.6-sol -t 8000

Select using the curated default order in `model-selection.json`:

    ./shell/openai-quota-fuse.sh select --estimated-tokens 8000
    ./shell/openai-quota-fuse.sh select -t 8000

Or override the candidates for one call:

    ./shell/openai-quota-fuse.sh select -t 8000 \
      -m gpt-5.6-luna \
      -m gpt-5.6-terra

The original positional `check MODEL TOKENS` and `select TOKENS [MODEL ...]` forms remain supported for compatibility.

## Examples

Runnable Shell examples are under `examples/shell/`:

    bash examples/shell/status.sh
    bash examples/shell/check-request.sh
    bash examples/shell/select-model.sh

`select-model.sh` uses the current curated defaults from `model-selection.json`.

## Periodic model-policy audit

`models.json` is the accounting registry; `model-selection.json` is the curated automatic-selection set. These are deliberately separate because removing an old-but-still-eligible model from accounting could undercount Usage and overstate remaining free quota.

Run the local audit with:

    bash scripts/audit-model-policy.sh

`.github/workflows/model-policy-audit.yml` also runs every week. The current review interval is 30 days. Once stale, the workflow fails and prompts a review of incentive eligibility, deprecation status, API pricing, and whether an older candidate still has a reason to exist relative to newer models in the same quota group.

The current Shell MVP deliberately counts all usage on registered models. This is conservative: it can stop early, but avoids overstating free capacity while incentive-specific accounting behavior is being validated against real Usage API responses.

`models.json` records its primary source and `last_reviewed` date so stale policy data is visible. Runtime Help Center scraping is intentionally not part of quota decisions.

See `spec/QUOTA_POLICY.md` for the language-neutral policy and [docs/TODO.md](docs/TODO.md) for implementation work remaining after PR #1.
