# Quota policy

## Goal

OpenAIQuotaFuse should normally prevent inference requests that would exceed OpenAI's complimentary daily token quota for eligible data-sharing traffic. Small billing leakage caused by reporting delay or concurrent clients is tolerated operationally, but paid quota is not yet treated as an available fallback budget.

## Reset boundary

The complimentary counter resets at 00:00 UTC every day.

## OpenAI policy data

`models.json` is the repository's machine-readable snapshot of OpenAI's current complimentary-token policy data:

- eligible model IDs,
- each model's shared quota group,
- per-group daily limits for usage tiers 1-2 and 3-5,
- the primary-source URL,
- the date the snapshot was last reviewed.

Shell, Python 3, and Swift 6 implementations must read this shared registry rather than duplicating model lists or quota constants in source code.

The registry is not an OpenAI API response and can become stale. Changes to it must be checked against the current OpenAI primary documentation. Runtime scraping of the Help Center is deliberately not part of the quota decision path.

Models explicitly documented as shut down are omitted even if they remain visible in historical offer documentation.

## Request boundary

If a new request would make the running daily total exceed the relevant quota, OpenAI bills the entire request at normal rates. Therefore a client must reserve enough quota for the whole request, not merely its expected overage.

For `run`, input tokens are counted with the Responses input-token endpoint and `max_output_tokens` is added before inference.

## Conservative accounting

The Shell MVP sums all completion usage for models registered in each quota group. This may understate remaining complimentary quota if some registered-model traffic was not itself eligible for the data-sharing incentive, but it avoids falsely claiming free capacity.

A future implementation may use a more precise incentive-specific signal if OpenAI exposes one through a stable documented API contract.

## Safety reserve

A configurable percentage of the daily quota is treated as unavailable. Default: 5%.

Available capacity is:

    max(0, quota - accounted_usage - safety_reserve)

A candidate model can be selected only when its group's available capacity is at least the reserved token requirement for the request.

## Model selection

The caller may supply models in preference order. If omitted, OpenAIQuotaFuse uses the curated quality profiles in `model-selection.json`.

For complimentary quota, candidate ordering optimizes capability per quota token, not API dollar price. When two models consume the same shared complimentary token quota, the more capable model may be preferred even if its paid API price is higher.

Current ordinary (`low`) preference order:

    gpt-5.6-terra
    gpt-5.6-luna
    gpt-5.6-sol

Current explicit `high` preference order:

    gpt-5.6-sol
    gpt-5.6-terra
    gpt-5.6-luna

Terra and Luna currently share the high-volume complimentary quota, so Luna's lower API dollar price does not reduce complimentary quota consumption. Terra is therefore preferred for ordinary complimentary execution. A future paid fallback policy should use a separately justified cost-aware ordering, where Luna can precede Terra.

The first candidate whose quota group has sufficient available capacity is selected. If no candidate fits, selection fails without making an inference request.

Quality profiles map to explicit curated candidate lists and must not spend an inference call merely to classify the request.

## CLI option conventions

Every long-form command-line option must have a short alias. New options are not complete until both forms are documented and tested.

Prefer conventional aliases where possible and keep each alias unambiguous within a command. Planned examples include:

    --quality, -q
    --input, -i
    --model, -m
    --estimated-tokens, -t
    --max-output-tokens, -o
    --raw, -r
    --help, -h
    --version, -v

The long form is canonical in documentation and scripts where readability matters; the short form is provided for interactive use. Python and Swift APIs should preserve the same concepts even though short CLI aliases do not apply to their native function-call interfaces.
