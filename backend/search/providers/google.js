const { cleanText } = require("../context_aggregator");

const endpoint = "https://www.googleapis.com/customsearch/v1";

module.exports = {
  id: "google",
  displayName: "Google Programmable Search",
  endpoint,
  defaultPriority: 3,
  quotaEnvPrefix: "GOOGLE_SEARCH",
  configFields: [
    {
      name: "apiKey",
      env: "GOOGLE_SEARCH_API_KEY",
      label: "Google Search API Key",
      secret: true,
    },
    {
      name: "searchEngineId",
      env: "GOOGLE_SEARCH_ENGINE_ID",
      label: "Search Engine ID",
      secret: false,
    },
  ],
  isConfigured(env) {
    return Boolean(
      cleanText(env.GOOGLE_SEARCH_API_KEY) &&
        cleanText(env.GOOGLE_SEARCH_ENGINE_ID)
    );
  },
  async search({ http, env, query, maxResults, timeout }) {
    return http.get(endpoint, {
      timeout,
      validateStatus: () => true,
      params: {
        key: env.GOOGLE_SEARCH_API_KEY,
        cx: env.GOOGLE_SEARCH_ENGINE_ID,
        q: query,
        num: clamp(maxResults),
      },
    });
  },
  normalize(payload) {
    const items = Array.isArray(payload?.items) ? payload.items : [];

    return {
      answer: cleanText(payload?.spelling?.correctedQuery),
      results: items.map((item) => ({
        title: item.title,
        url: item.link,
        snippet: item.snippet,
      })),
    };
  },
};

function clamp(value) {
  return Math.max(1, Math.min(Number(value) || 5, 10));
}
