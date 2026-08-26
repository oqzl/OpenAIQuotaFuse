# Quota policy

## Goal

OpenAIQuotaFuse should normally prevent inference requests that would exceed OpenAI's complimentary daily token quota for eligible data-sharing traffic. Small billing leakage caused by reporting delay or concurrent clients is tolerated operationally, but paid quota is not treated as an available fallback budget.

## Reset boundary

The complimentary counter resets at 00:00 UTC every day.

## Current quota classes

OpenAI currently documents two shared daily quota groups:

- large-model group: 250,000 tokens/day for usage tiers 1-2; 1,000,000 for tiers 3-5.
- small-model group: 2,500,000 tokens/day for usage tiers 1-2; 10,000,000 for tiers 3-5.

The model registry is implementation data and must be kept synchronized with OpenAI's current published eligibility list.

## Request boundary

If a new request would make the running daily total exceed the relevant quota, OpenAI bills the entire request at normal rates. Therefore a client must reserve enough quota for the whole estimated request, not merely its expected overage.

## Conservative accounting

The Shell MVP sums all completion usage for currently eligible models in each quota group. This may understate remaining complimentary quota if some eligible-model traffic was not itself eligible for the data-sharing incentive, but it avoids falsely claiming free capacity.

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
