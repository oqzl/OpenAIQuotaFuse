# OpenAIQuotaFuse

[日本語](README-ja.md)

OpenAIQuotaFuse is an OpenAI-specific quota guard intended to keep API usage inside the complimentary daily token quota available to eligible data-sharing traffic.

The project will provide aligned implementations for Shell, Python 3, and Swift 6. The Shell CLI is the first reference implementation.

## Shell MVP

Requirements:

- Bash
- curl
- jq
- an OpenAI Admin API key with access to the Organization Usage API

Setup:

    cp .env.example .env
    $EDITOR .env

Check current conservative quota availability:

    ./shell/openai-quota-fuse.sh status

Inspect the raw Usage API response (useful while validating service-tier behavior):

    ./shell/openai-quota-fuse.sh status --raw

Check whether an estimated request fits:

    ./shell/openai-quota-fuse.sh check gpt-5.6-sol 8000

Select the first model, in caller-defined preference order, that has enough quota:

    ./shell/openai-quota-fuse.sh select 8000 \
      gpt-5.6-sol \
      gpt-5.6-luna \
      gpt-5.6-terra

The current Shell MVP deliberately counts all usage on eligible models. This is conservative: it can stop early, but avoids overstating free capacity while incentive-specific accounting behavior is being validated against real Usage API responses.

See `spec/QUOTA_POLICY.md` for the language-neutral policy.
