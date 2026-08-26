# TODO

[日本語](../docs-ja/TODO.md)

This document tracks implementation work that remained after PR #1 established the Shell MVP and shared quota policy.

## P0 — Shell CLI usability and policy selection

- [x] Keep `models.json` as the broad accounting registry and `model-selection.json` as the curated automatic-selection policy.
- [x] Add explicit long options with short aliases to `check` and `select` while retaining the original positional forms for compatibility.
- [x] Support `--model/-m` and `--estimated-tokens/-t` in the Shell CLI.
- [x] Keep complimentary quota groups separate from model quality or task-difficulty concepts. Quota groups represent capacity/accounting only.
- [x] Add caller-selected `--quality/-q` as a task/quality hint, with `low` as the default and explicit `high` as a separate selection profile from quota groups. Model selection does not spend an extra inference call.
- [ ] Decide whether the legacy positional `check MODEL TOKENS` and `select TOKENS [MODEL ...]` forms should eventually be deprecated.

## P0 — `run` end-to-end flow

- [x] Add `run` as the primary user-facing command.
- [ ] Accept the real request through `--input/-i`; support stdin for pipeline use. The current implementation accepts the prompt as a positional argument.
- [x] Keep the normal inference key (`OPENAI_API_KEY`) separate from `OPENAI_ADMIN_KEY` used for Organization Usage API access.
- [ ] Document that `OPENAI_ADMIN_KEY` is created from the OpenAI Platform organization Admin Keys page and should only be used for administrative/Usage API access.
- [ ] Count request input with `POST /responses/input_tokens`; do not estimate token count locally when the API can return the authoritative count. The current implementation uses a conservative byte-based local estimate.
- [x] Add `max_output_tokens` to the current local input-token estimate and reserve that conservative requirement before inference.
- [x] Select the first candidate whose quota group can accommodate the conservative reservation.
- [x] Execute the Responses API request only after the quota check succeeds.
- [ ] Expose actual returned `usage.input_tokens`, `usage.output_tokens`, and `usage.total_tokens` in diagnostics.
- [x] Add `--max-output-tokens/-o` and `--model/-m` to `run`.
- [ ] Add `--raw/-r` and `--input/-i` to `run`.
- [ ] Define behavior for tools, structured output, files/images, previous responses, and other Responses API fields without turning the Shell reference into a generic API wrapper prematurely.

## P0 — Annual prepaid-credit budget (next development priority)

- [ ] Implement this as the first follow-up after the current `run` work.
- [ ] Treat purchased API prepaid credits as a separate budget from complimentary daily token quota.
- [ ] Default policy: use complimentary quota first; when complimentary quota cannot cover the request, allow paid execution only while the configured annual paid-use budget remains below `$5`; block once the annual cap would be exceeded.
- [ ] Keep the annual paid-use budget explicitly configurable, with `$5` as the intended default policy rather than an unbounded paid fallback.
- [ ] Estimate the paid cost of a request using the selected model's current API input/output pricing before execution, and account actual usage after execution when available.
- [ ] Prefer the configured `low` model order for ordinary paid fallback so the annual budget is consumed conservatively; explicit `high` remains caller-controlled.
- [ ] Determine the source of truth for year-to-date paid spend. Prefer an official API; if it cannot be derived reliably, use explicit local/configured accounting rather than guessing.
- [ ] Define the annual reset boundary and persistence format so usage is not reset accidentally between CLI invocations.
- [ ] Keep purchased-credit expiry handling separate from the annual cap: OpenAI currently documents a $5 minimum purchase and a one-year expiry for purchased credits.
- [ ] Determine whether an official API exposes prepaid-credit balance, individual grant/purchase expiry, or enough billing data to derive them reliably. Do not scrape the billing UI for runtime policy decisions.
- [ ] If balance and expiry can be obtained reliably, design an optional credit burn-down policy so prepaid credit that would otherwise expire can be deliberately consumed before expiry.
- [ ] Never silently exceed the configured annual cap, even when prepaid credit exists. Any exception must be explicitly enabled by the caller.
- [ ] Define behavior for multiple credit grants/purchases with different expiry dates and for OpenAI's documented delayed billing / possible negative balance behavior.
- [ ] If expiry cannot be retrieved through a supported API, allow explicit user configuration of remaining prepaid budget and expiry date rather than guessing.

## P1 — Accounting validation

- [x] Perform a live `status --raw` validation with a real Admin API key for the zero-usage case; the observed daily bucket returned `results: []` as expected.
- [ ] Perform a live inference probe and inspect the resulting Usage API record once API billing is active.
- [ ] Inspect actual `service_tier` values and determine whether the Usage API can distinguish incentive-covered traffic reliably enough to tighten accounting.
- [ ] Until validated, continue counting all usage on registered eligible models so remaining complimentary capacity is never overstated.
- [ ] Document observed Usage API response examples with secrets and organization identifiers removed.

## P1 — Model policy maintenance

- [ ] Re-check incentive eligibility, quota-group placement, availability/deprecation, and API pricing whenever the policy audit expires.
- [ ] Evaluate whether each automatic-selection candidate still has a reason to exist relative to newer models in the same quota group.
- [ ] Keep older active models in accounting even when they are removed from automatic selection.
- [ ] Add tests ensuring every automatic-selection candidate exists in `models.json`.
- [ ] Consider machine-readable rationale/price metadata only if it materially improves the recurring policy audit.

## P1 — Tests

- [ ] Add Shell tests with mocked Usage API responses.
- [ ] Cover UTC day reset, tier 1–2 vs tier 3–5 limits, reserve calculation, unknown models, exhausted groups, and candidate fallback.
- [ ] Cover long/short CLI aliases and explicit candidate ordering.
- [ ] Add mocked tests for input-token counting and the currently documented `run` end-to-end path.
- [ ] Add annual paid-budget tests: free-quota-first behavior, below-cap paid fallback, request-would-exceed-cap blocking, annual reset, persistence, and explicit `high` selection.
- [ ] Add prepaid-credit expiry/burn-down tests if expiry support is implemented, including expiry boundary and unavailable billing metadata.
- [ ] Run the same policy fixtures against future Python and Swift implementations.

## P2 — Python 3 implementation

- [ ] Implement the language-neutral policy from `spec/QUOTA_POLICY.md`.
- [ ] Share `models.json` and `model-selection.json` rather than duplicating model/quota data.
- [ ] Match Shell exit/error semantics where useful, while keeping the Python API idiomatic.
- [ ] Implement the same conservative `run` reservation behavior.

## P2 — Swift 6 implementation

- [ ] Add a Swift Package implementing the same quota policy.
- [ ] Share the machine-readable registry/selection files or generate strongly typed data from them.
- [ ] Keep networking and policy logic separable so applications can present their own UI.
- [ ] Implement the same conservative reservation behavior.

## Design constraints

- Complimentary quota is always consumed first.
- Paid fallback is bounded by the configured annual paid-use cap; the intended default is `$5` per year.
- Quota checks must not spend an inference call merely to decide which model to use.
- Complimentary quota groups must not be presented as model-quality or task-difficulty profiles.
- Current OpenAI primary documentation and observed API behavior take precedence over stale repository assumptions.
- The language-neutral policy in `spec/QUOTA_POLICY.md` remains the behavioral source of truth.
