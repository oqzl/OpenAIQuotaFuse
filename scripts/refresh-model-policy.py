#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
MODELS_PATH = ROOT / "models.json"
SELECTION_PATH = ROOT / "model-selection.json"
RESPONSES_URL = "https://api.openai.com/v1/responses"
MODELS_URL = "https://api.openai.com/v1/models"
DEFAULT_REFRESH_MODEL = "gpt-6.1-sol"
ALLOWED_SOURCE_HOSTS = {
    "openai.com",
    "help.openai.com",
    "developers.openai.com",
    "platform.openai.com",
}
REPORT_ENV = "MODEL_POLICY_REPORT"


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{path.name}: root must be an object")
    return data


def parse_review_date(value: Any) -> dt.date:
    if not isinstance(value, str):
        raise ValueError("last_reviewed must be YYYY-MM-DD")
    return dt.date.fromisoformat(value)


def policy_age_days(selection: dict[str, Any], today: dt.date) -> int:
    return (today - parse_review_date(selection.get("last_reviewed"))).days


def policy_is_stale(selection: dict[str, Any], today: dt.date) -> bool:
    interval = selection.get("review_interval_days")
    if not isinstance(interval, int) or interval < 1:
        raise ValueError("review_interval_days must be a positive integer")
    return policy_age_days(selection, today) > interval


def request_json(
    url: str,
    api_key: str,
    payload: dict[str, Any] | None = None,
    timeout: int = 180,
) -> dict[str, Any]:
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json",
        "User-Agent": "OpenAIQuotaFuse-model-policy-refresh/1",
    }
    data = None
    method = "GET"
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
        method = "POST"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenAI API HTTP {exc.code}: {body[:2000]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"OpenAI API request failed: {exc.reason}") from exc


def output_text(response: dict[str, Any]) -> str:
    parts: list[str] = []
    for item in response.get("output", []) or []:
        if not isinstance(item, dict) or item.get("type") != "message":
            continue
        for content in item.get("content", []) or []:
            if isinstance(content, dict) and content.get("type") == "output_text":
                text = content.get("text")
                if isinstance(text, str):
                    parts.append(text)
    return "\n".join(parts).strip()


def relevant_model_snapshot(
    api_models: dict[str, Any],
    current_models: dict[str, Any],
    current_selection: dict[str, Any],
) -> list[dict[str, Any]]:
    ids: set[str] = set()
    for group in current_models.get("quota_groups", {}).values():
        if isinstance(group, dict):
            ids.update(m for m in group.get("models", []) if isinstance(m, str))
    ids.update(
        m for m in current_selection.get("default_candidates", []) if isinstance(m, str)
    )
    paid = current_selection.get("paid_fallback", {})
    if isinstance(paid, dict):
        profiles = paid.get("quality_profiles", {})
        if isinstance(profiles, dict):
            for values in profiles.values():
                if isinstance(values, list):
                    ids.update(m for m in values if isinstance(m, str))

    rows: list[dict[str, Any]] = []
    for model in api_models.get("data", []) or []:
        if not isinstance(model, dict):
            continue
        model_id = model.get("id")
        if not isinstance(model_id, str):
            continue
        if (
            model_id in ids
            or model_id.startswith("gpt-6")
            or model_id.startswith("gpt-5.6")
            or model_id.startswith("gpt-5.4")
        ):
            rows.append(
                {
                    "id": model_id,
                    "owned_by": model.get("owned_by"),
                    "shutdown_date": model.get("shutdown_date"),
                }
            )
    rows.sort(key=lambda item: item["id"])
    return rows


def refresh_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "models_json": {"type": "string"},
            "model_selection_json": {"type": "string"},
            "summary": {"type": "string"},
            "sources": {
                "type": "array",
                "items": {"type": "string"},
                "minItems": 2,
                "maxItems": 12,
            },
        },
        "required": [
            "models_json",
            "model_selection_json",
            "summary",
            "sources",
        ],
        "additionalProperties": False,
    }


def build_prompt(
    current_models: dict[str, Any],
    current_selection: dict[str, Any],
    model_snapshot: list[dict[str, Any]],
    today: dt.date,
) -> str:
    return f"""Maintain the model policy for OpenAIQuotaFuse.

Today is {today.isoformat()} UTC.

Use web search and ONLY current OpenAI primary sources under openai.com, especially:
- the Help Center article about sharing API data and complimentary token quota groups;
- the API model catalog and model-selection guidance;
- the API pricing page;
- the API deprecations page.

The /v1/models snapshot below comes from the same project API key. Treat its shutdown_date
field as authoritative when present. A model absent from this project-specific list is not,
by itself, proof that the model has been globally shut down.

Return complete replacement contents for both JSON files as serialized JSON strings.

Rules for models.json:
1. Preserve schema_version=1 and the existing quota-group object shape.
2. The quota groups and daily limits must match the current data-sharing incentive source.
3. Keep incentive-eligible models that are still usable, including deprecated models whose
   shutdown date is in the future.
4. Remove a model once an official source says its shutdown date is today or earlier.
5. This is an accounting registry, so do not remove an active older model just because a
   newer model is preferred.
6. Set last_reviewed to {today.isoformat()} and use a query-free current OpenAI source URL.

Rules for model-selection.json:
1. Preserve schema_version=1 and review_interval_days unless there is a strong documented
   reason to change them.
2. Re-evaluate complimentary low/high candidates separately from paid fallback.
3. Complimentary routing optimizes capability per shared complimentary quota token.
4. Paid fallback optimizes capability/cost under the small annual dollar budget.
5. Every default candidate and auto_quality.classifier_model must exist in models.json.
6. Use only models that are actually available for the relevant API use.
7. Refresh paid-fallback prices from current official API pricing.
8. Preserve conservative behavior and the existing quality/effort semantics unless current
   model capabilities require a change.
9. Set last_reviewed to {today.isoformat()}.
10. Keep source URLs query-free and current.

Do not auto-merge or weaken any budget/quota safety behavior. Do not invent quota groups,
prices, model IDs, or deprecation dates. If official sources conflict, prefer the more
specific/newer source and explain the conflict briefly in summary.

Current models.json:
{json.dumps(current_models, ensure_ascii=False, indent=2)}

Current model-selection.json:
{json.dumps(current_selection, ensure_ascii=False, indent=2)}

Relevant /v1/models snapshot:
{json.dumps(model_snapshot, ensure_ascii=False, indent=2)}
"""


def parse_json_string(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, str):
        raise ValueError(f"{label} must be a JSON string")
    text = value.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        if len(lines) >= 3 and lines[-1].strip() == "```":
            text = "\n".join(lines[1:-1])
            if text.lstrip().startswith("json"):
                text = text.lstrip()[4:].lstrip()
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError(f"{label} root must be an object")
    return data


def registered_models(models: dict[str, Any]) -> set[str]:
    registered: set[str] = set()
    groups = models.get("quota_groups")
    if not isinstance(groups, dict) or not groups:
        raise ValueError("models.json quota_groups must be a non-empty object")
    for name, group in groups.items():
        if not isinstance(group, dict):
            raise ValueError(f"quota group {name} must be an object")
        limits = group.get("daily_token_limits")
        model_ids = group.get("models")
        if not isinstance(limits, dict) or not limits:
            raise ValueError(f"quota group {name} daily_token_limits must be an object")
        if not isinstance(model_ids, list) or not all(
            isinstance(model_id, str) and model_id for model_id in model_ids
        ):
            raise ValueError(f"quota group {name} models must be a string array")
        if len(model_ids) != len(set(model_ids)):
            raise ValueError(f"quota group {name} contains duplicate models")
        for limit_name, limit in limits.items():
            if not isinstance(limit_name, str) or not isinstance(limit, int) or limit <= 0:
                raise ValueError(f"quota group {name} has invalid daily token limit")
        registered.update(model_ids)
    return registered


def validate_sources(urls: Any) -> list[str]:
    if not isinstance(urls, list) or len(urls) < 2:
        raise ValueError("refresh must cite at least two OpenAI primary sources")
    cleaned: list[str] = []
    for value in urls:
        if not isinstance(value, str):
            raise ValueError("source URL must be a string")
        parsed = urlparse(value)
        host = (parsed.hostname or "").lower()
        if not (host in ALLOWED_SOURCE_HOSTS or host.endswith(".openai.com")):
            raise ValueError(f"non-OpenAI source rejected: {value}")
        cleaned.append(value.split("?", 1)[0])
    return list(dict.fromkeys(cleaned))


def validate_refresh(
    models: dict[str, Any],
    selection: dict[str, Any],
    today: dt.date,
    source_urls: Any,
) -> list[str]:
    if models.get("schema_version") != 1:
        raise ValueError("models.json schema_version must remain 1")
    if selection.get("schema_version") != 1:
        raise ValueError("model-selection.json schema_version must remain 1")
    if models.get("last_reviewed") != today.isoformat():
        raise ValueError("models.json last_reviewed must be today")
    if selection.get("last_reviewed") != today.isoformat():
        raise ValueError("model-selection.json last_reviewed must be today")
    interval = selection.get("review_interval_days")
    if not isinstance(interval, int) or interval < 1:
        raise ValueError("review_interval_days must be a positive integer")

    registered = registered_models(models)
    candidates = selection.get("default_candidates")
    if not isinstance(candidates, list) or not candidates:
        raise ValueError("default_candidates must be a non-empty array")
    missing = [m for m in candidates if not isinstance(m, str) or m not in registered]
    if missing:
        raise ValueError(f"default candidates missing from models.json: {missing}")

    profiles = selection.get("quality_profiles")
    if not isinstance(profiles, dict) or not profiles:
        raise ValueError("quality_profiles must be a non-empty object")
    for name, values in profiles.items():
        if not isinstance(values, list) or not values:
            raise ValueError(f"quality profile {name} must be a non-empty array")
        missing_profile = [m for m in values if not isinstance(m, str) or m not in registered]
        if missing_profile:
            raise ValueError(
                f"quality profile {name} contains unregistered models: {missing_profile}"
            )

    auto = selection.get("auto_quality")
    if not isinstance(auto, dict):
        raise ValueError("auto_quality must be an object")
    classifier = auto.get("classifier_model")
    if not isinstance(classifier, str) or classifier not in registered:
        raise ValueError("auto_quality.classifier_model must exist in models.json")

    paid = selection.get("paid_fallback")
    if not isinstance(paid, dict):
        raise ValueError("paid_fallback must be an object")
    paid_profiles = paid.get("quality_profiles")
    prices = paid.get("pricing_usd_per_million_tokens")
    if not isinstance(paid_profiles, dict) or not isinstance(prices, dict):
        raise ValueError("paid fallback profiles/pricing must be objects")
    used_paid: set[str] = set()
    for name, values in paid_profiles.items():
        if not isinstance(values, list) or not values:
            raise ValueError(f"paid fallback profile {name} must be a non-empty array")
        if not all(isinstance(model_id, str) and model_id for model_id in values):
            raise ValueError(f"paid fallback profile {name} contains invalid model IDs")
        used_paid.update(values)
    for model_id in used_paid:
        price = prices.get(model_id)
        if not isinstance(price, dict):
            raise ValueError(f"missing paid fallback pricing for {model_id}")
        for field in ("input", "output"):
            value = price.get(field)
            if not isinstance(value, (int, float)) or value < 0:
                raise ValueError(f"invalid {field} price for {model_id}")

    return validate_sources(source_urls)


def write_json(path: Path, data: dict[str, Any]) -> None:
    rendered = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(rendered, encoding="utf-8")
    temporary.replace(path)


def write_report(summary: str, sources: list[str], model: str) -> None:
    report_path = os.environ.get(REPORT_ENV)
    if not report_path:
        return
    lines = [
        "## Automated model-policy refresh",
        "",
        summary.strip(),
        "",
        f"Refresh model: `{model}`",
        "",
        "### OpenAI primary sources",
    ]
    lines.extend(f"- {source}" for source in sources)
    lines.append("")
    Path(report_path).write_text("\n".join(lines), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Refresh stale OpenAIQuotaFuse model policy from OpenAI primary sources."
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="refresh even when last_reviewed is still within the configured interval",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="validate a generated refresh without writing policy files",
    )
    args = parser.parse_args(argv)

    today = dt.datetime.now(dt.timezone.utc).date()
    current_models = load_json(MODELS_PATH)
    current_selection = load_json(SELECTION_PATH)
    age = policy_age_days(current_selection, today)
    interval = current_selection.get("review_interval_days")
    stale = policy_is_stale(current_selection, today)
    print(
        f"Model policy reviewed: {current_selection.get('last_reviewed')} "
        f"({age} days ago); interval={interval}"
    )
    if not args.force and not stale:
        print("Model policy is fresh; no API call needed.")
        return 0

    api_key = (
        os.environ.get("OPENAI_MODEL_POLICY_KEY")
        or os.environ.get("OPENAI_API_KEY")
        or ""
    ).strip()
    if not api_key:
        print(
            "error: stale model policy requires OPENAI_MODEL_POLICY_KEY "
            "or OPENAI_API_KEY",
            file=sys.stderr,
        )
        return 2

    refresh_model = os.environ.get(
        "MODEL_POLICY_REFRESH_MODEL", DEFAULT_REFRESH_MODEL
    ).strip() or DEFAULT_REFRESH_MODEL

    api_models = request_json(MODELS_URL, api_key)
    snapshot = relevant_model_snapshot(api_models, current_models, current_selection)
    payload = {
        "model": refresh_model,
        "reasoning": {"effort": "high"},
        "input": build_prompt(current_models, current_selection, snapshot, today),
        "tools": [
            {
                "type": "web_search",
                "filters": {"allowed_domains": ["openai.com"]},
                "search_context_size": "high",
                "external_web_access": True,
            }
        ],
        "tool_choice": "required",
        "max_output_tokens": 12000,
        "text": {
            "format": {
                "type": "json_schema",
                "name": "model_policy_refresh",
                "strict": True,
                "schema": refresh_schema(),
            }
        },
    }
    response = request_json(RESPONSES_URL, api_key, payload=payload)
    text = output_text(response)
    if not text:
        raise RuntimeError("OpenAI response contained no output_text")
    result = json.loads(text)
    if not isinstance(result, dict):
        raise ValueError("refresh response root must be an object")

    refreshed_models = parse_json_string(result.get("models_json"), "models_json")
    refreshed_selection = parse_json_string(
        result.get("model_selection_json"), "model_selection_json"
    )
    sources = validate_refresh(
        refreshed_models,
        refreshed_selection,
        today,
        result.get("sources"),
    )
    summary = result.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        raise ValueError("refresh summary must be a non-empty string")

    if args.dry_run:
        print(summary.strip())
        print("Dry run validated; policy files were not changed.")
        return 0

    write_json(MODELS_PATH, refreshed_models)
    write_json(SELECTION_PATH, refreshed_selection)
    write_report(summary, sources, refresh_model)
    print(summary.strip())
    print("Model policy refresh validated and written.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
