# OpenAIQuotaFuse

[日本語](README-ja.md)

OpenAIQuotaFuse is a quota guard for calling the OpenAI API while conservatively staying inside the complimentary daily token quota available to eligible data-sharing traffic, with a small hard-capped paid fallback.

## Quick start

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git
    cd OpenAIQuotaFuse
    cp .env.example .env
    $EDITOR .env
    ./shell/openai-quota-fuse.sh run "How high is Mount Fuji?"

Requirements: Bash, curl, and jq.

`OPENAI_ADMIN_KEY` is used only for Organization Usage. Organization Owners can create an Admin API key from the API Platform dashboard under Organization settings → Admin keys: https://platform.openai.com/settings/organization/admin-keys . Keep it separate from the normal project `OPENAI_API_KEY`, which is used for input-token counting and inference.

## Selection policy

Complimentary quota is always tried first. The default `low` order is:

    gpt-5.6-terra → gpt-5.6-luna → gpt-5.6-sol

Terra and Luna share the high-volume complimentary token quota, so Terra is preferred there for capability per quota token. `-q high` is explicitly Sol-first:

    gpt-5.6-sol → gpt-5.6-terra → gpt-5.6-luna

If no complimentary candidate can fit the conservative reservation, `run` may use the annual paid budget. Its default is `$5` and can be changed or disabled:

    OPENAI_ANNUAL_PAID_BUDGET_USD=5
    OPENAI_ANNUAL_PAID_BUDGET_USD=0   # disable paid fallback

The ordinary paid order is cost-aware and separate from complimentary selection:

    gpt-5.6-luna → gpt-5.6-terra → gpt-5.6-sol

The paid path reserves the worst-case request cost before inference, persists that reservation in a local ledger, and reconciles it to actual response usage afterward. The ledger resets logically by UTC calendar year; old events remain as history. Override its location with `OPENAI_QUOTA_FUSE_PAID_LEDGER`.

OpenAI does not currently provide a documented runtime API here for reliable prepaid-credit balance/expiry metadata, so OpenAIQuotaFuse does not scrape the Billing UI or guess. Purchased-credit expiry is therefore not used for runtime selection. OpenAI currently documents purchased credits as expiring after one year.

## `run`

Before inference, `run` calls `POST /v1/responses/input_tokens`, then reserves:

    input_tokens + max_output_tokens

Examples:

    ./shell/openai-quota-fuse.sh run "Explain this"
    ./shell/openai-quota-fuse.sh run -i "Explain this"
    printf '%s\n' "Explain this" | ./shell/openai-quota-fuse.sh run
    ./shell/openai-quota-fuse.sh run -i - < prompt.txt
    ./shell/openai-quota-fuse.sh run -m gpt-5.6-luna -o 256 "Answer in one sentence"
    ./shell/openai-quota-fuse.sh run -r "Return the full Responses API JSON"

`-r/--raw` changes stdout from extracted output text to the complete Responses API JSON. Quota/model/usage diagnostics remain on stderr.

The Shell reference deliberately accepts only plain text input plus model/quality/max-output/raw controls. Tools, structured-output schemas, files/images, `previous_response_id`, and arbitrary Responses API fields are out of scope for the Shell P0 rather than being partially proxied. Add them only when OpenAIQuotaFuse has explicit quota/accounting semantics for them.

Legacy positional `check MODEL TOKENS` and `select TOKENS [MODEL ...]` remain compatible throughout 0.x. The canonical documented forms are long/short options; positional compatibility is planned for removal at 1.0 rather than accumulating indefinitely.

## Inspection commands

    ./shell/openai-quota-fuse.sh status
    ./shell/openai-quota-fuse.sh models
    ./shell/openai-quota-fuse.sh select -t 8000
    ./shell/openai-quota-fuse.sh check -m gpt-5.6-sol -t 8000
    ./shell/openai-quota-fuse.sh status -r

## Policy and maintenance

Eligible models and quota-group limits live in `models.json`; curated complimentary and paid selection policy lives in `model-selection.json`. Current OpenAI primary documentation takes precedence over these snapshots when they become stale.

The Shell implementation deliberately counts all usage on registered models until incentive-specific Usage API behavior is validated. `bash scripts/audit-model-policy.sh` checks model-policy review age; the GitHub workflow also runs weekly.

See `spec/QUOTA_POLICY.md` for language-neutral policy and [docs/TODO.md](docs/TODO.md) for remaining work.
