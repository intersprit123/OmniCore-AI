const { cleanText } = require("../context_aggregator");

module.exports = {
  id: "custom",
  displayName: "Custom Provider",
  endpoint: "runtime-configured",
  defaultPriority: 50,
  defaultEnabled: false,
  quotaEnvPrefix: "CUSTOM_SEARCH",
  configFields: [
    {
      name: "endpoint",
      env: "CUSTOM_SEARCH_ENDPOINT",
      label: "Custom Search Endpoint",
      secret: false,
    },
    {
      name: "apiKey",
      env: "CUSTOM_SEARCH_API_KEY",
      label: "Custom Provider API Key",
      secret: true,
    },
  ],
  isConfigured(env) {
    return Boolean(cleanText(env.CUSTOM_SEARCH_ENDPOINT));
  },
  async search({ http, env, query, maxResults, timeout }) {
    const method = cleanText(env.CUSTOM_SEARCH_METHOD).toUpperCase() || "POST";
    const endpoint = cleanText(env.CUSTOM_SEARCH_ENDPOINT);
    const headers = {
      Accept: "application/json",
      "Content-Type": "application/json",
    };

    const key = cleanText(env.CUSTOM_SEARCH_API_KEY);
    if (key) {
      const headerName = cleanText(env.CUSTOM_SEARCH_KEY_HEADER) || "Authorization";
      headers[headerName] =
        headerName.toLowerCase() === "authorization" ? `Bearer ${key}` : key;
    }

    if (method === "GET") {
      return http.get(endpoint, {
        headers,
        timeout,
        validateStatus: () => true,
        params: {
          q: query,
          query,
          max_results: clamp(maxResults),
        },
      });
    }

    return http.post(
      endpoint,
      {
        q: query,
        query,
        max_results: clamp(maxResults),
      },
      {
        headers,
        timeout,
        validateStatus: () => true,
      }
    );
  },
  normalize(payload) {
    const candidates =
      payload?.results ||
      payload?.organic_results ||
      payload?.organic ||
      payload?.items ||
      payload?.web?.results ||
      [];
    const results = Array.isArray(candidates) ? candidates : [];

    return {
      answer: cleanText(payload?.answer || payload?.summary),
      results: results.map((item) => ({
        title: item.title || item.name,
        url: item.url || item.link,
        snippet: item.snippet || item.description || item.content,
      })),
    };
  },
};

function clamp(value) {
  return Math.max(1, Math.min(Number(value) || 5, 10));
}
