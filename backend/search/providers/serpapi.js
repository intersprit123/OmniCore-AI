const { cleanText } = require("../context_aggregator");

const endpoint = "https://serpapi.com/search.json";

module.exports = {
  id: "serpapi",
  displayName: "SerpApi",
  endpoint,
  defaultPriority: 2,
  quotaEnvPrefix: "SERPAPI",
  configFields: [
    {
      name: "apiKey",
      env: "SERPAPI_API_KEY",
      label: "SerpApi API Key",
      secret: true,
    },
  ],
  isConfigured(env) {
    return Boolean(cleanText(env.SERPAPI_API_KEY));
  },
  async search({ http, env, query, maxResults, timeout }) {
    return http.get(endpoint, {
      timeout,
      validateStatus: () => true,
      params: {
        q: query,
        engine: "google",
        api_key: env.SERPAPI_API_KEY,
        num: clamp(maxResults),
      },
    });
  },
  normalize(payload) {
    const organic = Array.isArray(payload?.organic_results)
      ? payload.organic_results
      : [];
    const answer =
      payload?.answer_box?.answer ||
      payload?.answer_box?.snippet ||
      payload?.knowledge_graph?.description ||
      "";

    return {
      answer: cleanText(answer),
      results: organic.map((item) => ({
        title: item.title,
        url: item.link || item.url,
        snippet: item.snippet,
      })),
    };
  },
};

function clamp(value) {
  return Math.max(1, Math.min(Number(value) || 5, 10));
}
