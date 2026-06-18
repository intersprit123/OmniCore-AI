import 'package:flutter_test/flutter_test.dart';
import 'package:omnicore_ai/models/tool_result.dart';
import 'package:omnicore_ai/services/ai_orchestrator.dart';

void main() {
  test('retrieval context instructs the model to answer directly', () {
    final prompt = AIOrchestrator.composePrompt(
      prompt: "today's pune pmc water schedule",
      mode: 'Smart',
      memories: const [],
      toolResults: const [
        ToolResult(
          toolId: 'serpapi-retrieval',
          title: 'Live Search',
          status: ToolResultStatus.success,
          content: 'PMC water supply updates indicate scheduled maintenance.',
          sources: [
            ToolSource(
              title: 'PMC Water Supply',
              url: 'https://www.pmc.gov.in/',
              snippet: 'Area-wise water supply timing updates are published.',
            ),
          ],
        ),
      ],
    );

    expect(prompt, contains('answer the user directly'));
    expect(prompt, contains('Do not tell the user to visit a website'));
    expect(prompt, contains('Retrieved evidence, ranked by retrieval order'));
    expect(prompt, contains('1. PMC Water Supply: https://www.pmc.gov.in/'));
  });

  test('missing retrieval context allows transparent fallback guidance', () {
    final prompt = AIOrchestrator.composePrompt(
      prompt: "today's pune pmc water schedule",
      mode: 'Smart',
      memories: const [],
      toolResults: const [],
    );

    expect(prompt, contains('No useful retrieval evidence is available'));
    expect(prompt, contains('suggest the most relevant official source'));
  });
}
