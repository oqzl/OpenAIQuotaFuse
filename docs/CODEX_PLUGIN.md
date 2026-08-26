# Codex plugin

[日本語](../docs-ja/CODEX_PLUGIN.md)

OpenAIQuotaFuse can be installed as a Codex plugin. The plugin bundles the `quota-fuse` skill and uses the Python 3 CLI as its execution surface.

## Why Python is the plugin-facing implementation

Codex skills can invoke shell commands, so Bash is not technically required to be replaced. Python is nevertheless the better plugin boundary here because it removes the additional `curl` and `jq` dependencies, behaves consistently across the major Codex host platforms, and gives future plugin integrations a stable programmatic implementation without duplicating quota policy in `SKILL.md`.

The Shell implementation remains a dependency-light reference for Unix environments. Both implementations share `models.json`, `model-selection.json`, and `spec/QUOTA_POLICY.md`.

## Important scope boundary

The plugin does not change the model that is already running a Codex turn. A skill is instructions plus callable local resources; it is not a hook that can replace Codex's own inference model mid-turn.

Fuse therefore governs secondary OpenAI API calls that Codex deliberately dispatches through the Fuse CLI. This is still useful for repository workflows that need extra inference, evaluation, classification, generation, or other API-backed substeps while keeping quota and paid fallback policy centralized.

## Local installation

Current Codex plugin discovery is marketplace-based. For a user-local development install:

1. Clone this repository somewhere permanent.
2. Symlink it into `~/plugins/openai-quota-fuse`.
3. Add an `openai-quota-fuse` entry to `~/.agents/plugins/marketplace.json`.
4. Restart Codex if the plugin is not picked up immediately.

Example:

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git ~/src/OpenAIQuotaFuse
    mkdir -p ~/plugins ~/.agents/plugins
    ln -sfn ~/src/OpenAIQuotaFuse ~/plugins/openai-quota-fuse

Marketplace entry (append it to the existing `plugins` array rather than replacing other entries):

    {
      "name": "openai-quota-fuse",
      "source": {
        "source": "local",
        "path": "./plugins/openai-quota-fuse"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Developer Tools"
    }

The path in `~/.agents/plugins/marketplace.json` is relative to the home directory, so `./plugins/openai-quota-fuse` resolves to `~/plugins/openai-quota-fuse`.

## Configure credentials

The plugin uses the same configuration as the CLI:

- `OPENAI_API_KEY` for normal Responses API requests and input-token counting;
- `OPENAI_ADMIN_KEY` for Organization Usage and Costs;
- optional `.env` and the existing quota/budget settings.

Do not combine the Admin API key with the normal inference key.

## Using it from Codex

Once installed, natural-language requests can trigger the bundled `quota-fuse` skill. Explicit examples:

    Use Quota Fuse to check my OpenAI API quota.
    Use Quota Fuse for this secondary OpenAI API call.
    Use Quota Fuse to choose a cost-aware model for an 8000-token reservation.

The skill delegates policy decisions to:

    python3 <plugin-root>/python/openai_quota_fuse.py

rather than reimplementing quota arithmetic in the prompt.
