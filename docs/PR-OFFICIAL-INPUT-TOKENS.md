# Official input-token counting implementation note

`run` now calls `POST /v1/responses/input_tokens` before inference and reserves the returned `input_tokens + max_output_tokens` against complimentary quota.

Automatic selection initially counts against the first candidate in the selected quality profile. If quota selection falls through to a different candidate, input tokens are counted again for the actual selected model and the quota check is repeated before inference. This avoids assuming tokenization is identical across candidates.

The completed Responses API result is also inspected for `usage.input_tokens`, `usage.output_tokens`, and `usage.total_tokens`; these values are emitted to stderr for diagnostics.

The mock test intercepts all `curl` calls and requires no live credentials. Live API validation remains separate from this deterministic test.
