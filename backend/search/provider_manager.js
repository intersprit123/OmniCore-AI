const axios = require("axios");

const { aggregateSearchResults, cleanText } = require("./context_aggregator");

const DEFAULT_FAILURE_THRESHOLD = 5;
const DEFAULT_COOLDOWN_MS = 10 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 30000;

class SearchProviderManager {
  constructor({ providers, env = process.env, http = axios, logger = () => {} }) {
    this.env = env;
    this.http = http;
    this.logger = logger;
    this.providers = new Map();
    this.states = new Map();
    this.lastActiveProvider = "";
    this.fallbackEvents = [];

    for (const provider of providers) {
      this.register(provider);
    }
  }

  register(provider) {
    if (!provider?.id) {
      throw new Error("Search provider registration requires an id.");
    }

    this.providers.set(provider.id, provider);
    if (!this.states.has(provider.id)) {
      this.states.set(provider.id, freshState(provider.id));
    }
  }

  getProvider(providerId) {
    return this.providers.get(providerId);
  }

  async search(query, maxResults = 5) {
    const startedAt = Date.now();
    const attempts = [];
    const candidates = this.selectCandidates();

    this.log("retrieval started", {
      queryLength: query.length,
      maxResults: clampResults(maxResults),
      candidateProviders: candidates.map((provider) => provider.id),
    });

    if (candidates.length === 0) {
      const reason = "No enabled and configured search providers are available.";
      this.recordFallback(reason);
      return {
        ok: false,
        status: 503,
        body: {
          error: reason,
          diagnostics: this.diagnostics(),
        },
      };
    }

    for (const provider of candidates) {
      const result = await this.runProvider(provider, query, maxResults);
      attempts.push(result.attempt);

      if (result.ok) {
        this.lastActiveProvider = provider.id;
        this.log("retrieval completed", {
          provider: provider.id,
          resultCount: result.payload.results.length,
          contextSize: result.payload.contextSize,
          retrievalLatency: `${Date.now() - startedAt}ms`,
        });
        return {
          ok: true,
          status: result.status,
          provider: provider.id,
          raw: result.raw,
          payload: {
            ...result.payload,
            provider: provider.id,
            attempts,
            diagnostics: this.diagnostics(),
          },
        };
      }

      this.recordFallback(
        `${provider.displayName}: ${result.attempt.error || "search failed"}`
      );
      this.log("provider fallback", {
        provider: provider.id,
        status: result.attempt.status,
        error: result.attempt.error,
      });
    }

    const reason = "All configured search providers were exhausted.";
    this.recordFallback(reason);
    return {
      ok: false,
      status: lastAttemptStatus(attempts),
      body: {
        error: reason,
        attempts,
        diagnostics: this.diagnostics(),
      },
    };
  }

  async testProvider(providerId, query = "OmniCore AI connectivity test") {
    const provider = this.providers.get(providerId);
    if (!provider) {
      return {
        ok: false,
        status: 404,
        error: `Unknown provider: ${providerId}`,
      };
    }

    const result = await this.runProvider(provider, query, 3, {
      ignoreCircuit: true,
    });
    return {
      ok: result.ok,
      status: result.status,
      provider: provider.id,
      attempt: result.attempt,
      resultCount: result.payload?.results?.length || 0,
      diagnostics: this.diagnostics(),
    };
  }

  selectCandidates() {
    return [...this.providers.values()]
      .filter((provider) => {
        const status = this.providerStatus(provider);
        return (
          status.enabled &&
          status.configured &&
          status.quota.available &&
          status.circuit.available
        );
      })
      .sort((a, b) => {
        const aStatus = this.providerStatus(a);
        const bStatus = this.providerStatus(b);
        if (aStatus.priority !== bStatus.priority) {
          return aStatus.priority - bStatus.priority;
        }
        if (aStatus.health !== bStatus.health) {
          return bStatus.health - aStatus.health;
        }
        return aStatus.averageLatencyMs - bStatus.averageLatencyMs;
      });
  }

  async runProvider(provider, query, maxResults, options = {}) {
    const status = this.providerStatus(provider);
    const attempt = {
      provider: provider.id,
      providerName: provider.displayName,
      status: 0,
      latencyMs: 0,
      error: "",
      circuitState: status.circuit.state,
    };

    if (!status.enabled) {
      return failedAttempt(attempt, 409, "Provider is disabled.");
    }
    if (!status.configured) {
      return failedAttempt(attempt, 401, "Provider is not configured.");
    }
    if (!status.quota.available) {
      return failedAttempt(attempt, 429, "Provider quota is exhausted.");
    }
    if (!options.ignoreCircuit && !status.circuit.available) {
      return failedAttempt(attempt, 503, "Provider circuit is open.");
    }

    this.incrementUsage(provider);
    const startedAt = Date.now();
    this.log("provider selected", {
      provider: provider.id,
      priority: status.priority,
      circuitState: status.circuit.state,
      health: status.health,
    });

    try {
      const response = await provider.search({
        http: this.http,
        env: this.env,
        query,
        maxResults: clampResults(maxResults),
        timeout: provider.timeoutMs || DEFAULT_TIMEOUT_MS,
      });

      attempt.status = response.status;
      attempt.latencyMs = Date.now() - startedAt;

      if (response.status === 429) {
        this.recordFailure(provider, attempt, "Provider quota exhausted.");
        return failedAttempt(attempt, response.status, "Provider quota exhausted.");
      }

      if (response.status < 200 || response.status >= 300) {
        const error = providerError(response.data);
        this.recordFailure(provider, attempt, error);
        return failedAttempt(attempt, response.status, error);
      }

      const normalized = provider.normalize(response.data);
      const payload = aggregateSearchResults({
        provider,
        answer: normalized.answer,
        results: normalized.results,
        maxResults,
      });

      if (!payload.answer && payload.results.length === 0) {
        const error = "Provider returned no usable results.";
        this.recordFailure(provider, attempt, error);
        return failedAttempt(attempt, 204, error);
      }

      this.recordSuccess(provider, attempt, response.headers);
      return {
        ok: true,
        status: response.status,
        raw: response.data,
        payload,
        attempt,
      };
    } catch (error) {
      attempt.status = isTimeoutError(error) ? 504 : error.response?.status || 502;
      attempt.latencyMs = Date.now() - startedAt;
      const message = isTimeoutError(error)
        ? "Provider timed out."
        : cleanText(error.message) || "Provider request failed.";
      this.recordFailure(provider, attempt, message, { timeout: isTimeoutError(error) });
      return failedAttempt(attempt, attempt.status, message);
    }
  }

  recordSuccess(provider, attempt, headers = {}) {
    const state = this.state(provider.id);
    state.successCount += 1;
    state.totalLatencyMs += attempt.latencyMs;
    state.lastSuccess = new Date().toISOString();
    state.lastError = "";
    state.circuit.failures = 0;
    state.circuit.state = "closed";
    state.circuit.openedAt = "";
    state.circuit.nextRetryAt = "";
    this.updateQuotaFromHeaders(provider, headers);
  }

  recordFailure(provider, attempt, error, details = {}) {
    const state = this.state(provider.id);
    state.failureCount += 1;
    state.errorCount += 1;
    state.lastFailure = new Date().toISOString();
    state.lastError = cleanText(error);
    if (details.timeout || attempt.status === 504) {
      state.timeoutCount += 1;
    }

    if (attempt.status === 429 || looksLikeQuotaError(error)) {
      state.quota.exhausted = true;
      state.quota.lastExhaustedAt = new Date().toISOString();
      state.quota.remaining = 0;
    }

    state.circuit.failures += 1;
    if (state.circuit.failures >= this.failureThreshold()) {
      state.circuit.state = "open";
      state.circuit.openedAt = new Date().toISOString();
      state.circuit.nextRetryAt = new Date(
        Date.now() + this.cooldownMs()
      ).toISOString();
      this.log("circuit opened", {
        provider: provider.id,
        failureThreshold: this.failureThreshold(),
        nextRetryAt: state.circuit.nextRetryAt,
      });
    }
  }

  incrementUsage(provider) {
    const state = this.state(provider.id);
    resetQuotaWindow(state);
    state.requestCount += 1;
    state.dailyRequests += 1;
    state.monthlyRequests += 1;
  }

  updateQuotaFromHeaders(provider, headers = {}) {
    const remaining = readRemainingQuota(headers);
    if (remaining == null) return;
    const state = this.state(provider.id);
    state.quota.remaining = remaining;
    state.quota.exhausted = remaining <= 0;
    if (state.quota.exhausted) {
      state.quota.lastExhaustedAt = new Date().toISOString();
    }
  }

  providerStatus(provider) {
    const state = this.state(provider.id);
    resetQuotaWindow(state);

    const config = this.providerConfig(provider);
    const quota = this.quotaStatus(provider, state);
    const circuit = this.circuitStatus(provider, state);
    const attempts = state.successCount + state.failureCount;
    const successRate = attempts === 0 ? 100 : (state.successCount / attempts) * 100;
    const averageLatencyMs =
      state.successCount === 0 ? 0 : Math.round(state.totalLatencyMs / state.successCount);
    const health = healthScore({
      configured: config.configured,
      enabled: config.enabled,
      successRate,
      averageLatencyMs,
      timeoutCount: state.timeoutCount,
      circuit,
      quota,
    });

    return {
      id: provider.id,
      name: provider.displayName,
      endpoint: provider.endpoint,
      active: this.lastActiveProvider === provider.id,
      enabled: config.enabled,
      configured: config.configured,
      priority: config.priority,
      health,
      successRate: Number(successRate.toFixed(1)),
      averageLatencyMs,
      timeoutCount: state.timeoutCount,
      errorCount: state.errorCount,
      requestCount: state.requestCount,
      dailyRequests: state.dailyRequests,
      monthlyRequests: state.monthlyRequests,
      lastSuccess: state.lastSuccess,
      lastFailure: state.lastFailure,
      lastError: state.lastError,
      circuit,
      quota,
      configFields: config.configFields,
    };
  }

  status() {
    const providers = [...this.providers.values()].map((provider) =>
      this.providerStatus(provider)
    );
    const activeProvider =
      this.lastActiveProvider ||
      providers
        .filter((provider) => provider.enabled && provider.configured)
        .sort((a, b) => a.priority - b.priority)[0]?.id ||
      "";

    return {
      activeProvider,
      configuredCount: providers.filter((provider) => provider.configured).length,
      healthyCount: providers.filter(
        (provider) =>
          provider.enabled &&
          provider.configured &&
          provider.health >= 70 &&
          provider.circuit.state !== "open" &&
          provider.quota.available
      ).length,
      providers,
      fallbackEvents: this.fallbackEvents,
    };
  }

  diagnostics() {
    const status = this.status();
    return {
      activeProvider: status.activeProvider,
      configuredCount: status.configuredCount,
      healthyCount: status.healthyCount,
      fallbackEvents: status.fallbackEvents,
      providers: status.providers.map((provider) => ({
        id: provider.id,
        name: provider.name,
        priority: provider.priority,
        health: provider.health,
        circuitState: provider.circuit.state,
        quotaStatus: provider.quota.status,
        requestCount: provider.requestCount,
        lastSuccess: provider.lastSuccess,
        lastFailure: provider.lastFailure,
      })),
    };
  }

  providerConfig(provider) {
    const priority = readPriority(this.env, provider);
    const enabled = readEnabled(this.env, provider);
    const configFields = (provider.configFields || []).map((field) => ({
      name: field.name,
      label: field.label,
      env: field.env,
      secret: field.secret === true,
      keyExists: Boolean(cleanText(this.env[field.env])),
      keyPreview: maskKey(this.env[field.env], field.secret),
    }));

    return {
      priority,
      enabled,
      configured: provider.isConfigured(this.env),
      configFields,
    };
  }

  quotaStatus(provider, state) {
    const dailyLimit = readNumber(this.env[`${provider.quotaEnvPrefix}_DAILY_QUOTA`]);
    const monthlyLimit = readNumber(this.env[`${provider.quotaEnvPrefix}_MONTHLY_QUOTA`]);
    const dailyRemaining =
      dailyLimit == null ? null : Math.max(0, dailyLimit - state.dailyRequests);
    const monthlyRemaining =
      monthlyLimit == null ? null : Math.max(0, monthlyLimit - state.monthlyRequests);
    const configuredRemaining = minDefined([
      dailyRemaining,
      monthlyRemaining,
      state.quota.remaining,
    ]);
    const exhausted =
      state.quota.exhausted ||
      dailyRemaining === 0 ||
      monthlyRemaining === 0 ||
      configuredRemaining === 0;

    return {
      available: !exhausted,
      status: exhausted
        ? "exhausted"
        : configuredRemaining == null
          ? "not reported"
          : `${configuredRemaining} remaining`,
      dailyLimit,
      monthlyLimit,
      dailyRequests: state.dailyRequests,
      monthlyRequests: state.monthlyRequests,
      remaining: configuredRemaining,
      lastExhaustedAt: state.quota.lastExhaustedAt,
    };
  }

  circuitStatus(provider, state) {
    if (state.circuit.state === "open" && state.circuit.nextRetryAt) {
      const retryAt = new Date(state.circuit.nextRetryAt).getTime();
      if (Date.now() >= retryAt) {
        state.circuit.state = "half-open";
      }
    }

    return {
      state: state.circuit.state,
      failures: state.circuit.failures,
      threshold: this.failureThreshold(),
      cooldownMs: this.cooldownMs(),
      openedAt: state.circuit.openedAt,
      nextRetryAt: state.circuit.nextRetryAt,
      available: state.circuit.state !== "open",
    };
  }

  state(providerId) {
    if (!this.states.has(providerId)) {
      this.states.set(providerId, freshState(providerId));
    }
    return this.states.get(providerId);
  }

  failureThreshold() {
    return (
      readNumber(this.env.SEARCH_PROVIDER_FAILURE_THRESHOLD) ||
      DEFAULT_FAILURE_THRESHOLD
    );
  }

  cooldownMs() {
    const minutes = readNumber(this.env.SEARCH_PROVIDER_COOLDOWN_MINUTES);
    return minutes == null ? DEFAULT_COOLDOWN_MS : minutes * 60 * 1000;
  }

  recordFallback(entry) {
    this.fallbackEvents = [
      `${new Date().toISOString()} ${cleanText(entry)}`,
      ...this.fallbackEvents,
    ].slice(0, 20);
  }

  log(label, details) {
    this.logger(label, details);
  }
}

function freshState(providerId) {
  const now = new Date();
  return {
    providerId,
    requestCount: 0,
    dailyRequests: 0,
    monthlyRequests: 0,
    quotaWindowDay: now.toISOString().slice(0, 10),
    quotaWindowMonth: now.toISOString().slice(0, 7),
    successCount: 0,
    failureCount: 0,
    totalLatencyMs: 0,
    timeoutCount: 0,
    errorCount: 0,
    lastSuccess: "",
    lastFailure: "",
    lastError: "",
    circuit: {
      state: "closed",
      failures: 0,
      openedAt: "",
      nextRetryAt: "",
    },
    quota: {
      remaining: null,
      exhausted: false,
      lastExhaustedAt: "",
    },
  };
}

function failedAttempt(attempt, status, error) {
  attempt.status = status;
  attempt.error = cleanText(error);
  return { ok: false, status, attempt };
}

function lastAttemptStatus(attempts) {
  const last = [...attempts].reverse().find((attempt) => attempt.status);
  return last?.status && last.status >= 400 ? last.status : 503;
}

function providerError(payload) {
  if (!payload) return "Provider returned an error.";
  if (typeof payload === "string") return cleanText(payload).slice(0, 600);
  const message =
    payload.error?.message ||
    payload.error ||
    payload.message ||
    payload.detail ||
    payload.status;
  return cleanText(message || JSON.stringify(payload)).slice(0, 600);
}

function isTimeoutError(error) {
  return (
    error.code === "ECONNABORTED" ||
    error.name === "TimeoutError" ||
    /timeout/i.test(error.message || "")
  );
}

function looksLikeQuotaError(error) {
  return /quota|limit|rate|exhaust/i.test(cleanText(error));
}

function healthScore({
  configured,
  enabled,
  successRate,
  averageLatencyMs,
  timeoutCount,
  circuit,
  quota,
}) {
  if (!enabled || !configured) return 0;
  const latencyPenalty =
    averageLatencyMs === 0 ? 0 : Math.min(25, averageLatencyMs / 450);
  const timeoutPenalty = Math.min(20, timeoutCount * 4);
  const circuitPenalty =
    circuit.state === "open" ? 55 : circuit.state === "half-open" ? 18 : 0;
  const quotaPenalty = quota.available ? 0 : 55;
  return Math.round(
    Math.max(
      0,
      Math.min(
        100,
        successRate - latencyPenalty - timeoutPenalty - circuitPenalty - quotaPenalty
      )
    )
  );
}

function readPriority(env, provider) {
  const direct = readNumber(env[`SEARCH_PROVIDER_${envKey(provider.id)}_PRIORITY`]);
  if (direct != null) return direct;

  const configured = readPriorityList(env);
  if (configured.has(provider.id)) return configured.get(provider.id);
  return provider.defaultPriority || 100;
}

function readPriorityList(env) {
  const raw = cleanText(env.SEARCH_PROVIDER_PRIORITY || env.SEARCH_PROVIDER_PRIORITIES);
  const priorities = new Map();
  if (!raw) return priorities;

  try {
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      parsed.forEach((item, index) => {
        if (typeof item === "string") {
          priorities.set(item.trim(), index + 1);
        } else if (item && typeof item === "object") {
          const provider = cleanText(item.provider || item.id);
          const priority = readNumber(item.priority) || index + 1;
          if (provider) priorities.set(provider, priority);
        }
      });
      return priorities;
    }
  } catch (_) {
    // Fall through to comma-separated parsing.
  }

  raw
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .forEach((provider, index) => priorities.set(provider, index + 1));
  return priorities;
}

function readEnabled(env, provider) {
  const raw = env[`SEARCH_PROVIDER_${envKey(provider.id)}_ENABLED`];
  if (raw == null || cleanText(raw) === "") {
    return provider.defaultEnabled !== false;
  }
  return !["0", "false", "no", "off", "disabled"].includes(
    cleanText(raw).toLowerCase()
  );
}

function readRemainingQuota(headers = {}) {
  const lookup = {};
  for (const [key, value] of Object.entries(headers || {})) {
    lookup[key.toLowerCase()] = value;
  }
  for (const key of [
    "x-ratelimit-remaining",
    "x-rate-limit-remaining",
    "ratelimit-remaining",
    "x-api-quota-remaining",
  ]) {
    const parsed = readNumber(lookup[key]);
    if (parsed != null) return parsed;
  }
  return null;
}

function resetQuotaWindow(state) {
  const now = new Date();
  const day = now.toISOString().slice(0, 10);
  const month = now.toISOString().slice(0, 7);
  if (state.quotaWindowDay !== day) {
    state.dailyRequests = 0;
    state.quotaWindowDay = day;
    state.quota.exhausted = false;
  }
  if (state.quotaWindowMonth !== month) {
    state.monthlyRequests = 0;
    state.quotaWindowMonth = month;
    state.quota.exhausted = false;
  }
}

function readNumber(value) {
  if (value == null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function minDefined(values) {
  const defined = values.filter((value) => value != null);
  if (defined.length === 0) return null;
  return Math.min(...defined);
}

function clampResults(value) {
  return Math.max(1, Math.min(Number(value) || 5, 10));
}

function envKey(providerId) {
  return providerId.toUpperCase().replace(/[^A-Z0-9]+/g, "_");
}

function maskKey(value, secret = true) {
  const text = cleanText(value);
  if (!text) return "";
  if (!secret) return text.length <= 22 ? text : `${text.slice(0, 10)}...`;
  if (text.length <= 8) return "configured";
  return `${text.slice(0, 4)}...${text.slice(-4)}`;
}

module.exports = {
  SearchProviderManager,
};
