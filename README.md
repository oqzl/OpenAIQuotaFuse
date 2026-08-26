# OpenAIQuotaFuse

[日本語](README-ja.md)

OpenAIQuotaFuse is a quota guard for calling the OpenAI API while conservatively staying inside the complimentary daily token quota available to eligible data-sharing traffic.

## Quick start

The normal path is deliberately simple:

    want to call OpenAI
            ↓
    OpenAIQuotaFuse
            ↓
     fits free quota?
       ↓ YES  ↓ NO
       call    stop

For ordinary use, start with `run`. You do not need to manually combine `status` and `select`.

### 1. Clone

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git
    cd OpenAIQuotaFuse

Requirements: Bash, curl, and jq.

### 2. Configure two API keys

    cp .env.example .env
    $EDITOR .env

Set:

    OPENAI_ADMIN_KEY=...
    OPENAI_API_KEY=...

`OPENAI_ADMIN_KEY` reads Organization Usage. `OPENAI_API_KEY` is the normal inference key used by `run`. Keep the organization-level Admin credential separate from inference credentials.

### 3. Run a prompt

    ./shell/openai-quota-fuse.sh run "How high is Mount Fuji?"

OpenAIQuotaFuse checks remaining quota, selects an eligible model, and calls the Responses API. If no candidate fits the conservative quota estimate, it stops before inference.

Example:

    quota: OK (conservative estimate 1068 tokens)
    model: gpt-5.6-luna

    Mount Fuji is 3,776 meters high.

## A little more control

Prefer the low-cost/light-task profile:

    ./shell/openai-quota-fuse.sh run -q low "What is 1+1?"

Force a model:

    ./shell/openai-quota-fuse.sh run -m gpt-5.6-luna "What is 1+1?"

Reduce the maximum output allowance:

    ./shell/openai-quota-fuse.sh run -o 256 "Answer in one sentence"

`run` conservatively estimates input tokens and adds `max-output-tokens` before selecting/checking quota. This is intentionally not an exact tokenizer; the guard prefers stopping early to overstating complimentary capacity.

## Inspection commands

These are useful when you want to inspect what `run` is doing:

    ./shell/openai-quota-fuse.sh status
    ./shell/openai-quota-fuse.sh models
    ./shell/openai-quota-fuse.sh select -t 8000
    ./shell/openai-quota-fuse.sh check -m gpt-5.6-sol -t 8000
    ./shell/openai-quota-fuse.sh status -r

## How policy is stored

Eligible models and quota-group limits change over time, so they live in the shared machine-readable `models.json` registry rather than being independently hard-coded. `models.json` stays broad for accounting, while `model-selection.json` contains the curated candidates used for automatic selection.

Quota groups describe complimentary quota capacity. They are not model-quality or task-difficulty profiles.

The Shell implementation deliberately counts all usage on registered models. This is conservative: it may stop early, but avoids overstating free capacity while incentive-specific accounting behavior is being validated.

## Periodic model-policy audit

    bash scripts/audit-model-policy.sh

`.github/workflows/model-policy-audit.yml` also runs weekly. The current review interval is 30 days.

See `spec/QUOTA_POLICY.md` for the language-neutral policy and [docs/TODO.md](docs/TODO.md) for remaining implementation work.
