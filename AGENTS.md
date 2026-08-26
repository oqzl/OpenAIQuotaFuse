# AGENTS.md

OpenAIQuotaFuse keeps OpenAI API usage inside the complimentary daily token quota provided by the data-sharing incentive, with conservative safety margins.

## Priorities

1. Prefer avoiding paid usage over maximizing quota utilization.
2. Use current OpenAI primary documentation as the source of truth for quota groups and quota behavior.
3. Keep Shell, Python 3, and Swift 6 behavior aligned with `spec/QUOTA_POLICY.md`.
4. Do not hide uncertainty in Usage API accounting. Expose raw/diagnostic data when useful.
5. Keep the Admin API key separate from normal inference API keys.

## Implementations

- `shell/`: dependency-light reference CLI (`bash`, `curl`, `jq`).
- `python/`: Python 3 implementation (planned).
- `swift/`: Swift 6 package (planned).

The language-neutral policy in `spec/QUOTA_POLICY.md` takes precedence over implementation-specific behavior.
