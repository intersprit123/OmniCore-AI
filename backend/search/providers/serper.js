const { cleanText } = require("../context_aggregator");

const endpoint = "https://google.serper.dev/search";

module.exports = {
  id: "serper",
  displayName: "Serper",
  endpoint,
  defaultPriority: 1,
  quotaEnvPrefix: "SERPER",
  configFields: [
    {
      name: "apiKey",
      env: "SERPER_API_KEY",
      label: "Serper API Key",
      secret: true,
    },
  ],
  isConfigured(env) {
    return Boolean(cleanText(env.SERPER_API_KEY));
  },
  async search({ http, env, query, maxResults, timeout }) {
    return http.post(
      endpoint,
      {
        q: query,
        num: clamp(maxResults),
      },
      {
        headers: {
          "X-API-KEY": env.SERPER_API_KEY,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        timeout,
        validateStatus: () => true,
      }
    );
  },
  normalize(payload) {
    const organic = Array.isArray(payload?.organic) ? payload.organic : [];
    const answer =
      payload?.answerBox?.answer ||
      payload?.answerBox?.snippet ||
      payload?.knowledgeGraph?.description ||
      "";

    return {
      answer: cleanText(answer),
      results: organic.map((item) => ({
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
