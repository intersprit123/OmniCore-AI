/// Groq API configuration.
///
/// OmniCore defaults to the local backend so provider secrets stay server-side.
/// Optional proxy override:
/// - `GROQ_API_ENDPOINT`
///
/// Avoid shipping `GROQ_API_KEY` in Flutter Web builds. The developer
/// configuration panel stores keys in the local backend instead.
class GroqConfig {
  static const String apiKey = '';
  static const String endpoint = '';
}
