# Quota policy

## Goal

OpenAIQuotaFuse normally keeps inference inside OpenAI's complimentary daily token quota for eligible data-sharing traffic. When no complimentary candidate can fit a request, an explicitly bounded local annual paid budget may be used. The intended default is `$5` per UTC calendar year.

## Complimentary reset boundary

The complimentary counter resets at 00:00 UTC every day.

## OpenAI policy data

`models.json` is the broad accounting registry for eligible model IDs, shared quota groups, tier limits, source, and review date. `model-selection.json` contains the smaller curated automatic-selection policy, paid fallback order, and reviewed prices used for the local hard cap.

Runtime scraping of OpenAI documentation or Billing UI is not part of quota decisions. Current OpenAI primary documentation takes precedence when the checked-in snapshot is stale.

## Request boundary

A request must reserve enough capacity for the whole request. For `run`, input tokens are counted with `POST /v1/responses/input_tokens` and `max_output_tokens` is added before inference.

## Conservative complimentary accounting

The Shell implementation sums all completion usage for models registered in each quota group. This may understate remaining complimentary quota, but it avoids falsely claiming free capacity until incentive-specific Usage API behavior is validated.

A configurable percentage of each daily quota is unavailable as a safety reserve. Default: 5%.

    available = max(0, quota - accounted_usage - safety_reserve)

## Complimentary model selection

Default `low`:

    gpt-5.6-terra
    gpt-5.6-luna
    gpt-5.6-sol

Explicit `high`:

    gpt-5.6-sol
    gpt-5.6-terra
    gpt-5.6-luna

Complimentary ordering optimizes capability per shared quota token rather than API dollar price. Terra therefore precedes Luna while they share the same high-volume token pool.

## Annual paid fallback

Paid fallback is separate from complimentary quota and is attempted only after the complimentary path cannot fit the request. `OPENAI_ANNUAL_PAID_BUDGET_USD` controls the hard local cap; the default is `$5`, and `0` disables paid fallback.

Default paid `low` order is cost-aware:

    gpt-5.6-luna
    gpt-5.6-terra
    gpt-5.6-sol

Explicit `high` remains Sol-first:

    gpt-5.6-sol
    gpt-5.6-terra
    gpt-5.6-luna

Before a paid inference, the implementation counts input tokens for the paid candidate and computes a worst-case dollar reservation using current checked-in input/output prices and `max_output_tokens`. Long-context price multipliers documented by OpenAI are included. A request is blocked if:

    year_to_date_local_spend + request_reservation > annual_cap

The reservation is persisted before inference. On a successful response, it is reconciled to actual `usage.input_tokens` and `usage.output_tokens`. If the inference outcome is unknown because the request fails after dispatch, the reservation remains charged locally; this intentionally fails safe rather than silently risking the annual cap.

The persistent ledger is local JSON, defaulting to:

    ${XDG_STATE_HOME:-$HOME/.local/state}/openai-quota-fuse/paid-usage.json

`OPENAI_QUOTA_FUSE_PAID_LEDGER` may override the path. Events are tagged with the UTC calendar year, so January 1 UTC starts a new annual budget without deleting historical records. A filesystem lock serializes paid reservations from concurrent local CLI processes sharing the ledger.

This ledger is the source of truth for the OpenAIQuotaFuse annual cap. It does not claim to equal OpenAI's billing ledger, which may include unrelated clients, delayed billing, credits, tool-call charges, or other products.

## Prepaid credits and expiry

Purchased prepaid credits are a billing balance, not the OpenAIQuotaFuse annual budget. OpenAI currently documents purchased credits as expiring after one year and notes that delayed billing can produce a negative balance.

No reliable documented runtime API for prepaid balance plus grant-level expiry metadata is currently used by this project. The Shell implementation therefore does not scrape Billing UI, infer expiry dates, or implement automatic expiry burn-down. If a future official API exposes reliable grant/expiry metadata, burn-down may be added as an optional policy without weakening the annual cap.

## Responses API scope

The Shell reference supports plain text input, model/quality selection, `max_output_tokens`, and raw response output. Tools, structured-output schemas, files/images, previous responses, and arbitrary Responses API fields are intentionally unsupported until their quota and paid-cost semantics are explicitly defined. The Shell reference is not a generic Responses API proxy.

## CLI option conventions

Every long-form command-line option must have a short alias. Canonical options include:

    --quality, -q
    --input, -i
    --model, -m
    --estimated-tokens, -t
    --max-output-tokens, -o
    --raw, -r
    --help, -h
    --version, -v

`run --input TEXT`, `run --input -`, and non-TTY stdin are supported. Positional prompt input remains convenient for `run`.

Legacy positional `check MODEL TOKENS` and `select TOKENS [MODEL ...]` are compatibility forms for 0.x. Long/short options are canonical and the positional compatibility forms are planned for removal at 1.0.
