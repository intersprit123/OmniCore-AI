const TRACKING_PARAMS = new Set([
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_term",
  "utm_content",
  "utm_id",
  "gclid",
  "fbclid",
  "mc_cid",
  "mc_eid",
]);

function aggregateSearchResults({
  provider,
  answer = "",
  results = [],
  maxResults = 5,
}) {
  const normalized = [];
  const seen = new Set();

  for (const [index, item] of results.entries()) {
    const url = normalizeUrl(item.url);
    if (!url || seen.has(url)) continue;
    seen.add(url);

    normalized.push({
      title: cleanText(item.title) || "Source",
      url,
      snippet: cleanText(item.snippet),
      provider: provider.id,
      providerName: provider.displayName,
      rank: normalized.length + 1,
      confidence: confidenceForResult(provider, item, index),
    });

    if (normalized.length >= limit(maxResults)) break;
  }

  const summary = normalized
    .map((item) =>
      [item.title, item.snippet, item.url, `confidence: ${item.confidence}`]
        .filter(Boolean)
        .join("\n")
    )
    .join("\n\n");

  return {
    answer: cleanText(answer),
    summary,
    results: normalized,
    contextSize: `${summary.length} chars`,
  };
}

function confidenceForResult(provider, result, index) {
  const providerBase = {
    serper: 0.93,
    serpapi: 0.92,
    google: 0.94,
    tavily: 0.9,
    brave: 0.91,
    custom: 0.72,
  };
  const base = providerBase[provider.id] || 0.75;
  const snippetBonus = cleanText(result.snippet).length > 80 ? 0.03 : 0;
  const titleBonus = cleanText(result.title).length > 6 ? 0.01 : 0;
  const rankPenalty = Math.min(index * 0.018, 0.16);
  return Number(
    Math.max(0.2, Math.min(0.99, base + snippetBonus + titleBonus - rankPenalty))
      .toFixed(2)
  );
}

function normalizeUrl(value) {
  const raw = cleanText(value);
  if (!raw) return "";

  try {
    const url = new URL(raw);
    url.hash = "";
    for (const key of [...url.searchParams.keys()]) {
      if (TRACKING_PARAMS.has(key.toLowerCase())) {
        url.searchParams.delete(key);
      }
    }
    return url.toString();
  } catch (_) {
    return raw;
  }
}

function cleanText(value) {
  if (value == null) return "";
  return String(value).replace(/\s+/g, " ").trim();
}

function limit(value) {
  return Math.max(1, Math.min(Number(value) || 5, 10));
}

module.exports = {
  aggregateSearchResults,
  cleanText,
  normalizeUrl,
};
