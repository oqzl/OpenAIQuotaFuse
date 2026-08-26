# OpenAIQuotaFuse

[日本語](README-ja.md)

OpenAIQuotaFuse is a quota guard for calling the OpenAI API while conservatively staying inside the complimentary daily token quota available to eligible data-sharing traffic.

Instead of calling the OpenAI API directly, ordinary usage goes through OpenAIQuotaFuse:

    Direct:
    you → OpenAI API

    With OpenAIQuotaFuse:
    you → quota check → model selection → OpenAI API

The goal is to reduce the need to manually reason about remaining quota and model choice for every request.

## Quick start

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git
    cd OpenAIQuotaFuse
    cp .env.example .env
    $EDITOR .env
    ./shell/openai-quota-fuse.sh run "How high is Mount Fuji?"

Requirements: Bash, curl, and jq. Configure `OPENAI_ADMIN_KEY` for Organization Usage and `OPENAI_API_KEY` for normal Responses API access.

For ordinary complimentary-quota use, start with `run`. The default `low` profile tries:

    gpt-5.6-terra → gpt-5.6-luna → gpt-5.6-sol

Terra and Luna currently share the same high-volume complimentary token quota, and that quota is accounted in tokens rather than API dollars. While the request remains inside complimentary quota, Luna's lower paid API price does not save quota. Terra is therefore preferred first because it is the more capable model. Luna remains useful as the cheaper option for future paid fallback.

Use `-q high` only when the task needs the Sol-first quality order:

    gpt-5.6-sol → gpt-5.6-terra → gpt-5.6-luna

## What `run` checks

Before inference, `run` calls `POST /v1/responses/input_tokens` with the candidate model and real prompt. It reserves:

    authoritative input_tokens + max_output_tokens

Only after that reservation fits the complimentary quota does it call `POST /v1/responses`. The completed response's actual `usage.input_tokens`, `usage.output_tokens`, and `usage.total_tokens` are printed to stderr as diagnostics.

Example diagnostics:

    quota: OK (input=12 + max_output=256 => reserve=268 tokens)
    model: gpt-5.6-terra
    usage: input=12 output=34 total=46

Force a model or reduce the maximum output allowance with `-m` / `-o`:

    ./shell/openai-quota-fuse.sh run -m gpt-5.6-luna -o 256 "Answer in one sentence"

Current accounting still intentionally errs on the conservative side when deriving remaining complimentary capacity from Organization Usage. It may stop earlier than the actual incentive allowance requires.

## Inspection commands

    ./shell/openai-quota-fuse.sh status
    ./shell/openai-quota-fuse.sh models
    ./shell/openai-quota-fuse.sh select -t 8000
    ./shell/openai-quota-fuse.sh check -m gpt-5.6-sol -t 8000
    ./shell/openai-quota-fuse.sh status -r

## Policy and maintenance

Eligible models and quota-group limits live in `models.json`; curated automatic-selection candidates live in `model-selection.json`. Quota groups describe complimentary capacity, not task difficulty or model quality.

The Shell implementation deliberately counts all usage on registered models until incentive-specific Usage API behavior is validated. `bash scripts/audit-model-policy.sh` checks model-policy review age; the GitHub workflow also runs weekly.

See `spec/QUOTA_POLICY.md` for language-neutral policy and [docs/TODO.md](docs/TODO.md) for remaining work.
