# Codex plugin

[日本語](../docs-ja/CODEX_PLUGIN.md)

OpenAIQuotaFuse can be installed as a Codex plugin. The plugin bundles the `quota-fuse` skill and uses the Python 3 CLI as its execution surface.

## Why Python is the plugin-facing implementation

Codex skills can invoke shell commands, so Bash is not technically required to be replaced. Python is nevertheless the better plugin boundary here because it removes the additional `curl` and `jq` dependencies, behaves consistently across the major Codex host platforms, and gives future plugin integrations a stable programmatic implementation without duplicating quota policy in `SKILL.md`.

The Shell implementation remains a thin compatibility wrapper for Unix environments. Both implementations share `models.json`, `model-selection.json`, and `spec/QUOTA_POLICY.md`.

## Important scope boundary

The plugin does not change the model that is already running a Codex turn. A skill is instructions plus callable local resources; it is not a hook that can replace Codex's own inference model mid-turn.

Fuse therefore governs secondary OpenAI API calls that Codex deliberately dispatches through the Fuse CLI. This is still useful for repository workflows that need extra inference, evaluation, classification, generation, or other API-backed substeps while keeping quota and paid fallback policy centralized.

## Installation

This repository includes `.agents/plugins/marketplace.json`. On current Codex CLI versions that expose `codex plugin`, prefer the marketplace commands instead of manually creating `~/plugins` and `~/.agents/plugins/marketplace.json`.

    codex plugin marketplace add oqzl/OpenAIQuotaFuse
    codex plugin add openai-quota-fuse@openai-quota-fuse

Verify:

    codex plugin list --json

Restart Codex if necessary so it reloads plugin metadata.

If your Codex distribution does not expose the `codex plugin` command, use the personal marketplace fallback below.

### Manual installation

`~/plugins` and `~/.agents/plugins` are not guaranteed to exist, so create them first.

    git clone https://github.com/oqzl/OpenAIQuotaFuse.git ~/src/OpenAIQuotaFuse
    mkdir -p ~/plugins ~/.agents/plugins
    ln -sfn ~/src/OpenAIQuotaFuse ~/plugins/openai-quota-fuse

`~/.agents/plugins/marketplace.json` is also not guaranteed to exist. If it does not exist yet, create the complete file below:

    cat > ~/.agents/plugins/marketplace.json <<'JSON'
    {
      "name": "local",
      "interface": {
        "displayName": "Local Plugins"
      },
      "plugins": [
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
      ]
    }
    JSON

If `~/.agents/plugins/marketplace.json` already exists, do not overwrite the file. Append only the `openai-quota-fuse` entry to its existing `plugins` array.

In the personal marketplace, `./plugins/openai-quota-fuse` resolves relative to the home directory and therefore points to `~/plugins/openai-quota-fuse`.

Validate JSON after manual edits:

    python3 -m json.tool ~/.agents/plugins/marketplace.json >/dev/null

The personal marketplace is discovered implicitly from `~/.agents/plugins/marketplace.json`, so the manual path does not require a separate `codex plugin marketplace add` command.

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
