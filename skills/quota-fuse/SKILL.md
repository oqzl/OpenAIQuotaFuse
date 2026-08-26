---
name: quota-fuse
description: Use OpenAIQuotaFuse when Codex should inspect OpenAI API complimentary quota/costs, choose a quota-aware model, or dispatch a secondary OpenAI API request under the repository's conservative quota and annual paid-budget policy. Do not claim this changes the model running the current Codex turn.
---

# OpenAI Quota Fuse

Use this skill as a policy/tool boundary for OpenAI API calls made from a Codex workflow.

## Scope

OpenAIQuotaFuse can:

- inspect the configured Organization Usage and Costs data;
- choose a model from the repository policy for an estimated request;
- classify a `run` task as `low` or `high` when quality is `auto`;
- execute a secondary Responses API request after quota/budget checks;
- enforce the configured annual paid fallback cap.

It cannot change the model or reasoning effort already running the current Codex turn. Do not describe the plugin as self-routing Codex itself. It governs OpenAI API work that Codex explicitly dispatches through the Fuse CLI.

## Path resolution

`skill_dir` is the directory containing this `SKILL.md`.

`plugin_root` is two directories above `skill_dir` and contains `.codex-plugin/plugin.json`, `python/`, `models.json`, and `model-selection.json`.

Use the Python implementation:

    python3 "<plugin_root>/python/openai_quota_fuse.py" ...

Do not prefer the Shell implementation merely because a shell is available. The Python CLI is the plugin-facing implementation and avoids the extra `curl` and `jq` runtime dependencies.

## When to use

Use Fuse when the user explicitly asks for quota/cost/model-policy handling, or when a Codex workflow is about to make a secondary OpenAI API inference and the repository's quota guard is relevant.

For a plain Codex reasoning/editing task that does not dispatch an OpenAI API request, do not add a pointless Fuse subprocess.

## Commands

Inspect quota:

    python3 "<plugin_root>/python/openai_quota_fuse.py" status

Inspect annual costs:

    python3 "<plugin_root>/python/openai_quota_fuse.py" costs

Choose a model for a known conservative token reservation:

    python3 "<plugin_root>/python/openai_quota_fuse.py" select -t 8000

Run a secondary API task with automatic difficulty routing:

    python3 "<plugin_root>/python/openai_quota_fuse.py" run "<task>"

Force cheap or high-quality routing only when the user/workflow has a reason:

    python3 "<plugin_root>/python/openai_quota_fuse.py" run -q low "<task>"
    python3 "<plugin_root>/python/openai_quota_fuse.py" run -q high "<task>"

Set Responses API reasoning effort independently from quality:

    python3 "<plugin_root>/python/openai_quota_fuse.py" run -e high "<task>"

## Required credentials

- `OPENAI_API_KEY`: normal project API key for input-token counting and Responses API inference.
- `OPENAI_ADMIN_KEY`: Organization Admin API key for Usage and Costs inspection.

Keep the two roles separate. Never print, echo, commit, or place either key in a prompt. The CLI can read the same `.env` format documented by OpenAIQuotaFuse.

## Decision rules

1. Preserve explicit user choices (`--model`, `--quality`, `--effort`).
2. Otherwise use `run` with its policy defaults rather than reimplementing model selection in the skill.
3. Treat `models.json`, `model-selection.json`, and `spec/QUOTA_POLICY.md` as policy sources of truth.
4. If Fuse blocks a request, report the block; do not silently bypass it with a direct OpenAI API call.
5. If the user explicitly asks to bypass Fuse, explain that the resulting request is outside Fuse accounting and follow the user's instruction only if otherwise appropriate.
6. Do not infer prepaid-credit balance/expiry from the Billing UI; the CLI intentionally does not scrape it.

## Output handling

Normal `run` prints the generated response text on stdout and routing/accounting diagnostics on stderr. Use `--raw` only when the workflow actually needs the full Responses API JSON.
