const { cleanText } = require("../context_aggregator");

const endpoint = "https://api.tavily.com/search";

module.exports = {
  id: "tavily",
  displayName: "Tavily",
  endpoint,
  defaultPriority: 4,
  quotaEnvPrefix: "TAVILY",
  configFields: [
    {
      name: "apiKey",
      env: "TAVILY_API_KEY",
      label: "Tavily API Key",
      secret: true,
    },
  ],
  isConfigured(env) {
    return Boolean(cleanText(env.TAVILY_API_KEY));
  },
  async search({ http, env, query, maxResults, timeout }) {
    return http.post(
      endpoint,
      {
        query,
        max_results: clamp(maxResults),
        search_depth: "basic",
        include_answer: true,
      },
      {
        headers: {
          Authorization: `Bearer ${env.TAVILY_API_KEY}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        timeout,
        validateStatus: () => true,
      }
    );
  },
  normalize(payload) {
    const results = Array.isArray(payload?.results) ? payload.results : [];

    return {
      answer: cleanText(payload?.answer),
      results: results.map((item) => ({
        title: item.title,
        url: item.url,
        snippet: item.content || item.raw_content,
      })),
    };
  },
};

function clamp(value) {
  return Math.max(1, Math.min(Number(value) || 5, 10));
}
