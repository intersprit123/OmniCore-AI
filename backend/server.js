const fs = require("fs");
const path = require("path");
const axios = require("axios");
const cors = require("cors");
const dotenv = require("dotenv");
const express = require("express");
const { createSearchProviderManager } = require("./search");
const app = express();
app.use(cors());
app.use(express.json({ limit: "1mb" }));
const PORT = Number(process.env.PORT || 3000);
const BACKEND_URL = `http://localhost:${PORT}`;
const ENV_PATH = path.join(__dirname, ".env");
const dotenvResult = loadDotenv();
const GROQ_ENDPOINT =
  process.env.GROQ_ENDPOINT ||
  "https://api.groq.com/openai/v1/chat/completions";
const GROQ_DEFAULT_MODEL =
  process.env.GROQ_MODEL || "llama-3.3-70b-versatile";

const diagnostics = {
  dotenvLoaded: dotenvResult.loaded,
  dotenvPath: dotenvResult.path,
  startupAt: new Date().toISOString(),
  lastError: "",
  lastProviderResponse: "No provider response yet",
  lastRetrievalEvent: "No retrieval event yet",
  activeModel: GROQ_DEFAULT_MODEL,
  currentBackendUrl: BACKEND_URL,
  lastGroqStatus: null,
};
const searchProviderManager = createSearchProviderManager({
  env: process.env,
  logger: (label, details) => safeLog(`search ${label}`, details),
});
app.get("/health", (req, res) => {
  res.json({
    status: "ok",
    backend: "OmniCore Local Backend",
    groqKeyLoaded: hasGroqKey(),
    serpApiKeyLoaded: hasSerpApiKey(),
    searchProviders: searchProviderManager.status(),
  });
});
app.get("/config/status", (req, res) => {
  res.json(configStatus());
});
app.post("/config/keys", (req, res) => {
  const groqApiKey = readOptionalString(req.body?.groqApiKey);
  const serpApiKey = readOptionalString(req.body?.serpApiKey);
  const serperApiKey = readOptionalString(req.body?.serperApiKey);
  const googleSearchApiKey = readOptionalString(req.body?.googleSearchApiKey);
  const googleSearchEngineId = readOptionalString(
    req.body?.googleSearchEngineId
  );
  const tavilyApiKey = readOptionalString(req.body?.tavilyApiKey);
  const braveSearchApiKey = readOptionalString(req.body?.braveSearchApiKey);
  if (
    !groqApiKey &&
    !serpApiKey &&
    !serperApiKey &&
    !googleSearchApiKey &&
    !googleSearchEngineId &&
    !tavilyApiKey &&
    !braveSearchApiKey
  ) {
    res.status(400).json({
      error: "No API keys were provided.",
      status: configStatus(),
    });
    return;
  }
  try {
    const updates = {};
    if (groqApiKey) updates.GROQ_API_KEY = groqApiKey;
    if (serpApiKey) updates.SERPAPI_API_KEY = serpApiKey;
    if (serperApiKey) updates.SERPER_API_KEY = serperApiKey;
    if (googleSearchApiKey) {
      updates.GOOGLE_SEARCH_API_KEY = googleSearchApiKey;
    }
    if (googleSearchEngineId) {
      updates.GOOGLE_SEARCH_ENGINE_ID = googleSearchEngineId;
    }
    if (tavilyApiKey) updates.TAVILY_API_KEY = tavilyApiKey;
    if (braveSearchApiKey) updates.BRAVE_SEARCH_API_KEY = braveSearchApiKey;
    applyEnvUpdates(updates);
    safeLog("configuration updated", {
      groqKeyLoaded: hasGroqKey(),
      serpApiKeyLoaded: hasSerpApiKey(),
      configuredSearchProviders: searchProviderManager.status().configuredCount,
      dotenvLoaded: diagnostics.dotenvLoaded,
    });
    res.json(configStatus());
  } catch (error) {
    recordError("Key configuration failed", error.message);
    res.status(500).json({
      error: "Key configuration failed.",
      status: configStatus(),
    });
  }
});
app.post("/config/search-providers", (req, res) => {
  const update = buildSearchProviderUpdates(req.body);
  if (update.error) {
    res.status(update.status || 400).json({
      error: update.error,
      status: configStatus(),
    });
    return;
  }
  try {
    applyEnvUpdates(update.updates);
    safeLog("search provider configuration updated", {
      provider: update.provider.id,
      updatedKeys: Object.keys(update.updates),
    });
    res.json(configStatus());
  } catch (error) {
    recordError("Search provider configuration failed", error.message);
    res.status(500).json({
      error: "Search provider configuration failed.",
      status: configStatus(),
    });
  }
});
app.post("/config/search-providers/order", (req, res) => {
  const priorities = Array.isArray(req.body?.priorities)
    ? req.body.priorities
    : Array.isArray(req.body?.providers)
      ? req.body.providers
      : [];
  const updates = {};
  for (const [index, item] of priorities.entries()) {
    const providerId = readOptionalString(
      typeof item === "string" ? item : item?.provider || item?.id
    );
    const provider = searchProviderManager.getProvider(providerId);
    if (!provider) continue;
    const priority = Number(item?.priority || index + 1);
    updates[`SEARCH_PROVIDER_${envKey(provider.id)}_PRIORITY`] = String(
      Math.max(1, Math.round(priority))
    );
  }
  if (Object.keys(updates).length === 0) {
    res.status(400).json({
      error: "No valid provider priorities were provided.",
      status: configStatus(),
    });
    return;
  }
  applyEnvUpdates(updates);
  res.json(configStatus());
});
app.delete("/config/search-providers/:provider", (req, res) => {
  const providerId = readOptionalString(req.params.provider);
  const provider = searchProviderManager.getProvider(providerId);
  if (!provider) {
    res.status(404).json({
      error: `Unknown search provider: ${providerId}`,
      status: configStatus(),
    });
    return;
  }
  applyEnvUpdates({
    [`SEARCH_PROVIDER_${envKey(provider.id)}_ENABLED`]: "false",
  });
  res.json(configStatus());
});
app.post("/config/search-providers/test", async (req, res) => {
  const providerId = readOptionalString(req.body?.provider || req.body?.id);
  if (!searchProviderManager.getProvider(providerId)) {
    res.status(404).json({
      error: `Unknown search provider: ${providerId}`,
      status: configStatus(),
    });
    return;
  }
  const result = await searchProviderManager.testProvider(
    providerId,
    readOptionalString(req.body?.query) || "OmniCore AI search provider test"
  );
  diagnostics.lastProviderResponse = `${providerDisplayName(providerId)} ${
    result.status
  }`;
  diagnostics.lastRetrievalEvent = `Connectivity test: ${providerDisplayName(
    providerId
  )} ${result.ok ? "ok" : "failed"}`;
  if (!result.ok) {
    recordError("Search provider connectivity test failed", result.attempt?.error);
  }
  res.status(result.ok ? 200 : 502).json({
    ...result,
    status: configStatus(),
  });
});
app.post("/groq", async (req, res) => {
  const request = normalizeGroqRequest(req.body);
  diagnostics.activeModel = request.body.model;
  safeLog("groq request received", {
    endpoint: GROQ_ENDPOINT,
    model: request.body.model,
    dotenvLoaded: diagnostics.dotenvLoaded,
    groqApiKeyLoaded: hasGroqKey(),
    messagesProvided: Array.isArray(request.body.messages),
    stream: request.stream,
    authorizationHeaderSet: hasGroqKey(),
  });
  if (!hasGroqKey()) {
    const message = "Groq API key is not configured.";
    recordError(message, "Set GROQ_API_KEY in backend/.env.");
    res.status(401).json({
      error: message,
      diagnostics: diagnosticSummary(),
    });
    return;
  }
  if (!request.valid) {
    const message = "Groq request format is invalid.";
    recordError(message, request.reason);
    res.status(400).json({
      error: message,
      details: request.reason,
      diagnostics: diagnosticSummary(),
    });
    return;
  }
  try {
    if (request.stream) {
      await proxyGroqStream(request.body, res);
      return;
    }
    const response = await axios.post(GROQ_ENDPOINT, request.body, {
      headers: groqHeaders(),
      timeout: 60000,
      validateStatus: () => true,
    });
    diagnostics.lastGroqStatus = response.status;
    diagnostics.lastProviderResponse = `Groq ${response.status}`;
    safeLog("groq response", {
      status: response.status,
      endpoint: GROQ_ENDPOINT,
      model: request.body.model,
    });
    if (response.status < 200 || response.status >= 300) {
      const providerError = sanitizePayload(response.data);
      recordError("Groq request failed", providerError);
      res.status(response.status).json({
        error: "Groq request failed",
        providerStatus: response.status,
        providerError,
        diagnostics: diagnosticSummary(),
      });
      return;
    }
    res.json(response.data);
  } catch (error) {
    handleProviderFailure(res, error);
  }
});
app.get("/search", async (req, res) => {
  const query = readOptionalString(req.query?.q);
  if (!query) {
    res.status(400).json({ error: "Search query is required." });
    return;
  }
  const result = await searchProviderManager.search(query, 5);
  if (!result.ok) {
    recordRetrievalFailure(result);
    res.status(result.status).json(result.body);
    return;
  }
  recordRetrievalSuccess(result, result.payload.results.length);
  res.json(result.raw);
});
app.post("/v1/retrieval", async (req, res) => {
  const query = readOptionalString(req.body?.query || req.body?.q);
  const maxResults = Number(req.body?.max_results || req.body?.maxResults || 5);
  if (!query) {
    res.status(400).json({ error: "Retrieval query is required." });
    return;
  }
  const result = await searchProviderManager.search(query, maxResults);
  if (!result.ok) {
    recordRetrievalFailure(result);
    res.status(result.status).json(result.body);
    return;
  }
  const retrievalPayload = result.payload;
  recordRetrievalSuccess(result, retrievalPayload.results.length);
  safeLog("retrieval response", {
    status: result.status,
    resultCount: retrievalPayload.results.length,
    activeProvider: result.provider,
    configuredSearchProviders: searchProviderManager.status().configuredCount,
  });
  res.json(retrievalPayload);
});
app.listen(PORT, () => {
  safeLog("startup", {
    backend: "OmniCore Local Backend",
    port: PORT,
    dotenvLoaded: diagnostics.dotenvLoaded,
    dotenvPath: diagnostics.dotenvPath || "not loaded",
    groqKeyLoaded: hasGroqKey(),
    serpApiKeyLoaded: hasSerpApiKey(),
    groqEndpoint: GROQ_ENDPOINT,
    defaultModel: GROQ_DEFAULT_MODEL,
    searchProviders: searchProviderManager.status().providers.map((provider) => ({
      id: provider.id,
      enabled: provider.enabled,
      configured: provider.configured,
      priority: provider.priority,
    })),
  });
});
function loadDotenv() {
  const result = dotenv.config({ path: ENV_PATH });
  if (!result.error) {
    return { loaded: true, path: ENV_PATH };
  }
  const fallbackPath = path.join(process.cwd(), ".env");
  if (fallbackPath !== ENV_PATH && fs.existsSync(fallbackPath)) {
    const fallback = dotenv.config({ path: fallbackPath });
    if (!fallback.error) {
      return { loaded: true, path: fallbackPath };
    }
  }
  return { loaded: false, path: "" };
}
function configStatus() {
  const searchProviders = searchProviderManager.status();
  const serpApi = searchProviders.providers.find(
    (provider) => provider.id === "serpapi"
  );
  return {
    status: "ok",
    backend: "OmniCore Local Backend",
    backendConnected: true,
    backendUrl: BACKEND_URL,
    dotenvLoaded: diagnostics.dotenvLoaded,
    dotenvPath: diagnostics.dotenvPath,
    groq: {
      keyExists: hasGroqKey(),
      keyPreview: maskKey(process.env.GROQ_API_KEY),
      endpoint: GROQ_ENDPOINT,
      defaultModel: GROQ_DEFAULT_MODEL,
      activeModel: diagnostics.activeModel,
    },
    serpapi: {
      keyExists: hasSerpApiKey(),
      keyPreview: maskKey(process.env.SERPAPI_API_KEY),
      endpoint: serpApi?.endpoint || "https://serpapi.com/search.json",
      retrievalEndpoint: `${BACKEND_URL}/v1/retrieval`,
      priority: serpApi?.priority,
      enabled: serpApi?.enabled,
      health: serpApi?.health,
    },
    searchProviders,
    diagnostics: diagnosticSummary(),
  };
}
function diagnosticSummary() {
  return {
    lastError: diagnostics.lastError || "No errors recorded",
    lastProviderResponse: diagnostics.lastProviderResponse,
    lastRetrievalEvent: diagnostics.lastRetrievalEvent,
    activeModel: diagnostics.activeModel,
    currentBackendUrl: diagnostics.currentBackendUrl,
    lastGroqStatus: diagnostics.lastGroqStatus,
    searchProviders: searchProviderManager.diagnostics(),
  };
}
function normalizeGroqRequest(body) {
  if (!body || typeof body !== "object") {
    return {
      valid: false,
      reason: "Request body must be a JSON object.",
      body: {},
      stream: false,
    };
  }
  const messages = Array.isArray(body.messages)
    ? body.messages
    : readOptionalString(body.prompt)
      ? [{ role: "user", content: readOptionalString(body.prompt) }]
      : null;
  if (!messages || messages.length === 0) {
    return {
      valid: false,
      reason: "Request must include messages or prompt.",
      body: {},
      stream: false,
    };
  }
  const normalized = {
    ...body,
    model: readOptionalString(body.model) || GROQ_DEFAULT_MODEL,
    messages,
    temperature:
      typeof body.temperature === "number" ? body.temperature : 0.7,
    max_completion_tokens: Number(
      body.max_completion_tokens || body.max_tokens || 1024
    ),
    stream: body.stream === true,
  };
  delete normalized.max_tokens;
  delete normalized.prompt;
  return {
    valid: true,
    reason: "",
    body: normalized,
    stream: normalized.stream,
  };
}
async function proxyGroqStream(body, res) {
  const response = await axios.post(GROQ_ENDPOINT, body, {
    headers: groqHeaders(),
    timeout: 60000,
    responseType: "stream",
    validateStatus: () => true,
  });
  diagnostics.lastGroqStatus = response.status;
  diagnostics.lastProviderResponse = `Groq ${response.status}`;
  safeLog("groq stream response", {
    status: response.status,
    endpoint: GROQ_ENDPOINT,
    model: body.model,
  });
  if (response.status < 200 || response.status >= 300) {
    const errorPayload = await streamToString(response.data);
    const providerError = sanitizePayload(errorPayload);
    recordError("Groq request failed", providerError);
    res.status(response.status).json({
      error: "Groq request failed",
      providerStatus: response.status,
      providerError,
      diagnostics: diagnosticSummary(),
    });
    return;
  }
  res.status(response.status);
  res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  if (typeof res.flushHeaders === "function") {
    res.flushHeaders();
  }
  let forwardedChunkCount = 0;
  response.data.on("data", (chunk) => {
    forwardedChunkCount += 1;
    safeLog("groq stream chunk forwarded", {
      chunkCount: forwardedChunkCount,
      chunkSize: Buffer.byteLength(chunk),
      preview: previewChunk(chunk),
    });
  });
  response.data.on("end", () => {
    safeLog("groq stream upstream ended", {
      chunkCount: forwardedChunkCount,
    });
  });
  reqSafePipe(response.data, res);
}
function buildSearchProviderUpdates(body = {}) {
  const providerId = readOptionalString(body?.provider || body?.id);
  const provider = searchProviderManager.getProvider(providerId);
  if (!provider) {
    return {
      error: `Unknown search provider: ${providerId}`,
      status: 404,
    };
  }
  const updates = {};
  if (typeof body.enabled === "boolean") {
    updates[`SEARCH_PROVIDER_${envKey(provider.id)}_ENABLED`] = body.enabled
      ? "true"
      : "false";
  }
  if (body.priority != null && Number.isFinite(Number(body.priority))) {
    updates[`SEARCH_PROVIDER_${envKey(provider.id)}_PRIORITY`] = String(
      Math.max(1, Math.round(Number(body.priority)))
    );
  }
  for (const field of provider.configFields || []) {
    const rawValue = body[field.name] ?? body[field.env];
    const value = readOptionalString(rawValue);
    if (value) updates[field.env] = value;
  }
  if (body.dailyQuota != null && Number.isFinite(Number(body.dailyQuota))) {
    updates[`${provider.quotaEnvPrefix}_DAILY_QUOTA`] = String(
      Math.max(0, Math.round(Number(body.dailyQuota)))
    );
  }
  if (body.monthlyQuota != null && Number.isFinite(Number(body.monthlyQuota))) {
    updates[`${provider.quotaEnvPrefix}_MONTHLY_QUOTA`] = String(
      Math.max(0, Math.round(Number(body.monthlyQuota)))
    );
  }
  if (Object.keys(updates).length === 0) {
    return {
      error: "No provider configuration updates were provided.",
      status: 400,
    };
  }
  return { provider, updates };
}
function recordRetrievalSuccess(result, resultCount) {
  const providerName = providerDisplayName(result.provider);
  diagnostics.lastError = "";
  diagnostics.lastProviderResponse = `${providerName} ${result.status}`;
  diagnostics.lastRetrievalEvent = `${providerName} ${result.status}: ${resultCount} results`;
}
function recordRetrievalFailure(result) {
  const error = result.body?.error || "Search retrieval failed.";
  diagnostics.lastProviderResponse = `Search ${result.status}`;
  diagnostics.lastRetrievalEvent = error;
  recordError("Retrieval failed", error);
}
function providerDisplayName(providerId) {
  return searchProviderManager.getProvider(providerId)?.displayName || providerId;
}
function envKey(value) {
  return String(value).toUpperCase().replace(/[^A-Z0-9]+/g, "_");
}
function groqHeaders() {
  return {
    Authorization: `Bearer ${process.env.GROQ_API_KEY}`,
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
  };
}
function hasGroqKey() {
  return Boolean(readOptionalString(process.env.GROQ_API_KEY));
}
function hasSerpApiKey() {
  return Boolean(readOptionalString(process.env.SERPAPI_API_KEY));
}
function writeEnvUpdates(updates) {
  const existing = fs.existsSync(ENV_PATH)
    ? fs.readFileSync(ENV_PATH, "utf8").split(/\r?\n/)
    : [];
  const keys = new Set(Object.keys(updates));
  const output = [];
  const seen = new Set();
 for (const line of existing) {
    const match = line.match(/^([A-Z0-9_]+)=/);
    if (!match || !keys.has(match[1])) {
      output.push(line);
      continue;
    }
    output.push(`${match[1]}=${escapeEnvValue(updates[match[1]])}`);
    seen.add(match[1]);
  }
  for (const key of keys) {
    if (!seen.has(key)) {
      output.push(`${key}=${escapeEnvValue(updates[key])}`);
    }
  }
  fs.writeFileSync(ENV_PATH, `${output.filter(Boolean).join("\n")}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  try {
    fs.chmodSync(ENV_PATH, 0o600);
  } catch (_) {
    // Windows does not consistently honor POSIX file modes.
  }
}
function applyEnvUpdates(updates) {
  writeEnvUpdates(updates);
  for (const [key, value] of Object.entries(updates)) {
    process.env[key] = value;
  }
  diagnostics.dotenvLoaded = true;
  diagnostics.dotenvPath = ENV_PATH;
}
function escapeEnvValue(value) {
  return String(value).replace(/[\r\n]/g, "").trim();
}
function readOptionalString(value) {
  return typeof value === "string" ? value.trim() : "";
}
function maskKey(value) {
  const key = readOptionalString(value);
  if (!key) return "";
  if (key.length <= 8) return "configured";
  return `${key.slice(0, 4)}...${key.slice(-4)}`;
}
function sanitizePayload(value) {
  const text =
    typeof value === "string" ? value : JSON.stringify(value ?? {}, null, 2);
  return text
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/g, "Bearer [redacted]")
    .replace(/gsk_[A-Za-z0-9]+/g, "gsk_[redacted]")
    .replace(/"api_key"\s*:\s*"[^"]+"/g, '"api_key":"[redacted]"')
    .replace(
      /"(GROQ_API_KEY|SERPAPI_API_KEY|SERPER_API_KEY|GOOGLE_SEARCH_API_KEY|TAVILY_API_KEY|BRAVE_SEARCH_API_KEY|CUSTOM_SEARCH_API_KEY)"\s*:\s*"[^"]+"/g,
      '"$1":"[redacted]"'
    )
    .replace(
      /"(apiKey|api_key|token|authorization)"\s*:\s*"[^"]+"/gi,
      '"$1":"[redacted]"'
    )
    .slice(0, 2000);
}
function recordError(label, details) {
  const safeDetails = sanitizePayload(details || "");
  diagnostics.lastError = safeDetails ? `${label}: ${safeDetails}` : label;
  safeLog("error", {
    label,
    details: safeDetails,
  });
}
function handleProviderFailure(res, error) {
  const providerStatus = error.response?.status || 502;
  const providerError = sanitizePayload(error.response?.data || error.message);
  diagnostics.lastGroqStatus = providerStatus;
  diagnostics.lastProviderResponse = `Groq ${providerStatus}`;
  recordError("Groq request failed", providerError);
  res.status(providerStatus).json({
    error: "Groq request failed",
    providerStatus,
    providerError,
    diagnostics: diagnosticSummary(),
  });
}
function safeLog(label, details) {
  let rendered = "";
  try {
    rendered = JSON.stringify(JSON.parse(sanitizePayload(details)), null, 2);
  } catch (_) {
    rendered = sanitizePayload(details || {});
  }
  console.log(`[OmniCore Backend] ${label}: ${rendered}`);
}
function streamToString(stream) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    stream.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    stream.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    stream.on("error", reject);
  });
}
function reqSafePipe(readable, writable) {
  readable.on("error", (error) => {
    recordError("Groq stream failed", error.message);
    if (!writable.destroyed) writable.end();
  });
  writable.on("close", () => {
    if (typeof readable.destroy === "function") readable.destroy();
  });
  readable.pipe(writable);
}
function previewChunk(chunk) {
  const text = Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
  const normalized = text.replace(/\r?\n/g, "\\n");
  return normalized.length <= 120
    ? normalized
    : `${normalized.slice(0, 120)}...`;
}
