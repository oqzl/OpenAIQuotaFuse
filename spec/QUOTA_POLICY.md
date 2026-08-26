# Quota policy

## Goal

OpenAIQuotaFuse should normally prevent inference requests that would exceed OpenAI's complimentary daily token quota for eligible data-sharing traffic. Small billing leakage caused by reporting delay or concurrent clients is tolerated operationally, but paid quota is not treated as an available fallback budget.

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

If a new request would make the running daily total exceed the relevant quota, OpenAI bills the entire request at normal rates. Therefore a client must reserve enough quota for the whole estimated request, not merely its expected overage.

## Conservative accounting

The Shell MVP sums all completion usage for models registered in each quota group. This may understate remaining complimentary quota if some registered-model traffic was not itself eligible for the data-sharing incentive, but it avoids falsely claiming free capacity.

A future implementation may use a more precise incentive-specific signal if OpenAI exposes one through a stable documented API contract.

## Safety reserve

A configurable percentage of the daily quota is treated as unavailable. Default: 5%.

Available capacity is:

    max(0, quota - accounted_usage - safety_reserve)

A candidate model can be selected only when its group's available capacity is at least the caller's estimated total tokens for the request.

## Model selection

The caller supplies models in preference order. OpenAIQuotaFuse must not invent a quality ranking.

Example:

    gpt-5.6-sol
    gpt-5.6-luna
    gpt-5.6-terra

The first candidate whose quota group has sufficient available capacity is selected. If no candidate fits, selection fails without making an inference request.
