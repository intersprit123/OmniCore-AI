const { cleanText } = require("../context_aggregator");

const endpoint = "https://api.search.brave.com/res/v1/web/search";

module.exports = {
  id: "brave",
  displayName: "Brave Search",
  endpoint,
  defaultPriority: 5,
  quotaEnvPrefix: "BRAVE_SEARCH",
  configFields: [
    {
      name: "apiKey",
      env: "BRAVE_SEARCH_API_KEY",
      label: "Brave Search API Key",
      secret: true,
    },
  ],
  isConfigured(env) {
    return Boolean(cleanText(env.BRAVE_SEARCH_API_KEY));
  },
  async search({ http, env, query, maxResults, timeout }) {
    return http.get(endpoint, {
      headers: {
        Accept: "application/json",
        "Accept-Encoding": "gzip",
        "X-Subscription-Token": env.BRAVE_SEARCH_API_KEY,
      },
      timeout,
      validateStatus: () => true,
      params: {
        q: query,
        count: clamp(maxResults),
        extra_snippets: true,
      },
    });
  },
  normalize(payload) {
    const results = Array.isArray(payload?.web?.results)
      ? payload.web.results
      : [];

    return {
      answer: "",
      results: results.map((item) => ({
        title: item.title,
        url: item.url,
        snippet: [item.description, ...(item.extra_snippets || [])]
          .map(cleanText)
          .filter(Boolean)
          .join(" "),
      })),
    };
  },
};

function clamp(value) {
  return Math.max(1, Math.min(Number(value) || 5, 20));
}
