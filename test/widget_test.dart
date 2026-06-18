import 'package:flutter_test/flutter_test.dart';
import 'package:omnicore_ai/main.dart';
import 'package:omnicore_ai/config/backend_config.dart';
import 'package:omnicore_ai/config/serpapi_config.dart';
import 'package:omnicore_ai/models/ai_memory.dart';
import 'package:omnicore_ai/models/chat_message.dart';
import 'package:omnicore_ai/models/tool_result.dart';
import 'package:omnicore_ai/services/groq_service.dart';
import 'package:omnicore_ai/services/memory_intelligence_service.dart';
import 'package:omnicore_ai/services/runtime_diagnostics.dart';
import 'package:omnicore_ai/services/serpapi_retrieval_service.dart';
import 'package:omnicore_ai/services/tool_registry.dart';
import 'package:omnicore_ai/services/cancellation_token.dart';

void main() {
  testWidgets('OmniCore shell renders without Firebase boot',
      (WidgetTester tester) async {
    await tester.pumpWidget(const OmniCoreApp());
    await tester.pump();

    expect(find.text('OMNICORE AI'), findsOneWidget);
    expect(find.text('New Chat'), findsOneWidget);
  });

  test('chat sessions serialize and restore messages', () {
    final session = ChatSession(
      id: 'session-test',
      title: 'SerpApi integration',
      messages: [
        Message(
          id: 'msg-user',
          text: 'Hello',
          isUser: true,
          timestamp: DateTime.utc(2026, 5, 23, 10),
          mode: 'Smart',
        ),
        Message(
          id: 'msg-ai',
          text: 'Hi there',
          isUser: false,
          timestamp: DateTime.utc(2026, 5, 23, 10, 1),
          mode: 'Smart',
        ),
      ],
      lastInteraction: DateTime.utc(2026, 5, 23, 10, 1),
    );

    final restored = ChatSession.fromJson(session.toJson());

    expect(restored.id, session.id);
    expect(restored.title, session.title);
    expect(restored.messages, hasLength(2));
    expect(restored.messages.last.text, 'Hi there');
    expect(restored.messages.last.mode, 'Smart');
  });

  test('app state keeps a render-safe default session', () {
    AppState.sessions.value = [];
    AppState.selectedSessionId.value = 'missing';

    AppState.hydrateSessions(const []);

    expect(AppState.sessions.value, hasLength(1));
    expect(AppState.activeSession.value.id, 'default');
    expect(AppState.activeSession.value.title, 'New Chat Session');
  });

  test('memory commands are captured and ranked', () {
    final memory = MemoryIntelligenceService.memoryFromPrompt(
      'Remember this: I prefer Flutter for UI work',
    );

    expect(memory, isNotNull);
    expect(memory!.type, OmniMemoryType.preference);

    final relevant = MemoryIntelligenceService.retrieveRelevant(
      'Build a Flutter dashboard',
      [memory],
    );

    expect(relevant.single.id, memory.id);
  });

  test('retrieval tool plans for current and url requests', () {
    final registry = ToolRegistry();
    final tools = registry.plan(
      ToolExecutionRequest(
        prompt: 'summarize this URL https://example.com and verify sources',
        mode: 'Smart',
        cancellationToken: CancellationToken(),
      ),
    );

    expect(tools.map((tool) => tool.id), contains('serpapi-retrieval'));
  });

  test('retrieval preference can force or disable tool planning', () {
    final registry = ToolRegistry();
    final token = CancellationToken();

    final forced = registry.plan(
      ToolExecutionRequest(
        prompt: 'explain dependency injection',
        mode: 'Smart',
        cancellationToken: token,
        retrievalPreference: RetrievalPreference.force,
      ),
    );
    final disabled = registry.plan(
      ToolExecutionRequest(
        prompt: 'latest AI news',
        mode: 'Smart',
        cancellationToken: token,
        retrievalPreference: RetrievalPreference.disabled,
      ),
    );

    expect(forced.map((tool) => tool.id), contains('serpapi-retrieval'));
    expect(disabled, isEmpty);
  });

  test('developer controls are gated to the developer email', () {
    expect(AppState.isDeveloperEmail('intersprit123@gmail.com'), isTrue);
    expect(AppState.isDeveloperEmail('normal@example.com'), isFalse);
    expect(AppState.isDeveloperEmail(null), isFalse);
  });

  test('frontend defaults route provider traffic through local backend', () {
    expect(BackendConfig.baseUrl, 'http://localhost:3000');
    expect(BackendConfig.healthEndpoint, 'http://localhost:3000/health');
    expect(GroqService.endpoint, 'http://localhost:3000/groq');
    expect(
      SerpApiConfig.retrievalEndpoint,
      'http://localhost:3000/v1/retrieval',
    );
  });

  test('SerpApi retrieval exits cleanly when already cancelled', () async {
    final token = CancellationToken()..cancel();

    final result = await SerpApiRetrievalService.retrieve(
      prompt: 'latest AI news',
      mode: 'Smart',
      cancellationToken: token,
    );

    expect(result.status, ToolResultStatus.skipped);
  });
}
