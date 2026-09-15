const BUILD_ID = "__COMMIT_SHA__";

const els = {
  refresh: document.querySelector("#refresh"),
  status: document.querySelector("#status"),
  identity: document.querySelector("#identity"),
  summary: document.querySelector("#summary"),
  models: document.querySelector("#models"),
  updated: document.querySelector("#updated")
};

let loading = false;

boot();

async function boot() {
  els.refresh.addEventListener("click", refresh);
  registerServiceWorker();
  await refresh();
}

async function refresh() {
  if (loading) return;
  setLoading(true);
  setStatus("Refreshing…");

  try {
    const response = await fetch("./api/status", {
      cache: "no-store",
      headers: { Accept: "application/json" }
    });
    const data = await response.json().catch(() => null);

    if (!response.ok) {
      throw new Error(data?.detail || data?.error || `HTTP ${response.status}`);
    }

    render(data);
    setStatus(`Tier ${data.policy.usage_tier} · ${data.policy.reserve_percent}% safety reserve`);
  } catch (error) {
    renderError(error);
    setStatus(error instanceof Error ? error.message : String(error), true);
  } finally {
    setLoading(false);
  }
}

function render(data) {
  els.identity.textContent = data.identity?.email
    ? `Cloudflare Access · ${data.identity.email}`
    : "Cloudflare Access";

  els.summary.replaceChildren(
    ...data.quota_groups.map(group => quotaCard(group, data.reset_at)),
    costCard(data.costs)
  );

  els.models.replaceChildren(
    ...(data.by_model.length ? data.by_model.map(modelRow) : [emptyRow()])
  );

  els.updated.textContent = `Updated ${new Date(data.generated_at).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit"
  })}`;
}

function quotaCard(group, resetAt) {
  const article = document.createElement("article");
  article.className = `card ${severity(group.used_ratio)}`;

  const label = group.name === "high_volume" ? "High volume" : "Standard";
  const usedPercent = group.used_ratio == null ? 0 : group.used_ratio * 100;

  article.append(
    cardTop(label, `${formatPercent(usedPercent)}%`),
    valueLine(formatTokens(group.used_tokens), ` / ${formatTokens(group.quota_tokens)}`),
    progress(usedPercent),
    definitionRows([
      ["Available", formatTokens(group.available_tokens)],
      ["Safety reserve", formatTokens(group.reserve_tokens)],
      ["Reset", formatReset(resetAt)]
    ])
  );

  return article;
}

function costCard(costs) {
  const article = document.createElement("article");
  const ratio = costs.annual_cap_usd > 0 ? costs.official_ytd_usd / costs.annual_cap_usd : 0;
  article.className = `card ${severity(ratio)}`;

  article.append(
    cardTop("Annual paid fallback", `${formatPercent(ratio * 100)}%`),
    valueLine(formatUsd(costs.official_ytd_usd), ` / ${formatUsd(costs.annual_cap_usd)}`),
    progress(ratio * 100),
    definitionRows([
      ["Official remaining", formatUsd(costs.official_remaining_usd)],
      ["Budget basis", "UTC calendar year"],
      ["Effective Fuse budget", "CLI only"]
    ])
  );

  const note = document.createElement("p");
  note.className = "note";
  note.textContent = costs.note;
  article.append(note);

  return article;
}

function modelRow(row) {
  const tr = document.createElement("tr");
  const values = [
    row.model,
    row.service_tier || "—",
    row.quota_group || "other",
    formatTokens(row.input_tokens),
    formatTokens(row.output_tokens),
    formatTokens(row.total_tokens)
  ];

  values.forEach((value, index) => {
    const td = document.createElement("td");
    td.textContent = value;
    if (index >= 3) td.className = "numeric";
    tr.append(td);
  });

  return tr;
}

function emptyRow() {
  const tr = document.createElement("tr");
  const td = document.createElement("td");
  td.colSpan = 6;
  td.className = "empty";
  td.textContent = "No completion usage observed in the current UTC day.";
  tr.append(td);
  return tr;
}

function renderError(error) {
  els.identity.textContent = "";
  els.models.replaceChildren();

  const article = document.createElement("article");
  article.className = "error-card";
  const h2 = document.createElement("h2");
  h2.textContent = "Could not load usage";
  const p = document.createElement("p");
  p.textContent = error instanceof Error ? error.message : String(error);
  article.append(h2, p);
  els.summary.replaceChildren(article);
  els.updated.textContent = "";
}

function cardTop(title, badgeText) {
  const wrap = document.createElement("div");
  wrap.className = "card-top";
  const h2 = document.createElement("h2");
  h2.textContent = title;
  const badge = document.createElement("span");
  badge.className = "badge";
  badge.textContent = badgeText;
  wrap.append(h2, badge);
  return wrap;
}

function valueLine(main, suffix) {
  const p = document.createElement("p");
  p.className = "value";
  p.append(document.createTextNode(main));
  const span = document.createElement("span");
  span.textContent = suffix;
  p.append(span);
  return p;
}

function progress(percent) {
  const outer = document.createElement("div");
  outer.className = "progress";
  outer.setAttribute("role", "progressbar");
  outer.setAttribute("aria-valuemin", "0");
  outer.setAttribute("aria-valuemax", "100");
  outer.setAttribute("aria-valuenow", String(Math.round(Math.min(100, Math.max(0, percent)))));

  const inner = document.createElement("span");
  inner.style.width = `${Math.min(100, Math.max(0, percent))}%`;
  outer.append(inner);
  return outer;
}

function definitionRows(rows) {
  const dl = document.createElement("dl");
  for (const [label, value] of rows) {
    const row = document.createElement("div");
    const dt = document.createElement("dt");
    const dd = document.createElement("dd");
    dt.textContent = label;
    dd.textContent = value;
    row.append(dt, dd);
    dl.append(row);
  }
  return dl;
}

function severity(ratio) {
  if (ratio >= 1) return "danger";
  if (ratio >= 0.8) return "warning";
  return "";
}

function formatTokens(value) {
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(value);
}

function formatPercent(value) {
  return new Intl.NumberFormat(undefined, {
    maximumFractionDigits: value < 10 ? 1 : 0
  }).format(value);
}

function formatUsd(value) {
  return new Intl.NumberFormat(undefined, {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 4
  }).format(value);
}

function formatReset(iso) {
  const date = new Date(iso);
  return date.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    timeZoneName: "short"
  });
}

function setLoading(value) {
  loading = value;
  els.refresh.disabled = value;
  els.refresh.toggleAttribute("aria-busy", value);
}

function setStatus(message, error = false) {
  els.status.textContent = message;
  els.status.dataset.level = error ? "error" : "normal";
}

function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) return;

  navigator.serviceWorker
    .register(`./sw.js?v=${BUILD_ID}`, { updateViaCache: "none" })
    .then(registration => registration.update())
    .catch(error => console.warn("Service worker registration failed", error));
}
