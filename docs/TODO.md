# TODO

[日本語](../docs-ja/TODO.md)

## P0 — Shell CLI usability and policy selection

- [x] Keep `models.json` as the broad accounting registry and `model-selection.json` as the curated automatic-selection policy.
- [x] Add explicit long options with short aliases to `check` and `select` while retaining positional compatibility forms.
- [x] Support `--model/-m`, `--estimated-tokens/-t`, and caller-selected `--quality/-q`; default quality is `low`.
- [x] Keep complimentary quota groups separate from model quality/task difficulty.
- [ ] Decide whether legacy positional `check MODEL TOKENS` and `select TOKENS [MODEL ...]` should eventually be deprecated.

## P0 — `run` end-to-end flow

- [x] Add `run` as the primary user-facing command.
- [ ] Accept requests through `--input/-i` and stdin; positional prompt is currently supported.
- [x] Keep `OPENAI_API_KEY` separate from Organization Usage `OPENAI_ADMIN_KEY`.
- [ ] Document where to create the Organization Admin key and its intended administrative-only use.
- [x] Count the actual request input with `POST /responses/input_tokens` instead of the former byte-based local estimate.
- [x] Reserve `input_tokens + max_output_tokens` before inference.
- [x] Select/check a candidate against the conservative reservation before inference.
- [x] Execute the Responses API request only after the quota check succeeds.
- [x] Expose returned `usage.input_tokens`, `usage.output_tokens`, and `usage.total_tokens` in stderr diagnostics.
- [x] Add `--max-output-tokens/-o` and `--model/-m` to `run`.
- [ ] Add `--raw/-r` and `--input/-i` to `run`.
- [ ] Define behavior for tools, structured output, files/images, previous responses, and other Responses API fields without turning the Shell reference into a generic API wrapper prematurely.

## P0 — Annual prepaid-credit budget (next development priority)

- [ ] Implement this as the first follow-up after the current `run` work.
- [ ] Treat purchased API prepaid credits as a separate budget from complimentary daily token quota.
- [ ] Default policy: complimentary quota first; paid execution only while the configured annual paid-use budget remains below `$5`; block a request that would exceed the cap.
- [ ] Keep the annual paid-use budget configurable, with `$5` as the intended default.
- [ ] Estimate paid cost from current model input/output pricing before execution and account actual usage afterward when available.
- [ ] Prefer the configured `low` model order for ordinary paid fallback; explicit `high` remains caller-controlled.
- [ ] Determine the reliable source of truth for year-to-date paid spend; use explicit local/configured accounting rather than guessing if no official API suffices.
- [ ] Define annual reset boundary and persistent accounting format.
- [ ] Keep purchased-credit expiry handling separate from the annual cap; current purchased credits have a one-year expiry.
- [ ] Determine whether official APIs expose prepaid balance and expiry metadata; do not scrape Billing UI for runtime decisions.
- [ ] If reliable expiry metadata exists, design an optional burn-down policy for expiring credit.
- [ ] Never silently exceed the annual cap, even when prepaid credit exists.
- [ ] Define behavior for multiple grants/expiry dates and delayed billing/negative balance behavior.
- [ ] If expiry cannot be retrieved, allow explicit user configuration rather than guessing.

## P1 — Accounting validation

- [x] Validate `status --raw` with a real Admin API key for zero usage (`results: []`).
- [ ] Perform a live inference probe and inspect the resulting Usage API record once API billing is active.
- [ ] Determine whether Usage API `service_tier` can reliably distinguish incentive-covered traffic.
- [ ] Until validated, count all usage on registered eligible models so complimentary capacity is never overstated.
- [ ] Document sanitized observed Usage API examples.

## P1 — Model policy maintenance

- [ ] Re-check incentive eligibility, quota groups, availability/deprecation, and API pricing whenever the policy audit expires.
- [ ] Re-evaluate whether each automatic-selection candidate still has a reason to exist relative to newer models.
- [ ] Keep older active models in accounting even when removed from automatic selection.
- [ ] Add tests ensuring every automatic-selection candidate exists in `models.json`.

## P1 — Tests

- [ ] Add broader Shell tests with mocked Usage API responses.
- [ ] Cover UTC reset, tier limits, reserve calculation, unknown models, exhausted groups, and candidate fallback.
- [ ] Cover long/short CLI aliases and explicit candidate ordering.
- [x] Add a mocked test covering authoritative input-token counting and the documented `run` path, including actual usage diagnostics.
- [ ] Add annual paid-budget tests: free-first, below-cap fallback, cap blocking, annual reset, persistence, and explicit `high`.
- [ ] Add prepaid-credit expiry/burn-down tests if implemented.
- [ ] Run the same policy fixtures against future Python and Swift implementations.

## P2 — Python 3 implementation

- [ ] Implement `spec/QUOTA_POLICY.md`, sharing `models.json` and `model-selection.json`.
- [ ] Match useful Shell semantics while keeping the Python API idiomatic.
- [ ] Implement the same conservative `run` reservation behavior.

## P2 — Swift 6 implementation

- [ ] Add a Swift Package implementing the same quota policy.
- [ ] Share or generate strongly typed data from the machine-readable registries.
- [ ] Keep networking and policy logic separable.
- [ ] Implement the same conservative reservation behavior.

## Design constraints

- Complimentary quota is always consumed first.
- Paid fallback is bounded by the configured annual cap; intended default is `$5` per year.
- Quota checks must not spend an inference call merely to choose a model. Input-token counting is a non-inference Responses API operation.
- Complimentary quota groups are not model-quality/task-difficulty profiles.
- Current OpenAI primary documentation and observed API behavior take precedence over stale assumptions.
- `spec/QUOTA_POLICY.md` remains the language-neutral behavioral source of truth.
