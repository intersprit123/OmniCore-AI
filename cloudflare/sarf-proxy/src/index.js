const RETRIEVAL_PATH = "/v1/retrieval";
const DEFAULT_SERPAPI_SEARCH_URL = "https://serpapi.com/search.json";

export default {
  async fetch(request, env) {
    const corsHeaders = buildCorsHeaders(request, env);

    if (request.method === "OPTIONS") {
      return handleOptions(request, env, corsHeaders);
    }

    const url = new URL(request.url);

    try {
      if (!isOriginAllowed(request, env)) {
        return jsonResponse(
          { error: "Origin is not allowed by this retrieval proxy." },
          403,
          corsHeaders,
        );
      }

      if (request.method === "GET" && url.pathname === "/health") {
        return jsonResponse(
          {
            ok: true,
            retrievalEndpointConfigured: Boolean(getSerpApiSearchUrl(env)),
            serpApiSecretConfigured: Boolean(getSerpApiKey(env)),
          },
          200,
          corsHeaders,
        );
      }

      if (url.pathname === RETRIEVAL_PATH) {
        return handleRetrieval(request, env, corsHeaders);
      }

      return jsonResponse({ error: "Not found." }, 404, corsHeaders);
    } catch (error) {
      if (error instanceof HttpError) {
        return jsonResponse(
          { error: error.message },
          error.status,
          corsHeaders,
        );
      }

      if (error?.name === "AbortError") {
        return jsonResponse(
          { error: "Client cancelled the request." },
          499,
          corsHeaders,
        );
      }

      console.error("SerpApi retrieval proxy failed", error);
      return jsonResponse(
        { error: "Retrieval proxy failed to complete the request." },
        502,
        corsHeaders,
      );
    }
  },
};

async function handleRetrieval(request, env, corsHeaders) {
  assertPost(request);

  const payload = parseJsonObject(await request.text());
  const query = stringValue(payload.query || payload.prompt);
  if (!query) {
    throw new HttpError(400, "Retrieval requires a non-empty query.");
  }

  const maxResults = clamp(numberValue(payload.max_results) || 5, 1, 10);
  const searchUrl = new URL(getSerpApiSearchUrl(env));
  searchUrl.searchParams.set("api_key", getRequiredSerpApiKey(env));
  searchUrl.searchParams.set("engine", stringValue(payload.engine) || "google");
  searchUrl.searchParams.set("q", query);
  searchUrl.searchParams.set("num", String(maxResults));

  const location = stringValue(payload.location || env.SERPAPI_LOCATION);
  if (location) searchUrl.searchParams.set("location", location);

  const gl = stringValue(payload.gl || env.SERPAPI_GL);
  if (gl) searchUrl.searchParams.set("gl", gl);

  const hl = stringValue(payload.hl || env.SERPAPI_HL);
  if (hl) searchUrl.searchParams.set("hl", hl);

  const upstream = await fetch(searchUrl, {
    method: "GET",
    headers: { Accept: "application/json" },
    signal: request.signal,
  });

  const responseText = await upstream.text();

  if (!upstream.ok) {
    return jsonResponse(
      {
        error: "SerpApi retrieval request failed.",
        status: upstream.status,
        details: trimProviderBody(responseText),
      },
      upstream.status,
      corsHeaders,
    );
  }

  const parsed = parseProviderJson(responseText);
  const normalized = normalizeSerpApiResults(parsed, maxResults);
  return jsonResponse(normalized, 200, corsHeaders);
}

function normalizeSerpApiResults(payload, maxResults) {
  const organicResults = Array.isArray(payload.organic_results)
    ? payload.organic_results
    : [];
  const newsResults = Array.isArray(payload.news_results)
    ? payload.news_results
    : [];
  const answerBox = payload.answer_box && typeof payload.answer_box === "object"
    ? payload.answer_box
    : null;

  const results = [...organicResults, ...newsResults]
    .map((item) => ({
      title: stringValue(item.title) || "Source",
      url: stringValue(item.link || item.url),
      snippet: stringValue(item.snippet || item.summary || item.date),
    }))
    .filter((item) => item.url)
    .slice(0, maxResults);

  const answer = answerBox
    ? stringValue(
        answerBox.answer ||
          answerBox.snippet ||
          answerBox.result ||
          answerBox.title,
      )
    : "";

  const summary = results
    .map((result, index) => {
      const snippet = result.snippet ? ` - ${result.snippet}` : "";
      return `${index + 1}. ${result.title}${snippet}\n${result.url}`;
    })
    .join("\n\n");

  return {
    answer,
    summary,
    results,
  };
}

function assertPost(request) {
  if (request.method !== "POST") {
    throw new HttpError(405, "Only POST is supported for this endpoint.");
  }
}

function getSerpApiSearchUrl(env) {
  return env.SERPAPI_SEARCH_URL || DEFAULT_SERPAPI_SEARCH_URL;
}

function getRequiredSerpApiKey(env) {
  const apiKey = getSerpApiKey(env);
  if (!apiKey) {
    throw new HttpError(500, "SERPAPI_API_KEY Worker secret is not configured.");
  }
  return apiKey;
}

function getSerpApiKey(env) {
  return env.SERPAPI_API_KEY || "";
}

function parseJsonObject(rawBody) {
  if (!rawBody || !rawBody.trim()) {
    throw new HttpError(400, "Request body must be JSON.");
  }

  let payload;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    throw new HttpError(400, "Request body must be valid JSON.");
  }

  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new HttpError(400, "Request body must be a JSON object.");
  }

  return payload;
}

function parseProviderJson(rawBody) {
  try {
    const payload = JSON.parse(rawBody);
    return payload && typeof payload === "object" ? payload : {};
  } catch {
    throw new HttpError(502, "SerpApi returned invalid JSON.");
  }
}

function buildCorsHeaders(request, env) {
  const origin = request.headers.get("Origin") || "";
  const allowedOrigins = parseCsv(env.ALLOWED_ORIGINS);
  const allowAny = allowedOrigins.length === 0 || allowedOrigins.includes("*");
  const headers = new Headers({
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Accept, X-OmniCore-Client",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  });

  if (allowAny) {
    headers.set("Access-Control-Allow-Origin", "*");
  } else if (origin && matchesAllowedOrigin(origin, allowedOrigins)) {
    headers.set("Access-Control-Allow-Origin", origin);
  }

  return headers;
}

function handleOptions(request, env, corsHeaders) {
  if (!isOriginAllowed(request, env)) {
    return jsonResponse(
      { error: "Origin is not allowed by this retrieval proxy." },
      403,
      corsHeaders,
    );
  }

  return new Response(null, { status: 204, headers: corsHeaders });
}

function isOriginAllowed(request, env) {
  const origin = request.headers.get("Origin");
  if (!origin) return true;

  const allowedOrigins = parseCsv(env.ALLOWED_ORIGINS);
  return allowedOrigins.length === 0 ||
    allowedOrigins.includes("*") ||
    matchesAllowedOrigin(origin, allowedOrigins);
}

function jsonResponse(payload, status, corsHeaders) {
  const headers = new Headers(corsHeaders);
  headers.set("Content-Type", "application/json; charset=utf-8");

  return new Response(JSON.stringify(payload), {
    status,
    headers,
  });
}

function parseCsv(value) {
  return String(value || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function matchesAllowedOrigin(origin, allowedOrigins) {
  return allowedOrigins.some((allowedOrigin) => {
    if (allowedOrigin === origin) return true;
    if (!allowedOrigin.includes("*")) return false;

    const pattern = allowedOrigin
      .replace(/[.+?^${}()|[\]\\]/g, "\\$&")
      .replace(/\*/g, ".*");
    return new RegExp(`^${pattern}$`).test(origin);
  });
}

function stringValue(value) {
  return typeof value === "string" ? value.trim() : "";
}

function numberValue(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function trimProviderBody(value) {
  const trimmed = String(value || "").trim();
  return trimmed.length > 500 ? trimmed.slice(0, 500) : trimmed;
}

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}
