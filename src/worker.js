import { createRemoteJWKSet, jwtVerify } from "jose";
import models from "../models.json";
import selection from "../model-selection.json";

const OPENAI_API = "https://api.openai.com/v1";
const jwksCache = new Map();

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (!url.pathname.startsWith("/api/")) {
      return json({ error: "Not found" }, 404);
    }

    if (request.method !== "GET") {
      return json({ error: "Method not allowed" }, 405, { Allow: "GET" });
    }

    let identity;
    try {
      identity = await authenticateAccess(request, env);
    } catch (error) {
      return json({ error: "Access denied", detail: errorMessage(error) }, 403);
    }

    if (url.pathname === "/api/status") {
      try {
        return json(await buildStatus(env, identity), 200);
      } catch (error) {
        return json({ error: "Could not load OpenAI usage", detail: errorMessage(error) }, 502);
      }
    }

    return json({ error: "Not found" }, 404);
  }
};

async function authenticateAccess(request, env) {
  if (!env.TEAM_DOMAIN || !env.POLICY_AUD) {
    throw new Error("Cloudflare Access is not configured");
  }

  const token = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!token) {
    throw new Error("Missing Cloudflare Access token");
  }

  const issuer = normalizeTeamDomain(env.TEAM_DOMAIN);
  let jwks = jwksCache.get(issuer);
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(`${issuer}/cdn-cgi/access/certs`));
    jwksCache.set(issuer, jwks);
  }

  const { payload } = await jwtVerify(token, jwks, {
    issuer,
    audience: env.POLICY_AUD,
    algorithms: ["RS256"]
  });

  return {
    email: typeof payload.email === "string" ? payload.email : null,
    subject: typeof payload.sub === "string" ? payload.sub : null
  };
}

function normalizeTeamDomain(value) {
  const url = new URL(value);
  if (url.protocol !== "https:") throw new Error("TEAM_DOMAIN must use HTTPS");
  return url.origin;
}

async function buildStatus(env, identity) {
  if (!env.OPENAI_ADMIN_KEY) {
    throw new Error("OPENAI_ADMIN_KEY is not configured");
  }

  const tier = parseInteger(env.OPENAI_USAGE_TIER ?? "1", 1, 5, "OPENAI_USAGE_TIER");
  const reservePercent = parseInteger(
    env.OPENAI_QUOTA_RESERVE_PERCENT ?? "5",
    0,
    100,
    "OPENAI_QUOTA_RESERVE_PERCENT"
  );
  const annualCap = parseNumber(
    env.OPENAI_ANNUAL_PAID_BUDGET_USD ?? String(selection.paid_fallback.default_annual_budget_usd),
    0,
    1_000_000,
    "OPENAI_ANNUAL_PAID_BUDGET_USD"
  );

  const [usageRaw, officialCosts] = await Promise.all([
    fetchUsage(env.OPENAI_ADMIN_KEY),
    fetchOfficialCosts(env.OPENAI_ADMIN_KEY)
  ]);

  const summarized = summarizeUsage(usageRaw, tier, reservePercent);
  const now = new Date();

  return {
    generated_at: now.toISOString(),
    identity,
    policy: {
      usage_tier: tier,
      reserve_percent: reservePercent,
      annual_paid_budget_usd: annualCap,
      quota_registry_reviewed_at: models.last_reviewed ?? null,
      selection_policy_reviewed_at: selection.last_reviewed ?? null,
      accounting_note:
        "Complimentary usage is conservatively counted across all registered model usage until incentive-specific Usage API behavior is validated."
    },
    reset_at: nextUtcMidnight(now).toISOString(),
    quota_groups: summarized.groups,
    by_model: summarized.byModel,
    costs: {
      official_ytd_usd: officialCosts,
      annual_cap_usd: annualCap,
      official_remaining_usd: Math.max(0, annualCap - officialCosts),
      effective_budget_available: false,
      note:
        "The web viewer cannot read the CLI-local recent paid guard, so official remaining is not the Fuse effective paid budget."
    }
  };
}

async function fetchUsage(key) {
  const query = new URLSearchParams();
  query.set("start_time", String(utcDayStartEpoch()));
  query.set("bucket_width", "1d");
  query.set("limit", "1");
  query.append("group_by", "model");
  query.append("group_by", "service_tier");
  return openAIJson(`${OPENAI_API}/organization/usage/completions?${query}`, key);
}

async function fetchOfficialCosts(key) {
  let total = 0;
  let page = null;

  for (let i = 0; i < 10; i += 1) {
    const query = new URLSearchParams();
    query.set("start_time", String(utcYearStartEpoch()));
    query.set("bucket_width", "1d");
    query.set("limit", "180");
    if (page) query.set("page", page);

    const raw = await openAIJson(`${OPENAI_API}/organization/costs?${query}`, key);
    for (const bucket of raw.data ?? []) {
      for (const result of bucket.results ?? []) {
        const amount = result.amount ?? {};
        if (amount.currency !== "usd") {
          throw new Error("Costs API returned a non-USD amount");
        }
        total += Number(amount.value ?? 0);
      }
    }

    if (!raw.has_more) return total;
    if (typeof raw.next_page !== "string" || !raw.next_page) {
      throw new Error("Costs API pagination missing next_page");
    }
    page = raw.next_page;
  }

  throw new Error("Costs API pagination exceeded safety limit");
}

async function openAIJson(url, key) {
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${key}`,
      Accept: "application/json"
    }
  });

  const text = await response.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw new Error(`OpenAI API returned non-JSON (${response.status})`);
  }

  if (!response.ok) {
    const message = data?.error?.message || `OpenAI API HTTP ${response.status}`;
    throw new Error(message);
  }

  return data;
}

function summarizeUsage(raw, tier, reservePercent) {
  const usedByGroup = Object.fromEntries(
    Object.keys(models.quota_groups).map(name => [name, 0])
  );
  const byModel = new Map();

  for (const bucket of raw.data ?? []) {
    for (const row of bucket.results ?? []) {
      const model = String(row.model ?? "unknown");
      const serviceTier = row.service_tier == null ? null : String(row.service_tier);
      const input = Number(row.input_tokens ?? 0);
      const output = Number(row.output_tokens ?? 0);
      const total = input + output;
      const group = modelGroup(model);

      if (group) usedByGroup[group] += total;

      const key = `${model}\u0000${serviceTier ?? ""}`;
      const current = byModel.get(key) ?? {
        model,
        service_tier: serviceTier,
        quota_group: group,
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0
      };
      current.input_tokens += input;
      current.output_tokens += output;
      current.total_tokens += total;
      byModel.set(key, current);
    }
  }

  const groups = Object.entries(models.quota_groups).map(([name, group]) => {
    const quotaKey = tier <= 2 ? "tier_1_2" : "tier_3_5";
    const quota = Number(group.daily_token_limits[quotaKey]);
    const used = usedByGroup[name];
    const reserve = Math.floor((quota * reservePercent) / 100);

    return {
      name,
      used_tokens: used,
      quota_tokens: quota,
      reserve_tokens: reserve,
      available_tokens: Math.max(0, quota - used - reserve),
      used_ratio: quota > 0 ? used / quota : null,
      models: group.models
    };
  });

  return {
    groups,
    byModel: [...byModel.values()].sort((a, b) => b.total_tokens - a.total_tokens)
  };
}

function modelGroup(model) {
  for (const [name, group] of Object.entries(models.quota_groups)) {
    if (group.models.includes(model)) return name;
  }
  return null;
}

function utcDayStartEpoch() {
  const now = new Date();
  return Math.floor(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()) / 1000
  );
}

function utcYearStartEpoch() {
  const now = new Date();
  return Math.floor(Date.UTC(now.getUTCFullYear(), 0, 1) / 1000);
}

function nextUtcMidnight(now) {
  return new Date(Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate() + 1
  ));
}

function parseInteger(value, min, max, name) {
  const number = Number.parseInt(value, 10);
  if (!Number.isInteger(number) || number < min || number > max) {
    throw new Error(`${name} must be ${min}..${max}`);
  }
  return number;
}

function parseNumber(value, min, max, name) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < min || number > max) {
    throw new Error(`${name} must be between ${min} and ${max}`);
  }
  return number;
}

function json(value, status, extraHeaders = {}) {
  return Response.json(value, {
    status,
    headers: {
      "Cache-Control": "no-store",
      ...extraHeaders
    }
  });
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
