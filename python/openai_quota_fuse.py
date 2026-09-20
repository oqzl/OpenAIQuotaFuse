#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import json
import os
from pathlib import Path
import random
import re
import sys
import tempfile
import time
from typing import Any, Iterable
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

VERSION = "0.10.0-dev"
API_BASE = os.environ.get("OPENAI_QUOTA_FUSE_API_BASE", "https://api.openai.com/v1").rstrip("/")
USAGE_URL = f"{API_BASE}/organization/usage/completions"
COSTS_URL = f"{API_BASE}/organization/costs"
RESPONSES_URL = f"{API_BASE}/responses"
INPUT_TOKENS_URL = f"{API_BASE}/responses/input_tokens"
REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODELS_FILE = REPO_ROOT / "models.json"
DEFAULT_SELECTION_FILE = REPO_ROOT / "model-selection.json"
LOCAL_COST_GUARD_SECONDS = 7 * 24 * 60 * 60
SESSION_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
RESPONSE_MIN_OUTPUT_TOKENS = 16
RESPONSE_MAX_OUTPUT_TOKENS = 128_000
GPT56_REASONING_EFFORTS = {"none", "low", "medium", "high", "xhigh", "max"}


class FuseError(RuntimeError):
    def __init__(self, message: str, code: int = 2):
        super().__init__(message)
        self.code = code


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def validate_max_output_tokens(value: int) -> int:
    if not RESPONSE_MIN_OUTPUT_TOKENS <= value <= RESPONSE_MAX_OUTPUT_TOKENS:
        raise FuseError(
            f"max output tokens must be {RESPONSE_MIN_OUTPUT_TOKENS}..{RESPONSE_MAX_OUTPUT_TOKENS}"
        )
    return value


def validate_reasoning_effort(value: str | None) -> str | None:
    if value is not None and value not in GPT56_REASONING_EFFORTS:
        raise FuseError("effort must be one of: none, low, medium, high, xhigh, max")
    return value


def load_env_file() -> None:
    path = Path(os.environ.get("OPENAI_QUOTA_FUSE_ENV_FILE", ".env"))
    if not path.is_file():
        return
    wanted = {
        "OPENAI_ADMIN_KEY", "OPENAI_API_KEY", "OPENAI_USAGE_TIER",
        "OPENAI_QUOTA_RESERVE_PERCENT", "OPENAI_QUOTA_FUSE_MODELS_FILE",
        "OPENAI_QUOTA_FUSE_SELECTION_FILE", "OPENAI_ANNUAL_PAID_BUDGET_USD",
        "OPENAI_QUOTA_FUSE_PAID_LEDGER", "OPENAI_QUOTA_FUSE_SESSION_DIR",
    }
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key not in wanted or key in os.environ:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        os.environ[key] = value


def read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FuseError(f"invalid JSON file {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise FuseError(f"invalid JSON root in {path}")
    return data


def models_file() -> Path:
    return Path(os.environ.get("OPENAI_QUOTA_FUSE_MODELS_FILE", DEFAULT_MODELS_FILE))


def selection_file() -> Path:
    return Path(os.environ.get("OPENAI_QUOTA_FUSE_SELECTION_FILE", DEFAULT_SELECTION_FILE))


def state_root() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "openai-quota-fuse"


def paid_ledger_file() -> Path:
    configured = os.environ.get("OPENAI_QUOTA_FUSE_PAID_LEDGER")
    if configured:
        return Path(configured).expanduser()
    return state_root() / "paid-usage.json"


def session_dir() -> Path:
    configured = os.environ.get("OPENAI_QUOTA_FUSE_SESSION_DIR")
    return Path(configured).expanduser() if configured else state_root() / "sessions"


def session_file(name: str) -> Path:
    if name in {".", ".."} or not SESSION_NAME_RE.fullmatch(name):
        raise FuseError("session name may contain only letters, digits, '.', '_', and '-'")
    return session_dir() / f"{name}.json"


def load_session_response_id(name: str | None) -> str | None:
    if not name:
        return None
    path = session_file(name)
    if not path.exists():
        return None
    data = read_json(path)
    response_id = data.get("response_id")
    if not isinstance(response_id, str) or not response_id:
        raise FuseError(f"invalid session state: {path}")
    return response_id


def save_session_response_id(name: str | None, response: dict[str, Any]) -> None:
    if not name:
        return
    response_id = response.get("id")
    if not isinstance(response_id, str) or not response_id:
        eprint(f"warning: session {name!r} not updated because response id is missing")
        return
    path = session_file(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "schema_version": 1,
        "response_id": response_id,
        "updated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
            tmp = Path(fh.name)
        tmp.replace(path)
    except OSError as exc:
        eprint(f"warning: failed to update session {name!r}: {exc}")


def registries() -> tuple[dict[str, Any], dict[str, Any]]:
    models = read_json(models_file())
    selection = read_json(selection_file())
    if models.get("schema_version") != 1 or not isinstance(models.get("quota_groups"), dict):
        raise FuseError("invalid model registry")
    if selection.get("schema_version") != 1 or not isinstance(selection.get("quality_profiles"), dict):
        raise FuseError("invalid selection policy")

    cfg = selection.get("auto_quality")
    if not isinstance(cfg, dict):
        raise FuseError("invalid auto quality configuration")
    classifier_model = cfg.get("classifier_model")
    if not isinstance(classifier_model, str) or not classifier_model:
        raise FuseError("invalid auto quality classifier model")
    if model_group(classifier_model, models) is None:
        raise FuseError(f"auto quality classifier model is not in models.json: {classifier_model}")
    try:
        classifier_max_output = int(cfg.get("max_output_tokens"))
    except (TypeError, ValueError) as exc:
        raise FuseError("invalid auto quality max_output_tokens") from exc
    validate_max_output_tokens(classifier_max_output)
    classifier_effort = cfg.get("reasoning_effort")
    if not isinstance(classifier_effort, str):
        raise FuseError("invalid auto quality reasoning_effort")
    validate_reasoning_effort(classifier_effort)
    if not isinstance(cfg.get("instructions"), str) or not str(cfg["instructions"]).strip():
        raise FuseError("invalid auto quality instructions")
    if cfg.get("fallback_quality") not in {"low", "high"}:
        raise FuseError("invalid auto quality fallback_quality")
    return models, selection


def require_config(run: bool = False) -> tuple[dict[str, Any], dict[str, Any]]:
    models, selection = registries()
    if not os.environ.get("OPENAI_ADMIN_KEY"):
        raise FuseError("OPENAI_ADMIN_KEY is not set (environment or .env)")
    tier = int(os.environ.get("OPENAI_USAGE_TIER", "1"))
    reserve = int(os.environ.get("OPENAI_QUOTA_RESERVE_PERCENT", "5"))
    if tier not in range(1, 6):
        raise FuseError("OPENAI_USAGE_TIER must be 1..5")
    if reserve not in range(0, 101):
        raise FuseError("OPENAI_QUOTA_RESERVE_PERCENT must be 0..100")
    if run and not os.environ.get("OPENAI_API_KEY"):
        raise FuseError("OPENAI_API_KEY is not set (environment or .env)")
    return models, selection


def api_json(method: str, url: str, key: str, payload: dict[str, Any] | None = None,
             query: dict[str, Any] | None = None) -> dict[str, Any]:
    if query:
        url += "?" + urlencode(query, doseq=True)
    body = None if payload is None else json.dumps(payload).encode()
    req = Request(url, data=body, method=method, headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"
    })
    try:
        with urlopen(req, timeout=60) as response:
            data = json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise FuseError(f"OpenAI API HTTP {exc.code}: {detail}", 1) from exc
    except (URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise FuseError(f"OpenAI API request failed: {exc}", 1) from exc
    if not isinstance(data, dict):
        raise FuseError("OpenAI API returned a non-object JSON response", 5)
    return data


def utc_day_start_epoch() -> int:
    now = dt.datetime.now(dt.timezone.utc)
    return int(now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp())


def utc_year_start_epoch() -> int:
    now = dt.datetime.now(dt.timezone.utc)
    return int(dt.datetime(now.year, 1, 1, tzinfo=dt.timezone.utc).timestamp())


def model_group(model: str, models: dict[str, Any]) -> str | None:
    for name, group in models["quota_groups"].items():
        if model in group.get("models", []):
            return name
    return None


def quota_for_group(group: str, models: dict[str, Any]) -> int:
    tier = int(os.environ.get("OPENAI_USAGE_TIER", "1"))
    key = "tier_1_2" if tier <= 2 else "tier_3_5"
    return int(models["quota_groups"][group]["daily_token_limits"][key])


def fetch_usage() -> dict[str, Any]:
    return api_json("GET", USAGE_URL, os.environ["OPENAI_ADMIN_KEY"], query={
        "start_time": utc_day_start_epoch(), "bucket_width": "1d", "limit": 1,
        "group_by": ["model", "service_tier"],
    })


def summarize_usage(raw: dict[str, Any], models: dict[str, Any]) -> dict[str, int]:
    result = {name: 0 for name in models["quota_groups"]}
    for bucket in raw.get("data", []):
        for row in bucket.get("results", []) or []:
            group = model_group(str(row.get("model", "")), models)
            if group:
                result[group] += int(row.get("input_tokens") or 0) + int(row.get("output_tokens") or 0)
    return result


def available_for_group(group: str, used: int, models: dict[str, Any]) -> int:
    quota = quota_for_group(group, models)
    reserve = quota * int(os.environ.get("OPENAI_QUOTA_RESERVE_PERCENT", "5")) // 100
    return max(0, quota - used - reserve)


def check_model(model: str, tokens: int, models: dict[str, Any], usage: dict[str, int] | None = None) -> tuple[bool, str, int]:
    group = model_group(model, models)
    if not group:
        raise FuseError(f"model is not in models.json: {model}", 3)
    usage = usage if usage is not None else summarize_usage(fetch_usage(), models)
    available = available_for_group(group, usage[group], models)
    return tokens <= available, group, available


def candidates(selection: dict[str, Any], quality: str, paid: bool = False) -> list[str]:
    profiles = selection["paid_fallback"]["quality_profiles"] if paid else selection["quality_profiles"]
    if quality not in profiles:
        raise FuseError(f"unknown quality profile: {quality}")
    return list(profiles[quality])


def select_model(tokens: int, quality: str, models: dict[str, Any], selection: dict[str, Any], explicit: Iterable[str] = ()) -> str:
    usage = summarize_usage(fetch_usage(), models)
    pool = list(explicit) or candidates(selection, quality)
    for model in pool:
        try:
            allowed, _, _ = check_model(model, tokens, models, usage)
        except FuseError:
            continue
        if allowed:
            return model
    raise FuseError("no candidate model has enough complimentary quota", 4)


def request_payload(model: str, input_text: str, max_output: int, effort: str | None = None,
                    previous_response_id: str | None = None) -> dict[str, Any]:
    validate_max_output_tokens(max_output)
    validate_reasoning_effort(effort)
    payload: dict[str, Any] = {"model": model, "input": input_text, "max_output_tokens": max_output}
    if effort:
        payload["reasoning"] = {"effort": effort}
    if previous_response_id:
        payload["previous_response_id"] = previous_response_id
    return payload


def input_token_payload(model: str, input_text: str, *, instructions: str | None = None,
                        previous_response_id: str | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {"model": model, "input": input_text}
    if instructions:
        payload["instructions"] = instructions
    if previous_response_id:
        payload["previous_response_id"] = previous_response_id
    return payload


def output_text(response: dict[str, Any]) -> str:
    parts: list[str] = []
    for item in response.get("output", []) or []:
        if item.get("type") != "message":
            continue
        for content in item.get("content", []) or []:
            if content.get("type") == "output_text":
                parts.append(str(content.get("text", "")))
    return "\n".join(parts)


def count_input_tokens(payload: dict[str, Any]) -> int:
    response = api_json("POST", INPUT_TOKENS_URL, os.environ["OPENAI_API_KEY"], payload=payload)
    value = response.get("input_tokens")
    if not isinstance(value, (int, float)) or value < 0:
        raise FuseError("invalid response from /responses/input_tokens", 5)
    return int(value)


def classify_quality(prompt: str, models: dict[str, Any], selection: dict[str, Any]) -> str:
    cfg = selection["auto_quality"]
    fallback = str(cfg["fallback_quality"])
    classifier_max_output = validate_max_output_tokens(int(cfg["max_output_tokens"]))
    classifier_effort = validate_reasoning_effort(str(cfg["reasoning_effort"]))
    response_payload = request_payload(
        str(cfg["classifier_model"]), prompt, classifier_max_output, classifier_effort
    )
    response_payload["instructions"] = str(cfg["instructions"])
    try:
        count_payload = input_token_payload(
            str(cfg["classifier_model"]), prompt, instructions=str(cfg["instructions"])
        )
        input_tokens = count_input_tokens(count_payload)
        required = input_tokens + classifier_max_output
        allowed, _, _ = check_model(str(cfg["classifier_model"]), required, models)
        if not allowed:
            raise FuseError("classifier has no complimentary quota", 4)
        response = api_json("POST", RESPONSES_URL, os.environ["OPENAI_API_KEY"], payload=response_payload)
        value = "".join(ch for ch in output_text(response).lower().splitlines()[0] if ch.isalpha())
        if value not in {"low", "high"}:
            raise FuseError("classifier returned invalid result", 5)
        eprint(f"quality: auto -> {value}")
        eprint(f"classifier: {cfg['classifier_model']} (input={input_tokens} + max_output={classifier_max_output})")
        return value
    except (FuseError, IndexError) as exc:
        eprint(f"warning: auto quality classifier unavailable ({exc}); using {fallback}")
        return fallback


def read_contexts(paths: list[str]) -> str:
    parts: list[str] = []
    for raw in paths:
        path = Path(raw).expanduser()
        if not path.is_file():
            raise FuseError(f"context is not a readable file: {raw}")
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            raise FuseError(f"failed to read context {raw}: {exc}") from exc
        parts.append(f"Context file: {raw}\n---\n{text}\n---")
    return "\n\n".join(parts)


def compose_input(prompt: str, context_paths: list[str]) -> str:
    context = read_contexts(context_paths)
    if not context:
        return prompt
    return f"{context}\n\nUser request:\n{prompt}"


def price_estimate(model: str, input_tokens: int, output_tokens: int, selection: dict[str, Any]) -> float:
    paid = selection["paid_fallback"]
    rate = paid["pricing_usd_per_million_tokens"].get(model)
    if not rate:
        raise FuseError(f"no paid pricing configured for model: {model}", 4)
    im = om = 1.0
    if input_tokens > int(paid["long_context_threshold_input_tokens"]):
        im = float(paid["long_context_input_multiplier"])
        om = float(paid["long_context_output_multiplier"])
    return (input_tokens * float(rate["input"]) * im + output_tokens * float(rate["output"]) * om) / 1_000_000


def fetch_cost_pages() -> list[dict[str, Any]]:
    pages: list[dict[str, Any]] = []
    page: str | None = None
    while True:
        query: dict[str, Any] = {"start_time": utc_year_start_epoch(), "bucket_width": "1d", "limit": 180}
        if page:
            query["page"] = page
        raw = api_json("GET", COSTS_URL, os.environ["OPENAI_ADMIN_KEY"], query=query)
        pages.append(raw)
        if not raw.get("has_more"):
            return pages
        page = raw.get("next_page")
        if not isinstance(page, str) or not page:
            raise FuseError("Costs API pagination missing next_page", 5)


def official_costs_spent() -> float:
    total = 0.0
    for page in fetch_cost_pages():
        for bucket in page.get("data", []):
            for result in bucket.get("results", []) or []:
                amount = result.get("amount", {})
                if amount.get("currency") != "usd":
                    raise FuseError("Costs API returned a non-USD amount", 5)
                total += float(amount.get("value") or 0)
    return total


def read_ledger() -> dict[str, Any]:
    path = paid_ledger_file()
    if not path.exists():
        return {"schema_version": 2, "requests": []}
    data = read_json(path)
    if int(data.get("schema_version", 1)) >= 2:
        data.setdefault("requests", [])
        return data
    return {"schema_version": 2, "legacy_events": data.get("events", []), "requests": []}


def write_ledger(data: dict[str, Any]) -> None:
    path = paid_ledger_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
        tmp = Path(fh.name)
    tmp.replace(path)


@contextlib.contextmanager
def ledger_lock():
    lock = Path(str(paid_ledger_file()) + ".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(100):
        try:
            lock.mkdir()
            break
        except FileExistsError:
            time.sleep(0.05)
    else:
        raise FuseError("timed out waiting for paid-budget ledger lock", 6)
    try:
        yield
    finally:
        with contextlib.suppress(OSError):
            lock.rmdir()


def local_guard_spent() -> float:
    data = read_ledger()
    year = str(dt.datetime.now(dt.timezone.utc).year)
    cutoff = int(time.time()) - LOCAL_COST_GUARD_SECONDS
    if data.get("legacy_events") and not data.get("requests"):
        return sum(float(e.get("usd") or 0) for e in data["legacy_events"] if str(e.get("year")) == year)
    total = 0.0
    for req in data.get("requests", []):
        if str(req.get("year")) != year:
            continue
        if req.get("state") == "unknown" or int(req.get("created_epoch") or 0) >= cutoff:
            total += float(req.get("actual_usd") if req.get("state") == "completed" and req.get("actual_usd") is not None else req.get("reserved_usd") or 0)
    return total


def effective_paid_spent() -> float:
    return official_costs_spent() + local_guard_spent()


def reserve_paid(model: str, usd: float) -> str:
    data = read_ledger()
    now = dt.datetime.now(dt.timezone.utc)
    request_id = f"{int(now.timestamp())}-{os.getpid()}-{random.randint(0, 99999)}"
    data.setdefault("requests", []).append({
        "id": request_id, "year": str(now.year), "timestamp": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "created_epoch": int(now.timestamp()), "model": model, "state": "unknown", "reserved_usd": usd,
    })
    write_ledger(data)
    return request_id


def complete_paid(request_id: str, actual: float) -> None:
    data = read_ledger()
    for req in data.get("requests", []):
        if req.get("id") == request_id:
            req["state"] = "completed"
            req["actual_usd"] = actual
    write_ledger(data)


def emit_response(response: dict[str, Any], raw: bool) -> None:
    usage = response.get("usage", {}) or {}
    output = usage.get("output_tokens")
    details = usage.get("output_tokens_details", {}) or {}
    reasoning = details.get("reasoning_tokens")
    visible: int | str = "?"
    if isinstance(output, (int, float)) and isinstance(reasoning, (int, float)):
        visible = max(0, int(output) - int(reasoning))
    output_label = str(output if output is not None else "?")
    if reasoning is not None:
        output_label += f" (reasoning={reasoning}, visible={visible})"
    eprint(
        f"usage: input={usage.get('input_tokens', '?')} output={output_label} "
        f"total={usage.get('total_tokens', '?')}"
    )
    status = response.get("status")
    incomplete = response.get("incomplete_details") or {}
    reason = incomplete.get("reason") if isinstance(incomplete, dict) else None
    if status == "incomplete" or reason:
        eprint(f"warning: response incomplete{f' ({reason})' if reason else ''}")
    print(json.dumps(response, indent=2, ensure_ascii=False) if raw else output_text(response))


def run_paid(input_text: str, quality: str, explicit: str | None, max_output: int, raw: bool,
             effort: str | None, selection: dict[str, Any], previous_response_id: str | None,
             session: str | None) -> int:
    with ledger_lock():
        model = explicit or candidates(selection, quality, paid=True)[0]
        input_tokens = count_input_tokens(input_token_payload(
            model, input_text, previous_response_id=previous_response_id
        ))
        estimate = price_estimate(model, input_tokens, max_output, selection)
        cap = float(os.environ.get("OPENAI_ANNUAL_PAID_BUDGET_USD", selection["paid_fallback"]["default_annual_budget_usd"]))
        spent = effective_paid_spent()
        if spent + estimate > cap:
            raise FuseError(f"paid fallback blocked: annual cap ${cap}, effective spend ${spent}, request reserve ${estimate}", 4)
        request_id = reserve_paid(model, estimate)
        eprint(f"quota: complimentary exhausted; paid fallback reserved ${estimate}")
        eprint(f"model: {model}")
        if effort:
            eprint(f"reasoning effort: {effort}")
        try:
            response = api_json(
                "POST", RESPONSES_URL, os.environ["OPENAI_API_KEY"],
                payload=request_payload(model, input_text, max_output, effort, previous_response_id),
            )
        except FuseError:
            eprint("warning: paid reservation retained because inference outcome is unknown")
            raise
        usage = response.get("usage", {})
        actual = price_estimate(model, int(usage.get("input_tokens") or 0), int(usage.get("output_tokens") or 0), selection)
        complete_paid(request_id, actual)
        save_session_response_id(session, response)
        emit_response(response, raw)
    return 0


def cmd_run(args: argparse.Namespace, models: dict[str, Any], selection: dict[str, Any]) -> int:
    prompt = args.input
    if prompt == "-":
        prompt = sys.stdin.read()
    elif prompt is None:
        if args.prompt:
            prompt = " ".join(args.prompt)
        elif not sys.stdin.isatty():
            prompt = sys.stdin.read()
    if not prompt:
        raise FuseError("run requires --input, a positional prompt, or stdin")
    validate_max_output_tokens(args.max_output_tokens)
    validate_reasoning_effort(args.effort)

    input_text = compose_input(prompt, args.context)
    previous_response_id = load_session_response_id(args.session)
    if args.session:
        eprint(f"session: {args.session} ({'continue' if previous_response_id else 'new'})")

    quality = args.quality or selection.get("default_run_quality", selection["default_quality"])
    if quality == "auto":
        quality = selection["auto_quality"]["fallback_quality"] if args.model else classify_quality(prompt, models, selection)
    elif quality not in {"low", "high"}:
        raise FuseError("run quality must be one of: auto, low, high")
    first = args.model or candidates(selection, quality)[0]
    input_tokens = count_input_tokens(input_token_payload(
        first, input_text, previous_response_id=previous_response_id
    ))
    required = input_tokens + args.max_output_tokens
    if args.model:
        allowed, _, _ = check_model(first, required, models)
        model = first if allowed else None
    else:
        try:
            model = select_model(required, quality, models, selection)
        except FuseError as exc:
            if exc.code != 4:
                raise
            model = None
        if model and model != first:
            input_tokens = count_input_tokens(input_token_payload(
                model, input_text, previous_response_id=previous_response_id
            ))
            required = input_tokens + args.max_output_tokens
            allowed, _, _ = check_model(model, required, models)
            if not allowed:
                model = None
    if model is None:
        return run_paid(
            input_text, quality, args.model, args.max_output_tokens, args.raw, args.effort,
            selection, previous_response_id, args.session,
        )
    eprint(f"quota: OK (input={input_tokens} + max_output={args.max_output_tokens} => reserve={required} tokens)")
    eprint(f"model: {model}")
    if args.effort:
        eprint(f"reasoning effort: {args.effort}")
    response = api_json(
        "POST", RESPONSES_URL, os.environ["OPENAI_API_KEY"],
        payload=request_payload(model, input_text, args.max_output_tokens, args.effort, previous_response_id),
    )
    save_session_response_id(args.session, response)
    emit_response(response, args.raw)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="openai-quota-fuse.py")
    parser.add_argument("-v", "--version", action="version", version=VERSION)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("prompt", nargs="*")
    run.add_argument("-i", "--input")
    run.add_argument("-m", "--model")
    run.add_argument("-q", "--quality", choices=["auto", "low", "high"])
    run.add_argument("-e", "--effort")
    run.add_argument("-o", "--max-output-tokens", type=int, default=1024)
    run.add_argument("-r", "--raw", action="store_true")
    run.add_argument("-c", "--context", action="append", default=[], metavar="FILE")
    run.add_argument("-s", "--session", metavar="NAME")
    status = sub.add_parser("status"); status.add_argument("-r", "--raw", action="store_true")
    costs = sub.add_parser("costs"); costs.add_argument("-r", "--raw", action="store_true")
    check = sub.add_parser("check"); check.add_argument("model_pos", nargs="?"); check.add_argument("tokens_pos", nargs="?", type=int); check.add_argument("-m", "--model"); check.add_argument("-t", "--estimated-tokens", type=int)
    select = sub.add_parser("select"); select.add_argument("tokens_pos", nargs="?", type=int); select.add_argument("models_pos", nargs="*"); select.add_argument("-t", "--estimated-tokens", type=int); select.add_argument("-q", "--quality", choices=["low", "high"]); select.add_argument("-m", "--model", action="append", default=[])
    sub.add_parser("models")
    return parser


def main(argv: list[str] | None = None) -> int:
    load_env_file()
    args = build_parser().parse_args(argv)
    try:
        models, selection = registries()
        if args.command == "models":
            for name, group in models["quota_groups"].items():
                print(f"{name}: {', '.join(group['models'])}")
            print(f"Default select quality: {selection['default_quality']}")
            print(f"Default run quality: {selection.get('default_run_quality', selection['default_quality'])}")
            print(f"Auto classifier: {selection['auto_quality']['classifier_model']}")
            print(f"Paid fallback low: {' -> '.join(selection['paid_fallback']['quality_profiles']['low'])}")
            return 0
        require_config(run=args.command == "run")
        if args.command == "run":
            return cmd_run(args, models, selection)
        if args.command == "status":
            raw = fetch_usage()
            if args.raw:
                print(json.dumps(raw, indent=2, ensure_ascii=False)); return 0
            usage = summarize_usage(raw, models)
            print("OpenAIQuotaFuse status (UTC day)")
            for group in models["quota_groups"]:
                print(f"{group} used={usage[group]} quota={quota_for_group(group, models)} available={available_for_group(group, usage[group], models)}")
            return 0
        if args.command == "costs":
            if args.raw:
                for page in fetch_cost_pages(): print(json.dumps(page, indent=2, ensure_ascii=False))
                return 0
            official = official_costs_spent(); guard = local_guard_spent()
            cap = float(os.environ.get("OPENAI_ANNUAL_PAID_BUDGET_USD", selection["paid_fallback"]["default_annual_budget_usd"]))
            print("OpenAIQuotaFuse costs (UTC calendar year)")
            print(f"official_costs_usd={official}"); print(f"local_recent_guard_usd={guard}")
            print(f"effective_budget_spend_usd={official + guard}"); print(f"annual_cap_usd={cap}")
            return 0
        if args.command == "check":
            model = args.model or args.model_pos; tokens = args.estimated_tokens if args.estimated_tokens is not None else args.tokens_pos
            if not model or tokens is None: raise FuseError("check requires model and estimated tokens")
            allowed, group, available = check_model(model, tokens, models)
            print(f"{'ALLOW' if allowed else 'BLOCK'} {model} group={group} requested={tokens} available={available}")
            return 0 if allowed else 4
        if args.command == "select":
            tokens = args.estimated_tokens if args.estimated_tokens is not None else args.tokens_pos
            if tokens is None: raise FuseError("select requires estimated tokens")
            quality = args.quality or selection["default_quality"]
            explicit = args.model or args.models_pos
            print(select_model(tokens, quality, models, selection, explicit))
            return 0
        raise FuseError("unknown command")
    except FuseError as exc:
        eprint(f"error: {exc}")
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main())
