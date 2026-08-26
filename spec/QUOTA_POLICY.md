# Quota policy

## Goal

OpenAIQuotaFuse normally keeps inference inside OpenAI's complimentary daily token quota for eligible data-sharing traffic. When no complimentary candidate can fit a request, an explicitly bounded annual paid budget may be used. The intended default is `$5` per UTC calendar year.

## Complimentary reset boundary

The complimentary counter resets at 00:00 UTC every day.

## OpenAI policy data

`models.json` is the broad accounting registry for eligible model IDs, shared quota groups, tier limits, source, and review date. `model-selection.json` contains the smaller curated automatic-selection policy, automatic quality classifier policy, paid fallback order, and reviewed prices used for request reservations.

Runtime scraping of OpenAI documentation or Billing UI is not part of quota decisions. Current OpenAI primary documentation takes precedence when the checked-in snapshot is stale.

## Request boundary

A request must reserve enough capacity for the whole request. For `run`, input tokens are counted with `POST /v1/responses/input_tokens` and `max_output_tokens` is added before inference.

Internal automatic-quality classification is a separate request and must independently reserve its own counted input tokens plus classifier `max_output_tokens` before dispatch.

## Conservative complimentary accounting

The Shell implementation sums all completion usage for models registered in each quota group. This includes usage generated outside OpenAIQuotaFuse when it appears in Organization Usage. This may understate remaining complimentary quota, but it avoids falsely claiming free capacity until incentive-specific Usage API behavior is validated.

A configurable percentage of each daily quota is unavailable as a safety reserve. Default: 5%.

    available = max(0, quota - accounted_usage - safety_reserve)

## Automatic run quality

`run` defaults to `quality=auto`. `select` remains `low` by default because `select` has no prompt from which to classify task difficulty.

For `run` auto quality, OpenAIQuotaFuse may issue one small classifier request before ordinary model selection. The checked-in policy currently uses:

    classifier model: gpt-5.6-luna
    reasoning effort: low
    max output tokens: 8
    allowed output: low | high
    fallback: low

The classifier is instructed to choose `high` for work that materially benefits from stronger model routing, including substantial multi-step reasoning, architecture/design judgment, nontrivial debugging or root-cause analysis, broad repository/code changes, several interacting constraints, mathematical/logical verification, or consequential comparison/judgment. Straightforward extraction, translation, summarization, formatting, known procedures, and small/local edits should remain `low`.

The classifier itself is quota-checked. Its input is counted with `/responses/input_tokens`, classifier max output is added, and the request is sent only when that reservation fits complimentary quota. Automatic classification never uses annual paid fallback merely to decide quality. If token counting fails, complimentary classifier quota is unavailable, the classifier request fails, or the classifier output is not exactly `low` or `high`, the configured fallback quality is used.

Explicit caller intent wins over automatic classification:

- `run -q low` bypasses classification and uses `low`.
- `run -q high` bypasses classification and uses `high`.
- `run -m MODEL` bypasses classification because model selection is already explicit.

Classifier routing diagnostics are written to stderr and do not replace the user's normal response on stdout.

## Complimentary model selection

Resolved `low`:

    gpt-5.6-terra
    gpt-5.6-luna
    gpt-5.6-sol

Resolved `high`:

    gpt-5.6-sol
    gpt-5.6-terra
    gpt-5.6-luna

Complimentary ordering optimizes capability per shared quota token rather than API dollar price. Terra therefore precedes Luna while they share the same high-volume token pool.

## Reasoning effort

`run --effort/-e` maps directly to Responses API `reasoning.effort`. It is independent from `--quality/-q`:

- `quality` determines model preference order, either explicitly or after auto classification.
- `effort` controls reasoning behavior inside the selected model.

Supported values are `none`, `low`, `medium`, `high`, `xhigh`, and `max`. When omitted, OpenAIQuotaFuse omits `reasoning.effort` from the user request so the current model/API default remains authoritative. The internal classifier has its own separately configured reasoning effort.

## Annual paid fallback

Paid fallback is separate from complimentary quota and is attempted only after the complimentary path cannot fit the user request. `OPENAI_ANNUAL_PAID_BUDGET_USD` controls the hard application cap; the default is `$5`, and `0` disables paid fallback.

Default paid `low` order is cost-aware:

    gpt-5.6-luna
    gpt-5.6-terra
    gpt-5.6-sol

Resolved `high` is Sol-first:

    gpt-5.6-sol
    gpt-5.6-terra
    gpt-5.6-luna

Before a paid user inference, the implementation counts input tokens for the paid candidate and computes a worst-case dollar reservation using current checked-in input/output prices and `max_output_tokens`. Long-context price multipliers documented by OpenAI are included.

### Organization Costs as the financial source of truth

Year-to-date actual spend is read from the official `GET /v1/organization/costs` endpoint using the Organization Admin key. OpenAI documents the Costs endpoint as the appropriate financial view for spend that should reconcile to billing.

The Shell implementation starts at January 1 00:00 UTC, requests one-day buckets, follows `next_page`, and sums USD `amount.value` across the full UTC calendar year. Therefore API spend made through other scripts, applications, or direct `curl` calls contributes to the next paid-budget decision after OpenAI reports it in Organization Costs.

The reported Organization Costs amount is the authoritative financial floor. OpenAIQuotaFuse does not attempt to infer which reported cost came from this CLI.

### Reporting-delay guard

A just-finished paid request may not yet appear in Organization Costs. To avoid opening a gap between local dispatch and financial reporting, OpenAIQuotaFuse keeps a local persistent guard for recent paid requests. Successful requests use actual response usage; requests whose inference outcome is unknown retain their worst-case reservation.

The effective spend used for a new paid request is conservatively:

    official_year_to_date_costs
    + recent_local_paid_guard
    + new_request_reservation

A request is blocked when this exceeds the configured annual cap.

Recent completed local requests are guarded for seven days. This can temporarily double-count spend once Costs has already incorporated the same request. That conservatism is intentional: avoiding an accidental paid overrun has priority over fully utilizing the annual budget. Unknown-outcome reservations remain guarded rather than silently disappearing.

The local JSON ledger defaults to:

    ${XDG_STATE_HOME:-$HOME/.local/state}/openai-quota-fuse/paid-usage.json

`OPENAI_QUOTA_FUSE_PAID_LEDGER` may override the path. A filesystem lock serializes paid reservations from concurrent local CLI processes sharing the ledger.

`openai-quota-fuse.sh costs` exposes the official year-to-date Costs amount, the recent local guard, the effective budget spend, and the configured cap. `costs --raw/-r` prints the raw paginated Costs responses.

## Prepaid credits and expiry

Purchased prepaid credits are a billing balance, not the OpenAIQuotaFuse annual budget. OpenAI currently documents purchased credits as expiring after one year and notes that delayed billing can produce a negative balance.

No reliable documented runtime API for prepaid balance plus grant-level expiry metadata is currently used by this project. The Shell implementation therefore does not scrape Billing UI, infer expiry dates, or implement automatic expiry burn-down. If a future official API exposes reliable grant/expiry metadata, burn-down may be added as an optional policy without weakening the annual cap.

## Responses API scope

The Shell reference supports plain text user input, model/quality selection, automatic quality classification, `reasoning.effort`, `max_output_tokens`, and raw response output. Tools, structured-output schemas, files/images, previous responses, and arbitrary user-supplied Responses API fields are intentionally unsupported until their quota and paid-cost semantics are explicitly defined. The internal classifier may use fixed checked-in request fields such as `instructions`; this does not make the Shell reference a generic Responses API proxy.

## CLI option conventions

Every long-form command-line option must have a short alias. Canonical options include:

    --quality, -q
    --effort, -e
    --input, -i
    --model, -m
    --estimated-tokens, -t
    --max-output-tokens, -o
    --raw, -r
    --help, -h
    --version, -v

For `run`, `--quality/-q` accepts `auto`, `low`, and `high`, with `auto` as the default. For prompt-less `select`, only actual selection profiles (`low` / `high`) apply and the default remains `low`.

`run --input TEXT`, `run --input -`, and non-TTY stdin are supported. Positional prompt input remains convenient for `run`.

Legacy positional `check MODEL TOKENS` and `select TOKENS [MODEL ...]` are compatibility forms for 0.x. Long/short options are canonical and the positional compatibility forms are planned for removal at 1.0.
