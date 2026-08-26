# Walkthrough fixes

This temporary note records the current walkthrough batch for the open pull request.

- Do not send Responses-only parameters such as `max_output_tokens` to `/responses/input_tokens`.
- Replace meaningless CLI examples with self-contained examples.
- Add `-c/--context FILE` and `-s/--session NAME` to `run`.
- Fix Codex plugin installation so missing `~/plugins` and `~/.agents/plugins/marketplace.json` are handled, and prefer repository marketplace installation on current Codex CLI.

This file can be removed before merge if the PR description is sufficient.
