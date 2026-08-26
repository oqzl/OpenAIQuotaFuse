# AGENTS.md

OpenAIQuotaFuse keeps OpenAI API usage inside the complimentary daily token quota provided by the data-sharing incentive, with conservative safety margins.

## Priorities

1. Prefer avoiding paid usage over maximizing quota utilization.
2. Use current OpenAI primary documentation as the source of truth for quota groups and quota behavior.
3. Keep the Python implementation aligned with `spec/QUOTA_POLICY.md`; compatibility wrappers and future implementations must delegate to or match that behavior.
4. Do not hide uncertainty in Usage API accounting. Expose raw/diagnostic data when useful.
5. Keep the Admin API key separate from normal inference API keys.

## Implementations

- `python/`: canonical Python 3 CLI and the execution surface for the Codex plugin; use the standard library unless a dependency clearly reduces total complexity.
- `shell/`: thin Unix compatibility wrapper that delegates to the Python CLI. Do not duplicate policy or networking logic here.
- `swift/`: Swift 6 package (planned).
- `.codex-plugin/` + `skills/`: Codex plugin metadata and instructions. Keep policy arithmetic in the canonical implementation/registries rather than duplicating it in prompts.

The language-neutral policy in `spec/QUOTA_POLICY.md` takes precedence over implementation-specific behavior.

The Codex plugin can govern secondary OpenAI API calls explicitly dispatched through OpenAIQuotaFuse. Do not claim that a Skill can change the model or reasoning effort already running the current Codex turn.

## Documentation and TODO synchronization

Implementation work is not complete until the repository documentation reflects the resulting state.

When a change implements, removes, supersedes, or materially changes an item tracked in `docs/TODO.md` / `docs-ja/TODO.md`, update those TODO files in the same change. Do not leave implemented work unchecked or obsolete TODO wording behind.

Before completing a development task, explicitly review:

- `README.md` / `README-ja.md` when user-facing behavior, setup, defaults, or examples changed.
- `docs/TODO.md` / `docs-ja/TODO.md` when tracked work changed state or scope.
- `spec/QUOTA_POLICY.md` when language-independent behavior or policy changed.
- `model-selection.json` / `models.json` when model or quota policy changed.

Paired English/Japanese baseline documents should remain semantically synchronized.
