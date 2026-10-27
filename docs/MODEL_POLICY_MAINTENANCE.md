# Automatic model-policy maintenance

OpenAIQuotaFuse reviews `models.json` and `model-selection.json` on a 30-day interval. The weekly `Model policy audit` workflow now refreshes stale policy instead of only failing after the deadline.

## Behavior

The scheduled workflow runs every Monday. `scripts/refresh-model-policy.py` first checks `model-selection.json:last_reviewed` against `review_interval_days`.

- If the policy is still fresh, it exits without calling the OpenAI API.
- If the policy is stale, it calls `GET /v1/models`, then makes one Responses API review request using OpenAI web search restricted to `openai.com`.
- The review is instructed to check current data-sharing incentive quota groups, model availability/deprecations, API pricing, complimentary candidate ordering, and paid-fallback ordering.
- Generated replacements are schema-checked and cross-validated before either JSON file is written.
- `scripts/audit-model-policy.sh` runs after the refresh as an independent guard.
- If the validated policy changed, the workflow force-updates the bot-owned `automation/model-policy-refresh` branch and creates or updates a pull request.
- The workflow never auto-merges the pull request.

The generated PR body includes a summary and the OpenAI primary-source URLs returned by the review. Non-OpenAI source URLs are rejected by the refresh script.

## Credentials

The workflow accepts either of these GitHub Actions repository secrets:

1. `OPENAI_MODEL_POLICY_KEY` — preferred dedicated project API key for policy maintenance.
2. `OPENAI_API_KEY` — fallback when the dedicated key is not configured.

The script never prints either key. A dedicated key limits the blast radius of revocation or rotation and is the recommended setup.

The GitHub connector/API cannot populate Actions secrets for this repository automatically. Add the secret in repository settings before the next stale review is due.

The refresh model defaults to `gpt-6.1-sol`. Set `MODEL_POLICY_REFRESH_MODEL` in the workflow environment if that default needs to change later.

## GitHub permissions

The workflow requests:

- `contents: write`
- `pull-requests: write`

The repository or organization must also allow GitHub Actions to create pull requests. If that setting is disabled, policy generation and validation can succeed but the final `gh pr create` step will fail with a permissions error.

## Manual run

`workflow_dispatch` exposes `force_refresh`. When enabled, the workflow performs a review even if the 30-day interval has not expired. This is intended for model launches, pricing changes, or deprecation announcements that should be reviewed immediately.

A local dry run can validate a generated refresh without writing the policy files:

```sh
OPENAI_MODEL_POLICY_KEY=... python3 scripts/refresh-model-policy.py --force --dry-run
```

A normal local run only calls the API when the policy is stale:

```sh
OPENAI_MODEL_POLICY_KEY=... python3 scripts/refresh-model-policy.py
```

## Safety boundaries

Automatic maintenance is deliberately review-gated:

- current OpenAI primary sources take precedence over stale checked-in assumptions;
- the broad accounting registry keeps older models while they remain usable;
- a model is removed after an official shutdown date is reached, not merely because a newer model exists;
- complimentary routing and paid fallback are evaluated separately;
- generated model IDs, prices, and quota groups must pass local structural checks;
- no automatic merge is performed.

The human review of the generated PR remains the final policy approval step.
