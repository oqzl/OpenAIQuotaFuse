# TODO

[日本語](../docs-ja/TODO.md)

## P0 — Shell CLI usability and policy selection

- [x] Keep `models.json` as the broad accounting registry and `model-selection.json` as the curated automatic-selection policy.
- [x] Add explicit long options with short aliases to `check` and `select` while retaining positional compatibility forms.
- [x] Support `--model/-m`, `--estimated-tokens/-t`, and caller-selected `--quality/-q`.
- [x] Keep `select` default quality at `low`, while `run` defaults to prompt-aware `auto` quality.
- [x] Keep complimentary quota groups separate from model quality/task difficulty.
- [x] Prefer Terra over Luna for ordinary complimentary-quota execution while both consume the same high-volume token quota.
- [x] Legacy positional `check MODEL TOKENS` and `select TOKENS [MODEL ...]` remain supported through 0.x and are planned for removal at 1.0; option forms are canonical.

## P0 — Automatic run quality

- [x] Add `run -q auto` and make it the `run` default without changing prompt-less `select` semantics.
- [x] Use a small Luna classifier to return exactly `low` or `high` before normal model selection.
- [x] Keep explicit `-q low`, `-q high`, and `-m MODEL` stronger than automatic classification and bypass the classifier.
- [x] Account for classifier input plus max output against complimentary quota before dispatch.
- [x] Send only fields supported by `/responses/input_tokens` when counting classifier input; do not reuse response-only fields such as `max_output_tokens`.
- [x] Never use paid fallback merely to classify quality; use configured `low` fallback if the classifier cannot run or returns invalid output.
- [x] Emit classifier/model-routing diagnostics on stderr.
- [x] Keep classifier model, effort, output cap, instructions, and fallback in `model-selection.json`.
- [x] Add mocked coverage for auto→high routing and explicit override bypass.
- [ ] Add a reusable fixture set of representative easy/hard prompts and periodically evaluate classifier accuracy before changing classifier model/prompt.

## P0 — `run` end-to-end flow

- [x] Add `run` as the primary user-facing command.
- [x] Accept requests through `--input/-i`, `--input -`, non-TTY stdin, and positional prompt input.
- [x] Keep `OPENAI_API_KEY` separate from Organization Usage/Costs `OPENAI_ADMIN_KEY`.
- [x] Document where Organization Owners create the Admin API key and its administrative-only use.
- [x] Count actual request input with `POST /responses/input_tokens`.
- [x] Reserve `input_tokens + max_output_tokens` before inference.
- [x] Select/check a candidate against the conservative reservation before inference.
- [x] Execute the Responses API request only after the quota/budget check succeeds.
- [x] Expose returned usage in stderr diagnostics.
- [x] Add `--max-output-tokens/-o`, `--model/-m`, `--raw/-r`, and `--input/-i` to `run`.
- [x] Add `--effort/-e` for Responses API `reasoning.effort`, independent of model-selection `--quality/-q`.
- [x] Add repeatable `--context/-c FILE` for explicit UTF-8 text context and include that full effective input in token counting.
- [x] Add named `--session/-s NAME` continuation by persisting the latest response ID and passing `previous_response_id` to both token counting and inference.
- [x] Keep the supported Responses scope explicit: plain text, explicit text context, named sessions, and model/quality/effort/max-output/raw controls; tools, structured output, images, arbitrary fields, directory recursion, and implicit file upload remain unsupported until quota/cost semantics are defined.
- [ ] Treat `status=incomplete` as a first-class non-success result: expose `incomplete_details.reason` and reasoning/visible token diagnostics without presenting truncated output as a normal completion.
- [ ] Add explicit continuation for an incomplete response, e.g. `continue [RESPONSE_ID]`; when the ID is omitted, reuse the most recent locally recorded response that ended because of `max_output_tokens`.
- [ ] Route continuation through the same `/responses/input_tokens` accounting, complimentary-quota reservation, model selection, and paid-budget fuse as a normal request; do not auto-continue without user action.
- [ ] Add mocked E2E coverage for incomplete detection, persisted continuation state, explicit/default response IDs, and continuation quota/budget blocking.

## P0 — Annual prepaid-credit budget

- [x] Treat intentional paid fallback as a separate budget from complimentary daily token quota.
- [x] Default policy: complimentary quota first; paid execution only while the UTC-calendar-year budget remains below `$5`; block a request whose worst-case reservation would exceed the cap.
- [x] Make the annual paid-use budget configurable with `$5` default and `0` as disable.
- [x] Estimate paid cost from reviewed model input/output pricing before execution and reconcile actual response usage afterward.
- [x] Keep paid-fallback ordering separate: ordinary `low` is Luna → Terra → Sol; explicit `high` remains Sol-first.
- [x] Use the official Organization Costs endpoint as the financial year-to-date spend floor, so direct API usage outside OpenAIQuotaFuse is included after reporting.
- [x] Follow Costs pagination from January 1 00:00 UTC and sum USD amounts across the full UTC calendar year.
- [x] Keep a conservative local lag guard for recent QuotaFuse paid requests; unknown-outcome reservations remain charged rather than silently disappearing.
- [x] Add `costs` / `costs --raw` inspection for official spend, local guard, effective budget spend, and raw Costs pages.
- [x] Keep purchased-credit expiry separate from the annual cap; OpenAI currently documents purchased credits as expiring after one year.
- [x] Do not scrape Billing UI. No reliable documented runtime prepaid balance + grant-expiry API is currently used.
- [x] Do not implement expiry burn-down until reliable official expiry metadata exists.
- [x] Never intentionally exceed the annual cap: persist the worst-case reservation before dispatch; retain it when inference outcome is unknown.
- [x] If expiry metadata is unavailable, do not guess. Future explicit expiry configuration may be added only as an optional burn-down input.

## P1 — Accounting validation

- [x] Validate `status --raw` with a real Admin API key for zero usage (`results: []`).
- [ ] Perform a live inference probe and inspect the resulting Usage API record once API billing is active.
- [ ] Validate `costs` with a real Admin API key and record a sanitized year-to-date Costs response.
- [ ] Observe practical Costs reporting delay after a paid inference and revisit the conservative seven-day local guard if evidence supports a narrower bound.
- [ ] Determine whether Usage API `service_tier` can reliably distinguish incentive-covered traffic.
- [ ] Until validated, count all usage on registered eligible models so complimentary capacity is never overstated.
- [ ] Document sanitized observed Usage API examples.

## P1 — Model policy maintenance

- [ ] Re-check incentive eligibility, quota groups, availability/deprecation, and API pricing whenever the policy audit expires.
- [ ] Re-evaluate whether each automatic-selection candidate still has a reason to exist relative to newer models.
- [ ] Keep complimentary-quota ordering and paid-fallback ordering independently justified.
- [ ] Keep older active models in accounting even when removed from automatic selection.
- [ ] Add tests ensuring every automatic-selection candidate exists in `models.json`.

## P1 — Tests

- [x] Add Python unit tests for quota grouping/reserve arithmetic, pricing, output extraction, and paid-ledger guard behavior.
- [x] Add mocked HTTP E2E coverage for input token counting, input/stdin/raw, reasoning effort, auto quality routing, explicit classifier bypass, strict input-token payloads, text context, named sessions, Costs API spend, paid fallback, ledger completion, and annual-cap blocking.
- [x] Run Python syntax, unit, mocked E2E, and plugin-manifest JSON checks in CI on pull requests and `main` pushes.
- [x] Keep Shell CI as a wrapper smoke test only; Shell delegates to the Python implementation and must not duplicate policy tests.
- [ ] Cover UTC reset, tier limits, reserve calculation, unknown models, exhausted groups, and candidate fallback more deeply.
- [ ] Cover long/short CLI aliases and explicit candidate ordering.
- [ ] Add deeper annual-budget tests for annual reset, Costs pagination, legacy-ledger migration, and concurrent-process locking.
- [ ] Reuse the same policy fixtures for a future Swift implementation.

## P1 — Python 3 implementation

- [x] Implement the core `spec/QUOTA_POLICY.md` semantics using shared `models.json` and `model-selection.json`.
- [x] Match useful Shell CLI semantics for `run`, `status`, `costs`, `check`, `select`, and `models` using Python standard library networking and argument parsing.
- [x] Implement conservative reservation, auto-quality, reasoning effort, Organization Costs, annual paid fallback, and the local lag guard.
- [x] Make Python the canonical implementation and replace the former Shell implementation with a thin compatibility wrapper.
- [x] Add mocked HTTP end-to-end coverage to the Python implementation.

## P1 — Codex plugin

- [x] Add `.codex-plugin/plugin.json` and a bundled `quota-fuse` Skill.
- [x] Use Python as the plugin-facing and canonical execution surface; keep Shell only as a Unix compatibility wrapper.
- [x] Document local marketplace installation and credential setup in English/Japanese.
- [x] Explicitly document that the plugin governs secondary API calls dispatched through Fuse and cannot change the model already running the current Codex turn.
- [x] Validate plugin manifest JSON in CI.
- [ ] Add a stable standalone Codex plugin validator when one is available in the development environment.

## P2 — Swift 6 implementation

- [ ] Add a Swift Package implementing the same quota policy.
- [ ] Share or generate strongly typed data from the machine-readable registries.
- [ ] Keep networking and policy logic separable.
- [ ] Implement the same conservative reservation, auto-quality, reasoning-effort, Organization Costs, and annual paid-budget behavior.

## Design constraints

- Complimentary quota is always attempted first.
- Paid fallback is bounded by the configured annual cap; intended default is `$5` per UTC calendar year.
- Organization Costs is the financial spend floor; local paid accounting exists only to guard the reporting-delay window and unknown outcomes.
- Complimentary ordering optimizes capability per quota token; paid ordering optimizes capability/cost under a dollar budget.
- `run --quality auto` may spend one separately quota-checked complimentary inference call to classify task difficulty; it must never spend paid budget just to choose quality.
- Explicit `--quality low/high` and explicit `--model` bypass classification.
- `--quality` selects model preference; `--effort` controls reasoning inside the selected model.
- Complimentary quota groups are not model-quality/task-difficulty profiles.
- Current OpenAI primary documentation and observed API behavior take precedence over stale assumptions.
- `spec/QUOTA_POLICY.md` remains the language-neutral behavioral source of truth.
