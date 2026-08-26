# OpenAIQuotaFuse

[日本語](README-ja.md)

OpenAIQuotaFuse is a quota guard for calling the OpenAI API while conservatively staying inside the complimentary daily token quota available to eligible data-sharing traffic, with a small hard-capped paid fallback.

## Quick start

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git
    cd OpenAIQuotaFuse
    cp .env.example .env
    $EDITOR .env
    python3 python/openai_quota_fuse.py run "How high is Mount Fuji?"

The Python 3 CLI is the canonical implementation and the execution surface used by the Codex plugin. It uses only the Python standard library. Unix users can also call `./shell/openai-quota-fuse.sh`; it is a thin Bash compatibility wrapper that delegates to the same Python CLI, so it requires Bash and Python 3 but does not maintain separate quota logic.

`OPENAI_ADMIN_KEY` is used only for Organization Usage and Costs. Organization Owners can create an Admin API key from the API Platform dashboard under Organization settings → Admin keys: https://platform.openai.com/settings/organization/admin-keys . Keep it separate from the normal project `OPENAI_API_KEY`, which is used for input-token counting and inference.

## Codex plugin

This repository also contains a Codex plugin manifest and bundled `quota-fuse` Skill. The plugin lets Codex inspect quota/costs, select a policy-approved model, or dispatch a secondary OpenAI API request through the Fuse policy.

It does not replace the model already running the current Codex turn. Fuse governs API calls that Codex explicitly dispatches through the plugin-facing Python CLI.

See [docs/CODEX_PLUGIN.md](docs/CODEX_PLUGIN.md) for local marketplace installation and usage.

## Selection policy

`run` defaults to `auto` quality. Before normal model selection, a small difficulty classifier may route an ordinary task to `low` or promote a difficult task to `high` while staying inside complimentary quota.

    python3 python/openai_quota_fuse.py run "Translate to Japanese: good morning"
    # quality: auto -> low

    python3 python/openai_quota_fuse.py run \
      "Compare three migration strategies for a distributed system and design a staged plan including rollback after failures"
    # quality: auto -> high

The classifier uses `gpt-5.6-luna`, low reasoning effort, and the Responses API minimum of 16 output tokens. Its own `input_tokens + max_output_tokens` must fit complimentary quota before the classifier is called. Input-token counting sends only fields accepted by `/responses/input_tokens`; response-only fields such as `max_output_tokens` are not sent there. If classification cannot run or returns anything other than `low` / `high`, OpenAIQuotaFuse does not spend money on routing; it falls back to `low`.

Explicit choices override auto routing:

    -q low   # fixed low; no classifier
    -q high  # fixed high; no classifier
    -m MODEL # fixed model; no classifier

`select` has no prompt to classify, so its default remains `low`.

Complimentary `low` order is:

    gpt-5.6-terra → gpt-5.6-luna → gpt-5.6-sol

Terra and Luna share the high-volume complimentary token quota, so Terra is preferred there for capability per quota token. `high` is Sol-first:

    gpt-5.6-sol → gpt-5.6-terra → gpt-5.6-luna

If no complimentary candidate can fit the conservative reservation, `run` may use the annual paid budget. Its default is `$5` and can be changed or disabled:

    OPENAI_ANNUAL_PAID_BUDGET_USD=5
    OPENAI_ANNUAL_PAID_BUDGET_USD=0   # disable paid fallback

The ordinary paid order is cost-aware and separate from complimentary selection:

    gpt-5.6-luna → gpt-5.6-terra → gpt-5.6-sol

The annual cap uses the official Organization Costs API as its spend floor. This means API calls made outside OpenAIQuotaFuse are included after OpenAI reports them. Because Costs reporting can lag behind a just-finished request, OpenAIQuotaFuse also keeps a conservative local guard for recent paid requests. This can temporarily double-count some spend, which is intentional: avoiding accidental paid overrun is preferred over maximizing the `$5` budget.

Inspect the current accounting with:

    python3 python/openai_quota_fuse.py costs
    python3 python/openai_quota_fuse.py costs -r

The normal output separates `official_costs_usd`, the recent local lag guard, and the effective amount used for budget checks. The Costs endpoint is paginated from January 1 00:00 UTC so a full UTC calendar year is covered.

OpenAI does not currently provide a documented runtime API here for reliable prepaid-credit balance/expiry metadata, so OpenAIQuotaFuse does not scrape the Billing UI or guess. Purchased-credit expiry is therefore not used for runtime selection. OpenAI currently documents purchased credits as expiring after one year.

## `run`

Before inference, `run` calls `POST /v1/responses/input_tokens`, then reserves:

    input_tokens + max_output_tokens

`-o/--max-output-tokens` is validated locally against the current GPT-5.6 Responses API bounds: 16 through 128,000 tokens. Invalid values are rejected before any API call.

Start with an ordinary question:

    python3 python/openai_quota_fuse.py run "How high is Mount Fuji?"

Use a different input form:

    python3 python/openai_quota_fuse.py run -i "What is the difference between HTTP 404 and 500?"
    printf '%s\n' "What is the capital of Japan?" | python3 python/openai_quota_fuse.py run
    python3 python/openai_quota_fuse.py run -i - < prompt.txt

Control routing or reasoning explicitly:

    python3 python/openai_quota_fuse.py run -q low "Translate to English: りんご"
    python3 python/openai_quota_fuse.py run -q high \
      "Explain the CAP theorem and its practical system-design tradeoffs with concrete examples"
    python3 python/openai_quota_fuse.py run -m gpt-5.6-luna -o 256 \
      "Explain three differences between TCP and UDP"
    python3 python/openai_quota_fuse.py run -e high \
      "One of 12 coins has a different weight. Find it using at most three balance-scale weighings"

Inspect the complete Responses API JSON:

    python3 python/openai_quota_fuse.py run -r "How high is Mount Fuji?"

### Context

`-c/--context FILE` adds a UTF-8 text file to the current user request as context. The option is repeatable. Quota selection counts the full effective input including the supplied context files.

    python3 python/openai_quota_fuse.py run \
      -c AGENTS.md \
      -c README.md \
      -c python/openai_quota_fuse.py \
      "Review this implementation and identify the highest-priority design improvements"

The current implementation intentionally accepts explicit text files only. It does not implicitly recurse through directories, expand globs, accept binary files, or upload content to the OpenAI Files API / File Search.

### Sessions

`-s/--session NAME` stores the most recent successful Responses API `response_id` locally. The next invocation with the same name passes that ID as `previous_response_id` to both input-token counting and inference, preserving conversation history while keeping quota accounting aligned with the actual request.

    python3 python/openai_quota_fuse.py run -s design \
      -c python/openai_quota_fuse.py \
      "Review this implementation"

    python3 python/openai_quota_fuse.py run -s design \
      "Expand the three highest-priority findings from the previous answer"

Session state defaults to `~/.local/state/openai-quota-fuse/sessions/` and can be moved with `OPENAI_QUOTA_FUSE_SESSION_DIR`. OpenAIQuotaFuse stores only the latest response ID and update timestamp; it does not duplicate the conversation text locally. If the referenced OpenAI response is no longer available, continuing that session will fail.

`-q/--quality` accepts `auto`, `low`, or `high` for `run`; omitting it means `auto`. `-e/--effort` controls Responses API `reasoning.effort` independently. `quality` chooses the model order while `effort` controls how much reasoning the selected model performs. Supported effort values are `none`, `low`, `medium`, `high`, `xhigh`, and `max`. Omitting effort leaves the model/API default unchanged.

`-r/--raw` changes stdout from extracted output text to the complete Responses API JSON. Classifier, quota, model, and usage diagnostics remain on stderr.

The canonical Python implementation supports plain text input, explicit text context, and named sessions in addition to model/quality/effort/max-output/raw controls. Tools, structured-output schemas, images, and arbitrary Responses API fields remain out of scope until OpenAIQuotaFuse has explicit quota/accounting semantics for them.

Legacy positional `check MODEL TOKENS` and `select TOKENS [MODEL ...]` remain compatible throughout 0.x. The canonical documented forms are long/short options; positional compatibility is planned for removal at 1.0 rather than accumulating indefinitely.

## Inspection commands

    python3 python/openai_quota_fuse.py status
    python3 python/openai_quota_fuse.py costs
    python3 python/openai_quota_fuse.py models
    python3 python/openai_quota_fuse.py select -t 8000
    python3 python/openai_quota_fuse.py check -m gpt-5.6-sol -t 8000
    python3 python/openai_quota_fuse.py status -r

The equivalent Shell entry point remains available through `./shell/openai-quota-fuse.sh`; it delegates directly to the Python CLI.

## Policy and maintenance

Eligible models and quota-group limits live in `models.json`; curated complimentary/paid selection and classifier policy live in `model-selection.json`. Current OpenAI primary documentation takes precedence over these snapshots when they become stale.

The canonical implementation deliberately counts all usage on registered models until incentive-specific Usage API behavior is validated. Organization Costs is used for financial accounting because OpenAI recommends the Costs endpoint for spend that should reconcile to billing. `bash scripts/audit-model-policy.sh` checks model-policy review age; the GitHub workflow also runs weekly.

See `spec/QUOTA_POLICY.md` for language-neutral policy and [docs/TODO.md](docs/TODO.md) for remaining work.
