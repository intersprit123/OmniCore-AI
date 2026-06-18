enum AIProviderType { groq }

class AIRoute {
  const AIRoute({
    required this.provider,
    required this.model,
    required this.mode,
  });

  final AIProviderType provider;
  final String model;
  final String mode;
}
