import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/auth_service.dart';
import 'services/firestore_service.dart';
import 'services/memory_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'models/ai_memory.dart';
import 'services/ai_generation.dart';
import 'services/ai_router.dart';
import 'services/backend_configuration_service.dart';
import 'services/memory_intelligence_service.dart';
import 'services/runtime_diagnostics.dart';
import 'services/tool_registry.dart';
import 'models/chat_message.dart';

final isInitializing = ValueNotifier<bool>(true);
const Duration _localStartupTimeout = Duration(seconds: 5);
const Duration _remoteHydrationTimeout = Duration(seconds: 8);
int _authHydrationVersion = 0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OmniCoreApp());
  unawaited(_bootstrapAppServices());
}

Future<void> _bootstrapAppServices() async {
  try {
    await AppState.init().timeout(
      _localStartupTimeout,
      onTimeout: () {
        dev.log('Local app state initialization timed out.');
      },
    );
  } catch (error, stackTrace) {
    dev.log(
      'Local app state initialization failed; continuing with shell defaults.',
      error: error,
      stackTrace: stackTrace,
    );
    AppState.ensureDefaultSession();
  }

  unawaited(BackendConfigurationService.refreshStatus());

  AuthService.authStateChanges().listen(_handleAuthChange);

  try {
    await AuthService.initialize().timeout(_remoteHydrationTimeout);
  } catch (error, stackTrace) {
    dev.log(
      'Firebase initialization failed; continuing in local mode.',
      error: error,
      stackTrace: stackTrace,
    );
  }

  if (!AuthService.isInitialized) {
    isInitializing.value = false;
  }
}

Future<void> _handleAuthChange(User? user) async {
  final hydrationVersion = ++_authHydrationVersion;
  try {
    if (user != null) {
      await _syncUserProfile(user);
      if (hydrationVersion != _authHydrationVersion) return;

      final sessions = await _safeHydrationValue<List<ChatSession>>(
        label: 'Firestore session hydration failed.',
        fallback: AppState.sessions.value,
        task: () => FirestoreService.loadSessions(user.uid),
      );
      if (hydrationVersion != _authHydrationVersion) return;
      AppState.hydrateSessions(sessions);

      final memories = await _safeHydrationValue<List<OmniMemory>>(
        label: 'Firestore memory hydration failed.',
        fallback: AppState.memories.value,
        task: () => FirestoreService.loadMemories(user.uid),
      );
      if (hydrationVersion != _authHydrationVersion) return;
      AppState.memories.value = memories;
    } else {
      AppState.hydrateSessions(MemoryService.loadSessions());
      final loadedMemories = MemoryService.loadMemories();
      if (loadedMemories != null) {
        AppState.memories.value = loadedMemories;
      }
    }
  } catch (error, stackTrace) {
    dev.log(
      'Auth state hydration failed.',
      error: error,
      stackTrace: stackTrace,
    );
  } finally {
    isInitializing.value = false;
  }
}

Future<void> _syncUserProfile(User user) async {
  if (AppState.isLoggingInActive) return;
  await _safeHydrationTask(
    label: 'Firestore profile sync failed.',
    task: () async {
      final isFirst = await FirestoreService.isFirstTimeUser(user.uid);
      if (isFirst) {
        await FirestoreService.createUserProfile(user);
      } else {
        await FirestoreService.updateUserLastLogin(user.uid);
      }
    },
  );
}

Future<T> _safeHydrationValue<T>({
  required String label,
  required T fallback,
  required Future<T> Function() task,
}) async {
  try {
    return await task().timeout(_remoteHydrationTimeout);
  } catch (error, stackTrace) {
    dev.log(label, error: error, stackTrace: stackTrace);
    return fallback;
  }
}

Future<void> _safeHydrationTask({
  required String label,
  required Future<void> Function() task,
}) async {
  try {
    await task().timeout(_remoteHydrationTimeout);
  } catch (error, stackTrace) {
    dev.log(label, error: error, stackTrace: stackTrace);
  }
}

// ============================================================================
// MODELS
// ============================================================================

// ============================================================================
// APP STATE (LIGHTWEIGHT STATE MANAGEMENT)
// ============================================================================

class AppState {
  static bool isLoggingInActive = false;
  static final ChatSession _initialSession = _defaultSession();
  static final sessions = ValueNotifier<List<ChatSession>>([_initialSession]);
  static final selectedSessionId = ValueNotifier<String>('default');
  static final selectedMode = ValueNotifier<String>('Smart');
  static final retrievalPreference =
      ValueNotifier<RetrievalPreference>(RetrievalPreference.auto);
  static final isTyping = ValueNotifier<bool>(false);
  static final compactMode = ValueNotifier<bool>(false);
  static final sidebarCollapsed = ValueNotifier<bool>(false);
  static final memories = ValueNotifier<List<OmniMemory>>([]);
  static final activeSession = ValueNotifier<ChatSession>(_initialSession);
  static bool _prefsListenerAttached = false;
  static const developerEmail = 'intersprit123@gmail.com';

  static bool isDeveloperUser(User? user) {
    return isDeveloperEmail(user?.email);
  }

  static bool isDeveloperEmail(String? email) {
    return email?.toLowerCase().trim() == developerEmail;
  }

  static RetrievalPreference get effectiveRetrievalPreference {
    if (RuntimeDiagnostics.forceGroqOnlyMode.value) {
      return RetrievalPreference.disabled;
    }
    if (RuntimeDiagnostics.forceRetrievalMode.value) {
      return RetrievalPreference.force;
    }
    return retrievalPreference.value;
  }

  static ChatSession _defaultSession() {
    return ChatSession(
      id: 'default',
      title: 'New Chat Session',
      messages: const [],
      lastInteraction: DateTime.now(),
    );
  }

  static Future<void> init() async {
    // Initialize Hive box
    await MemoryService.init();
    // Load persisted sessions
    final loadedSessions = MemoryService.loadSessions();
    hydrateSessions(loadedSessions);
    // Load selected session ID
    final selSessionId = MemoryService.loadSelectedSessionId();
    if (selSessionId != null) {
      selectedSessionId.value = selSessionId;
    }
    // Load selected mode
    final selMode = MemoryService.loadSelectedMode();
    if (selMode != null) {
      selectedMode.value = selMode;
    }
    final loadedMemories = MemoryService.loadMemories();
    if (loadedMemories != null) {
      memories.value = loadedMemories;
    }
    ensureDefaultSession();

    if (_prefsListenerAttached) return;
    sessions.addListener(_savePrefs);
    selectedSessionId.addListener(_savePrefs);
    selectedMode.addListener(_savePrefs);
    memories.addListener(_savePrefs);
    _prefsListenerAttached = true;
  }

  static Future<void> _savePrefs() async {
    try {
      await MemoryService.saveSessions(sessions.value);
      await MemoryService.saveSelectedSessionId(selectedSessionId.value);
      await MemoryService.saveSelectedMode(selectedMode.value);
      await MemoryService.saveMemories(memories.value);
    } catch (error, stackTrace) {
      dev.log(
        'Local preference persistence failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static void hydrateSessions(List<ChatSession>? loadedSessions) {
    if (loadedSessions != null && loadedSessions.isNotEmpty) {
      sessions.value = loadedSessions;
    } else if (sessions.value.isEmpty) {
      sessions.value = [_defaultSession()];
    }
    ensureDefaultSession();
  }

  static void ensureDefaultSession() {
    if (sessions.value.isEmpty) {
      final session = _defaultSession();
      sessions.value = [session];
      selectedSessionId.value = session.id;
      activeSession.value = session;
      return;
    }

    final active = sessions.value.firstWhere(
      (s) => s.id == selectedSessionId.value,
      orElse: () => sessions.value.first,
    );
    selectedSessionId.value = active.id;
    activeSession.value = active;
  }

  static void selectSession(String sessionId) {
    if (sessions.value.isEmpty) {
      ensureDefaultSession();
      return;
    }
    final session = sessions.value.firstWhere(
      (s) => s.id == sessionId,
      orElse: () => sessions.value.first,
    );
    selectedSessionId.value = sessionId;
    activeSession.value = session;
  }

  static void createNewChat() {
    final newId = 'session-${DateTime.now().millisecondsSinceEpoch}';
    final newSession = ChatSession(
      id: newId,
      title: 'New Chat Session',
      messages: [],
      lastInteraction: DateTime.now(),
    );
    sessions.value = [newSession, ...sessions.value];
    selectedSessionId.value = newId;
    activeSession.value = newSession;
    unawaited(_saveSessionToCloud(newSession));
  }

  static void deleteSession(String sessionId) {
    if (sessions.value.length <= 1) {
      final cleanSession = _defaultSession();
      sessions.value = [cleanSession];
      selectSession('default');
      return;
    }
    final updatedList = List<ChatSession>.from(sessions.value)
      ..removeWhere((s) => s.id == sessionId);
    sessions.value = updatedList;
    if (selectedSessionId.value == sessionId) {
      selectSession(updatedList.first.id);
    }
    unawaited(_deleteSessionFromCloud(sessionId));
    unawaited(_savePrefs());
  }

  static void addMessage(
    String text,
    bool isUser, {
    String? customMode,
    bool persistToCloud = true,
  }) {
    final currentSes = activeSession.value;
    final modeUsed = customMode ?? selectedMode.value;
    final newMessage = Message(
      id: 'msg-${DateTime.now().millisecondsSinceEpoch}-${isUser ? "user" : "ai"}',
      text: text,
      isUser: isUser,
      timestamp: DateTime.now(),
      mode: modeUsed,
    );
    final updatedMessages = List<Message>.from(currentSes.messages)
      ..add(newMessage);
    String updatedTitle = currentSes.title;
    if (isUser && currentSes.messages.isEmpty) {
      updatedTitle = text.length > 25 ? '${text.substring(0, 22)}...' : text;
    }
    final updatedSession = ChatSession(
      id: currentSes.id,
      title: updatedTitle,
      messages: updatedMessages,
      lastInteraction: DateTime.now(),
    );
    activeSession.value = updatedSession;

    final list = List<ChatSession>.from(sessions.value);
    final index = list.indexWhere((s) => s.id == currentSes.id);
    if (index != -1) {
      list[index] = updatedSession;
      final item = list.removeAt(index);
      sessions.value = [item, ...list];
    } else {
      sessions.value = [updatedSession, ...list];
    }
    if (persistToCloud) {
      unawaited(_saveSessionToCloud(updatedSession));
    }
  }

  static void updateMessageText(String messageId, String text) {
    final currentSes = activeSession.value;
    final updatedMessages = currentSes.messages
        .map((message) =>
            message.id == messageId ? message.copyWith(text: text) : message)
        .toList();
    final updatedSession = ChatSession(
      id: currentSes.id,
      title: currentSes.title,
      messages: updatedMessages,
      lastInteraction: DateTime.now(),
    );
    activeSession.value = updatedSession;

    final list = List<ChatSession>.from(sessions.value);
    final index = list.indexWhere((s) => s.id == currentSes.id);
    if (index != -1) {
      list[index] = updatedSession;
      sessions.value = list;
    }
    unawaited(_saveSessionToCloud(updatedSession));
  }

  static void truncateSessionAfterMessage(String messageId) {
    final currentSes = activeSession.value;
    final index =
        currentSes.messages.indexWhere((message) => message.id == messageId);
    if (index == -1) return;

    final updatedSession = ChatSession(
      id: currentSes.id,
      title: currentSes.title,
      messages: currentSes.messages.take(index + 1).toList(),
      lastInteraction: DateTime.now(),
    );
    activeSession.value = updatedSession;

    final list = List<ChatSession>.from(sessions.value);
    final sessionIndex = list.indexWhere((s) => s.id == currentSes.id);
    if (sessionIndex != -1) {
      list[sessionIndex] = updatedSession;
      sessions.value = list;
    }
    unawaited(_saveSessionToCloud(updatedSession));
  }

  static void updateLastAIMessage(String text) {
    final currentSes = activeSession.value;
    if (currentSes.messages.isEmpty) {
      dev.log(
        'UI state update skipped: no messages exist for assistant text length=${text.length}',
      );
      return;
    }
    final updatedMessages = List<Message>.from(currentSes.messages);
    final lastIndex = updatedMessages.length - 1;
    if (!updatedMessages[lastIndex].isUser) {
      updatedMessages[lastIndex] =
          updatedMessages[lastIndex].copyWith(text: text);
      final updatedSession = ChatSession(
        id: currentSes.id,
        title: currentSes.title,
        messages: updatedMessages,
        lastInteraction: DateTime.now(),
      );
      activeSession.value = updatedSession;

      final list = List<ChatSession>.from(sessions.value);
      final index = list.indexWhere((s) => s.id == currentSes.id);
      if (index != -1) {
        list[index] = updatedSession;
        sessions.value = list;
      } else {
        sessions.value = [updatedSession, ...list];
      }
      dev.log(
        'UI state update applied: assistant message id=${updatedMessages[lastIndex].id} textLength=${text.length}',
      );
    } else {
      dev.log(
        'UI state update skipped: last message is user; assistant text length=${text.length}',
      );
    }
  }

  static void persistActiveSession() {
    unawaited(_savePrefs());
    unawaited(_saveSessionToCloud(activeSession.value));
  }

  static Future<OmniMemory?> captureMemoryCommand(String prompt) async {
    final forgetTarget =
        MemoryIntelligenceService.forgetTargetFromPrompt(prompt);
    if (forgetTarget != null && forgetTarget.isNotEmpty) {
      forgetMemoryMatching(forgetTarget);
      return null;
    }

    final memory = MemoryIntelligenceService.memoryFromPrompt(prompt);
    if (memory == null) return null;
    await saveMemory(memory);
    return memory;
  }

  static Future<void> saveMemory(OmniMemory memory) async {
    final existing = memories.value.where((m) => m.id != memory.id).toList();
    memories.value = [memory, ...existing];
    try {
      await MemoryService.saveMemories(memories.value);
    } catch (error, stackTrace) {
      dev.log(
        'Local memory persistence failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
    unawaited(_saveMemoryToCloud(memory));
  }

  static void forgetMemory(String memoryId) {
    memories.value = memories.value.where((m) => m.id != memoryId).toList();
    unawaited(_savePrefs());
    unawaited(_deleteMemoryFromCloud(memoryId));
  }

  static void forgetMemoryMatching(String query) {
    final lowerQuery = query.toLowerCase();
    OmniMemory? match;
    for (final memory in memories.value) {
      if (memory.text.toLowerCase().contains(lowerQuery)) {
        match = memory;
        break;
      }
    }
    if (match != null) forgetMemory(match.id);
  }

  static List<OmniMemory> relevantMemoriesFor(String prompt) {
    return MemoryIntelligenceService.retrieveRelevant(prompt, memories.value);
  }

  static Future<void> _saveSessionToCloud(ChatSession session) async {
    final user = AuthService.currentUser;
    if (user == null) return;
    try {
      await FirestoreService.saveSession(user.uid, session)
          .timeout(_remoteHydrationTimeout);
    } catch (error, stackTrace) {
      dev.log(
        'Cloud session persistence failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static Future<void> _deleteSessionFromCloud(String sessionId) async {
    final user = AuthService.currentUser;
    if (user == null) return;
    try {
      await FirestoreService.deleteSession(user.uid, sessionId)
          .timeout(_remoteHydrationTimeout);
    } catch (error, stackTrace) {
      dev.log(
        'Cloud session deletion failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static Future<void> _saveMemoryToCloud(OmniMemory memory) async {
    final user = AuthService.currentUser;
    if (user == null) return;
    try {
      await FirestoreService.saveMemory(user.uid, memory)
          .timeout(_remoteHydrationTimeout);
    } catch (error, stackTrace) {
      dev.log(
        'Cloud memory persistence failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static Future<void> _deleteMemoryFromCloud(String memoryId) async {
    final user = AuthService.currentUser;
    if (user == null) return;
    try {
      await FirestoreService.deleteMemory(user.uid, memoryId)
          .timeout(_remoteHydrationTimeout);
    } catch (error, stackTrace) {
      dev.log(
        'Cloud memory deletion failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

// ============================================================================
// THEME & COLOR PALETTE
// ============================================================================

class AppColors {
  static const background = Color(0xFF08090C);
  static const sidebarBackground = Color(0xFF0E1017);
  static const cardBackground = Color(0xFF141722);
  static const border = Color(0xFF1F2335);
  static const borderStrong = Color(0xFF2A3148);
  static const surfaceSoft = Color(0xFF10131D);
  static const surfaceHigh = Color(0xFF191D2B);

  static const userBubble = Color(0xFF1E2135);
  static const aiBubble = Color(0xFF111424);

  static const textPrimary = Color(0xFFE2E8F0);
  static const textSecondary = Color(0xFF94A3B8);
  static const textMuted = Color(0xFF64748B);

  // Neon accents
  static const cyan = Color(0xFF00FFCC);
  static const blue = Color(0xFF3B82F6);
  static const purple = Color(0xFF8B5CF6);
  static const pink = Color(0xFFEC4899);
  static const gold = Color(0xFFF59E0B);
  static const stop = Color(0xFFFF4D6D);

  static Color getModeColor(String mode) {
    switch (mode) {
      case 'Fast':
        return cyan;
      case 'Smart':
        return blue;
      case 'Code':
        return purple;
      case 'Creative':
        return pink;
      case 'Auto':
        return gold;
      default:
        return blue;
    }
  }
}

void showOmniSettingsMenu(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.58),
    builder: (context) {
      return const _SettingsPanel();
    },
  );
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel();

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height * 0.88, maxWidth: 980),
        child: Container(
          margin: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: AppColors.cyan.withValues(alpha: 0.16),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.cyan.withValues(alpha: 0.08),
                blurRadius: 34,
                offset: const Offset(0, -14),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: StreamBuilder<User?>(
              stream: AuthService.authStateChanges(),
              builder: (context, snapshot) {
                final user = snapshot.data;
                final isDeveloper = AppState.isDeveloperUser(user);

                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SettingsHeader(user: user),
                      const SizedBox(height: 18),
                      _NormalSettingsGrid(user: user),
                      if (isDeveloper) ...[
                        const SizedBox(height: 20),
                        const _DeveloperConfigurationPanel(),
                        const SizedBox(height: 14),
                        const _DeveloperOperationsPanel(),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader({required this.user});

  final User? user;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient:
                const LinearGradient(colors: [AppColors.cyan, AppColors.blue]),
          ),
          child: const Icon(Icons.tune, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'OmniCore Control Deck',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                user?.email ?? 'Local session',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
          color: AppColors.textSecondary,
        ),
      ],
    );
  }
}

class _NormalSettingsGrid extends StatelessWidget {
  const _NormalSettingsGrid({required this.user});

  final User? user;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumn = constraints.maxWidth > 720;
        final width =
            twoColumn ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: width,
              child: _SettingsTile(
                icon: Icons.person_outline,
                title: 'Profile',
                subtitle: user?.displayName ?? user?.email ?? 'Guest profile',
                accent: AppColors.cyan,
              ),
            ),
            SizedBox(
              width: width,
              child: const _SettingsTile(
                icon: Icons.settings_outlined,
                title: 'Settings',
                subtitle: 'Runtime preferences and session controls',
                accent: AppColors.blue,
              ),
            ),
            SizedBox(
              width: width,
              child: ValueListenableBuilder<bool>(
                valueListenable: AppState.compactMode,
                builder: (context, compact, _) {
                  return _SettingsTile(
                    icon: Icons.contrast,
                    title: 'Appearance',
                    subtitle:
                        compact ? 'Compact chat density' : 'Comfort density',
                    accent: AppColors.purple,
                    trailing: Switch(
                      value: compact,
                      onChanged: (value) => AppState.compactMode.value = value,
                      activeThumbColor: AppColors.cyan,
                    ),
                  );
                },
              ),
            ),
            SizedBox(
              width: width,
              child: ValueListenableBuilder<List<ChatSession>>(
                valueListenable: AppState.sessions,
                builder: (context, sessions, _) {
                  return _SettingsTile(
                    icon: Icons.forum_outlined,
                    title: 'Saved Chats',
                    subtitle: '${sessions.length} local/cloud sessions visible',
                    accent: AppColors.gold,
                  );
                },
              ),
            ),
            SizedBox(
              width: width,
              child: ValueListenableBuilder<List<OmniMemory>>(
                valueListenable: AppState.memories,
                builder: (context, memories, _) {
                  return _SettingsTile(
                    icon: Icons.memory,
                    title: 'Memory',
                    subtitle: '${memories.length} saved memory entries',
                    accent: AppColors.gold,
                  );
                },
              ),
            ),
            SizedBox(
              width: width,
              child: ValueListenableBuilder<RetrievalPreference>(
                valueListenable: AppState.retrievalPreference,
                builder: (context, preference, _) {
                  return _SettingsTile(
                    icon: Icons.travel_explore,
                    title: 'Retrieval Preferences',
                    subtitle: 'Per-message live search: ${preference.label}',
                    accent: AppColors.cyan,
                    trailing: _RetrievalSegmentedControl(value: preference),
                  );
                },
              ),
            ),
            SizedBox(
              width: width,
              child: _SettingsTile(
                icon: Icons.logout,
                title: 'Logout',
                subtitle:
                    user == null ? 'No active account' : 'End session safely',
                accent: AppColors.stop,
                onTap: user == null
                    ? null
                    : () async {
                        await AuthService.signOut();
                        AppState.selectSession('default');
                        if (context.mounted) Navigator.pop(context);
                      },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RetrievalSegmentedControl extends StatelessWidget {
  const _RetrievalSegmentedControl({required this.value});

  final RetrievalPreference value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: RetrievalPreference.values.map((preference) {
          final selected = value == preference;
          return InkWell(
            onTap: () => AppState.retrievalPreference.value = preference,
            borderRadius: BorderRadius.circular(11),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.cyan.withValues(alpha: 0.16)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                preference.label,
                style: TextStyle(
                  color: selected ? AppColors.cyan : AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      hoverColor: accent.withValues(alpha: 0.06),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        constraints: const BoxConstraints(minHeight: 74),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceSoft.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.11),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accent.withValues(alpha: 0.20)),
              ),
              child: Icon(icon, color: accent, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _DeveloperConfigurationPanel extends StatefulWidget {
  const _DeveloperConfigurationPanel();

  @override
  State<_DeveloperConfigurationPanel> createState() =>
      _DeveloperConfigurationPanelState();
}

class _DeveloperConfigurationPanelState
    extends State<_DeveloperConfigurationPanel> {
  final TextEditingController _groqKeyController = TextEditingController();
  final TextEditingController _serpApiKeyController = TextEditingController();
  final TextEditingController _serperKeyController = TextEditingController();
  final TextEditingController _googleKeyController = TextEditingController();
  final TextEditingController _googleEngineController = TextEditingController();
  final TextEditingController _tavilyKeyController = TextEditingController();
  final TextEditingController _braveKeyController = TextEditingController();
  bool _isSaving = false;
  String _busyProvider = '';

  @override
  void initState() {
    super.initState();
    unawaited(BackendConfigurationService.refreshStatus());
  }

  @override
  void dispose() {
    _groqKeyController.dispose();
    _serpApiKeyController.dispose();
    _serperKeyController.dispose();
    _googleKeyController.dispose();
    _googleEngineController.dispose();
    _tavilyKeyController.dispose();
    _braveKeyController.dispose();
    super.dispose();
  }

  Future<void> _saveKeys() async {
    final hasAnyValue = [
      _groqKeyController,
      _serpApiKeyController,
      _serperKeyController,
      _googleKeyController,
      _googleEngineController,
      _tavilyKeyController,
      _braveKeyController,
    ].any((controller) => controller.text.trim().isNotEmpty);
    if (!hasAnyValue) {
      _showSnack('Enter at least one key or provider value to save.');
      return;
    }

    setState(() => _isSaving = true);
    try {
      await BackendConfigurationService.saveKeys(
        groqApiKey: _groqKeyController.text,
        serpApiKey: _serpApiKeyController.text,
        serperApiKey: _serperKeyController.text,
        googleSearchApiKey: _googleKeyController.text,
        googleSearchEngineId: _googleEngineController.text,
        tavilyApiKey: _tavilyKeyController.text,
        braveSearchApiKey: _braveKeyController.text,
      );
      _groqKeyController.clear();
      _serpApiKeyController.clear();
      _serperKeyController.clear();
      _googleKeyController.clear();
      _googleEngineController.clear();
      _tavilyKeyController.clear();
      _braveKeyController.clear();
      _showSnack('Configuration saved.');
    } catch (error) {
      _showSnack('Configuration save failed.');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _setProviderEnabled(
    BackendSearchProviderStatus provider,
    bool enabled,
  ) async {
    setState(() => _busyProvider = provider.id);
    try {
      await BackendConfigurationService.updateSearchProvider(
        provider: provider.id,
        enabled: enabled,
      );
      _showSnack('${provider.name} ${enabled ? 'enabled' : 'disabled'}.');
    } catch (_) {
      _showSnack('Provider update failed.');
    } finally {
      if (mounted) setState(() => _busyProvider = '');
    }
  }

  Future<void> _moveProvider(
    List<BackendSearchProviderStatus> providers,
    int index,
    int delta,
  ) async {
    final nextIndex = index + delta;
    if (nextIndex < 0 || nextIndex >= providers.length) return;
    final ordered = [...providers]..sort((a, b) => a.priority - b.priority);
    final item = ordered.removeAt(index);
    ordered.insert(nextIndex, item);
    setState(() => _busyProvider = item.id);
    try {
      await BackendConfigurationService.updateSearchProviderOrder(
        ordered.map((provider) => provider.id).toList(growable: false),
      );
    } catch (_) {
      _showSnack('Provider priority update failed.');
    } finally {
      if (mounted) setState(() => _busyProvider = '');
    }
  }

  Future<void> _testProvider(BackendSearchProviderStatus provider) async {
    setState(() => _busyProvider = provider.id);
    try {
      final result = await BackendConfigurationService.testSearchProvider(
        provider.id,
      );
      _showSnack(
        result['ok'] == true
            ? '${provider.name} test passed.'
            : '${provider.name} test failed.',
      );
    } catch (_) {
      _showSnack('${provider.name} test failed.');
    } finally {
      if (mounted) setState(() => _busyProvider = '');
    }
  }

  Future<void> _showProviderConfigDialog(
    BackendSearchProviderStatus provider,
  ) async {
    final controllers = {
      for (final field in provider.configFields)
        field.name: TextEditingController(),
    };
    final dailyQuotaController = TextEditingController();
    final monthlyQuotaController = TextEditingController();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceHigh,
          title: Text(
            'Configure ${provider.name}',
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final field in provider.configFields) ...[
                  TextField(
                    controller: controllers[field.name],
                    obscureText: field.secret,
                    enableSuggestions: !field.secret,
                    autocorrect: false,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: field.keyExists
                          ? '${field.label} (${field.keyPreview})'
                          : field.label,
                      labelStyle: const TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: dailyQuotaController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Daily quota limit',
                    labelStyle: TextStyle(color: AppColors.textMuted),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: monthlyQuotaController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Monthly quota limit',
                    labelStyle: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop({
                  for (final entry in controllers.entries)
                    entry.key: entry.value.text,
                  'dailyQuota': dailyQuotaController.text,
                  'monthlyQuota': monthlyQuotaController.text,
                });
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    for (final controller in controllers.values) {
      controller.dispose();
    }
    dailyQuotaController.dispose();
    monthlyQuotaController.dispose();
    if (result == null) return;

    setState(() => _busyProvider = provider.id);
    try {
      await BackendConfigurationService.updateSearchProvider(
        provider: provider.id,
        fields: {
          for (final field in provider.configFields)
            field.name: result[field.name] ?? '',
        },
        dailyQuota: int.tryParse(result['dailyQuota'] ?? ''),
        monthlyQuota: int.tryParse(result['monthlyQuota'] ?? ''),
      );
      _showSnack('${provider.name} configuration saved.');
    } catch (_) {
      _showSnack('${provider.name} configuration failed.');
    } finally {
      if (mounted) setState(() => _busyProvider = '');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BackendConfigurationStatus>(
      valueListenable: BackendConfigurationService.status,
      builder: (context, status, _) {
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.cyan.withValues(alpha: 0.24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.key, color: AppColors.cyan),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Developer Configuration',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: () =>
                        BackendConfigurationService.refreshStatus(),
                    icon: const Icon(Icons.refresh),
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final twoColumn = constraints.maxWidth > 720;
                  final width = twoColumn
                      ? (constraints.maxWidth - 12) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: width,
                        child: _SettingsTile(
                          icon: status.backendConnected
                              ? Icons.cloud_done
                              : Icons.cloud_off,
                          title: 'Backend',
                          subtitle: status.backendConnected
                              ? 'Connected: ${status.backendUrl}'
                              : 'Disconnected: ${status.backendUrl}',
                          accent: status.backendConnected
                              ? AppColors.cyan
                              : AppColors.stop,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _SettingsTile(
                          icon: status.dotenvLoaded
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          title: 'dotenv',
                          subtitle:
                              status.dotenvLoaded ? 'Loaded' : 'Not loaded',
                          accent: status.dotenvLoaded
                              ? AppColors.cyan
                              : AppColors.gold,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _SettingsTile(
                          icon: Icons.bolt,
                          title: 'Groq API Key',
                          subtitle: status.groqKeyExists
                              ? 'Configured (${status.groqKeyPreview})'
                              : 'Missing',
                          accent: status.groqKeyExists
                              ? AppColors.cyan
                              : AppColors.stop,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _SettingsTile(
                          icon: Icons.travel_explore,
                          title: 'SerpApi Key',
                          subtitle: status.serpApiKeyExists
                              ? 'Configured (${status.serpApiKeyPreview})'
                              : 'Missing',
                          accent: status.serpApiKeyExists
                              ? AppColors.cyan
                              : AppColors.stop,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final twoColumn = constraints.maxWidth > 720;
                  final width = twoColumn
                      ? (constraints.maxWidth - 12) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: width,
                        child: _SecretField(
                          controller: _groqKeyController,
                          label: 'New Groq Key',
                          icon: Icons.bolt,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _SecretField(
                          controller: _serpApiKeyController,
                          label: 'New SerpApi Key',
                          icon: Icons.travel_explore,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _SecretField(
                          controller: _serperKeyController,
                          label: 'New Serper Key',
                          icon: Icons.search,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _SecretField(
                          controller: _googleKeyController,
                          label: 'New Google Search Key',
                          icon: Icons.public,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _SecretField(
                          controller: _googleEngineController,
                          label: 'Google Search Engine ID',
                          icon: Icons.tag,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _SecretField(
                          controller: _tavilyKeyController,
                          label: 'New Tavily Key',
                          icon: Icons.hub,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _SecretField(
                          controller: _braveKeyController,
                          label: 'New Brave Search Key',
                          icon: Icons.shield,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              _SearchProviderDashboard(
                providers: status.searchProviders,
                busyProvider: _busyProvider,
                onToggle: _setProviderEnabled,
                onMove: _moveProvider,
                onTest: _testProvider,
                onConfigure: _showProviderConfigDialog,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: _isSaving
                        ? null
                        : () => BackendConfigurationService.refreshStatus(),
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text('Check'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _isSaving ? null : _saveKeys,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save, size: 16),
                    label: const Text('Save Keys'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.cyan,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SecretField extends StatelessWidget {
  const _SecretField({
    required this.controller,
    required this.label,
    required this.icon,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppColors.textMuted),
        prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 18),
        filled: true,
        fillColor: AppColors.background.withValues(alpha: 0.42),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.cyan),
        ),
      ),
    );
  }
}

class _SearchProviderDashboard extends StatelessWidget {
  const _SearchProviderDashboard({
    required this.providers,
    required this.busyProvider,
    required this.onToggle,
    required this.onMove,
    required this.onTest,
    required this.onConfigure,
  });

  final List<BackendSearchProviderStatus> providers;
  final String busyProvider;
  final Future<void> Function(
      BackendSearchProviderStatus provider, bool enabled) onToggle;
  final Future<void> Function(
    List<BackendSearchProviderStatus> providers,
    int index,
    int delta,
  ) onMove;
  final Future<void> Function(BackendSearchProviderStatus provider) onTest;
  final Future<void> Function(BackendSearchProviderStatus provider) onConfigure;

  @override
  Widget build(BuildContext context) {
    final ordered = [...providers]..sort((a, b) => a.priority - b.priority);
    if (ordered.isEmpty) {
      return const _SettingsTile(
        icon: Icons.travel_explore,
        title: 'Search Providers',
        subtitle: 'No provider status reported by the backend',
        accent: AppColors.gold,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'SEARCH PROVIDER DASHBOARD',
          style: TextStyle(
            color: AppColors.cyan,
            fontSize: 10,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth > 860
                ? (constraints.maxWidth - 12) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final entry in ordered.indexed)
                  SizedBox(
                    width: width,
                    child: _SearchProviderCard(
                      provider: entry.$2,
                      index: entry.$1,
                      total: ordered.length,
                      busy: busyProvider == entry.$2.id,
                      providers: ordered,
                      onToggle: onToggle,
                      onMove: onMove,
                      onTest: onTest,
                      onConfigure: onConfigure,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _SearchProviderCard extends StatelessWidget {
  const _SearchProviderCard({
    required this.provider,
    required this.index,
    required this.total,
    required this.busy,
    required this.providers,
    required this.onToggle,
    required this.onMove,
    required this.onTest,
    required this.onConfigure,
  });

  final BackendSearchProviderStatus provider;
  final int index;
  final int total;
  final bool busy;
  final List<BackendSearchProviderStatus> providers;
  final Future<void> Function(
      BackendSearchProviderStatus provider, bool enabled) onToggle;
  final Future<void> Function(
    List<BackendSearchProviderStatus> providers,
    int index,
    int delta,
  ) onMove;
  final Future<void> Function(BackendSearchProviderStatus provider) onTest;
  final Future<void> Function(BackendSearchProviderStatus provider) onConfigure;

  @override
  Widget build(BuildContext context) {
    final accent = provider.active
        ? AppColors.cyan
        : provider.configured && provider.enabled
            ? AppColors.blue
            : AppColors.gold;
    final status = provider.configured
        ? provider.enabled
            ? 'Enabled'
            : 'Disabled'
        : 'Needs key';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.travel_explore, color: accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${provider.name}${provider.active ? ' (active)' : ''}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ProviderMetric(label: 'State', value: status),
              _ProviderMetric(label: 'Priority', value: '${provider.priority}'),
              _ProviderMetric(label: 'Health', value: '${provider.health}%'),
              _ProviderMetric(
                label: 'Latency',
                value: provider.averageLatencyMs == 0
                    ? 'n/a'
                    : '${provider.averageLatencyMs} ms',
              ),
              _ProviderMetric(
                label: 'Success',
                value: '${provider.successRate.toStringAsFixed(1)}%',
              ),
              _ProviderMetric(
                label: 'Requests',
                value: '${provider.requestCount}',
              ),
              _ProviderMetric(
                label: 'Circuit',
                value:
                    '${provider.circuitState} ${provider.circuitFailures}/${provider.circuitThreshold}',
              ),
              _ProviderMetric(label: 'Quota', value: provider.quotaStatus),
            ],
          ),
          if (provider.lastError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              provider.lastError,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.stop, fontSize: 11),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            children: [
              IconButton.filledTonal(
                tooltip: 'Move up',
                onPressed: busy || index == 0
                    ? null
                    : () => onMove(providers, index, -1),
                icon: const Icon(Icons.arrow_upward, size: 16),
              ),
              IconButton.filledTonal(
                tooltip: 'Move down',
                onPressed: busy || index == total - 1
                    ? null
                    : () => onMove(providers, index, 1),
                icon: const Icon(Icons.arrow_downward, size: 16),
              ),
              TextButton.icon(
                onPressed: busy ? null : () => onConfigure(provider),
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('Configure'),
              ),
              TextButton.icon(
                onPressed: busy ? null : () => onTest(provider),
                icon: const Icon(Icons.network_ping, size: 16),
                label: const Text('Test'),
              ),
              Switch(
                value: provider.enabled,
                onChanged: busy ? null : (value) => onToggle(provider, value),
                activeThumbColor: AppColors.cyan,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProviderMetric extends StatelessWidget {
  const _ProviderMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 86),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceSoft.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeveloperOperationsPanel extends StatelessWidget {
  const _DeveloperOperationsPanel();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RuntimeSnapshot>(
      valueListenable: RuntimeDiagnostics.snapshot,
      builder: (context, snapshot, _) {
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.surfaceHigh.withValues(alpha: 0.82),
                AppColors.background.withValues(alpha: 0.44),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.purple.withValues(alpha: 0.26)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.admin_panel_settings, color: AppColors.purple),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Developer Operations',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _DevSection(
                title: 'System Status',
                rows: {
                  'Groq Status': snapshot.groqConnectivity,
                  'SerpApi Status': snapshot.serpApiConnectivity,
                  'Backend Status': snapshot.backendConnectivity,
                  'Retrieval Status': snapshot.retrievalStatus,
                  'Memory Status': MemoryService.isReady
                      ? '${AppState.memories.value.length} entries loaded'
                      : 'Local memory cache unavailable',
                },
              ),
              _DevSection(
                title: 'Diagnostics',
                rows: {
                  'Last Error': snapshot.lastError ?? 'No errors recorded',
                  'Last Provider Response': snapshot.lastProviderResponse,
                  'Last Retrieval Event': snapshot.lastRetrievalEvent,
                  'Active Model': snapshot.activeModel,
                  'Current Backend URL': snapshot.currentBackendUrl,
                },
              ),
              _DevSection(
                title: 'AI Systems',
                rows: {
                  'Provider Status': snapshot.providerStatus,
                  'Worker Health': snapshot.workerHealth,
                  'Orchestrator Status': snapshot.orchestratorStatus,
                },
              ),
              _DevSection(
                title: 'Streaming + Performance',
                rows: {
                  'Streaming Inspector': snapshot.streamState,
                  'Active Stream State':
                      snapshot.isStreaming ? 'Active' : 'Idle',
                  'Send/Stop Debug State': snapshot.sendStopState,
                  'Latency Metrics': snapshot.latencyMs == null
                      ? 'Waiting for first token'
                      : '${snapshot.latencyMs} ms to first token',
                  'Performance Metrics':
                      '${snapshot.chunkCount} chunks / ${snapshot.characterCount} chars',
                  'Response Timing': snapshot.totalMs == null
                      ? 'In progress or idle'
                      : '${snapshot.totalMs} ms total',
                },
              ),
              _DevSection(
                title: 'Retrieval + Memory',
                rows: {
                  'Retrieval Inspector': snapshot.retrievalStatus,
                  'Last Search Results': snapshot.lastSources.isEmpty
                      ? 'No sources captured'
                      : snapshot.lastSources
                          .take(3)
                          .map((source) => source.title)
                          .join(' | '),
                  'Memory Inspector':
                      '${AppState.memories.value.length} memory entries loaded',
                  'Context Injection Viewer': snapshot.contextPreview.isEmpty
                      ? 'No context injected'
                      : snapshot.contextPreview,
                  'Retrieved Context Preview':
                      snapshot.lastSearchSummary.isEmpty
                          ? 'No retrieval payload'
                          : snapshot.lastSearchSummary,
                },
              ),
              _DevSection(
                title: 'Routing + Orchestration',
                rows: {
                  'Router Decisions': snapshot.routerDecision,
                  'Tool Activation Logs': snapshot.toolActivationLogs.isEmpty
                      ? 'No tool activations yet'
                      : snapshot.toolActivationLogs.join(' | '),
                  'Fallback Events': snapshot.fallbackEvents.isEmpty
                      ? 'No fallback events'
                      : snapshot.fallbackEvents.join(' | '),
                  'Retrieval Trigger Reasons': snapshot.retrievalTriggerReason,
                },
              ),
              const SizedBox(height: 8),
              const _DeveloperToggles(),
              const SizedBox(height: 12),
              const _FutureToolsStrip(),
            ],
          ),
        );
      },
    );
  }
}

class _DevSection extends StatelessWidget {
  const _DevSection({required this.title, required this.rows});

  final String title;
  final Map<String, String> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: AppColors.cyan,
              fontSize: 10,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 9),
          ...rows.entries.map((entry) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 168,
                    child: Text(
                      entry.key,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entry.value,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _DeveloperToggles extends StatelessWidget {
  const _DeveloperToggles();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth > 720
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _devToggle(
              width: itemWidth,
              listenable: RuntimeDiagnostics.forceGroqOnlyMode,
              title: 'Force Groq-only Mode',
              subtitle:
                  'Disable retrieval injection while preserving Groq streaming',
            ),
            _devToggle(
              width: itemWidth,
              listenable: RuntimeDiagnostics.forceRetrievalMode,
              title: 'Force Retrieval Mode',
              subtitle: 'Run live search for every prompt',
            ),
            _devToggle(
              width: itemWidth,
              listenable: RuntimeDiagnostics.experimentalFeatures,
              title: 'Experimental Features Toggle',
              subtitle: 'Expose future tool hooks without activating them',
            ),
            _devToggle(
              width: itemWidth,
              listenable: RuntimeDiagnostics.debugOverlayEnabled,
              title: 'Debug Overlay Toggle',
              subtitle: 'Show live stream and retrieval telemetry over chat',
            ),
          ],
        );
      },
    );
  }

  Widget _devToggle({
    required double width,
    required ValueNotifier<bool> listenable,
    required String title,
    required String subtitle,
  }) {
    return SizedBox(
      width: width,
      child: ValueListenableBuilder<bool>(
        valueListenable: listenable,
        builder: (context, value, _) {
          return _SettingsTile(
            icon: value ? Icons.toggle_on : Icons.toggle_off,
            title: title,
            subtitle: subtitle,
            accent: value ? AppColors.cyan : AppColors.textMuted,
            trailing: Switch(
              value: value,
              onChanged: (next) => listenable.value = next,
              activeThumbColor: AppColors.cyan,
            ),
          );
        },
      ),
    );
  }
}

class _FutureToolsStrip extends StatelessWidget {
  const _FutureToolsStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'FUTURE TOOLS PLACEHOLDER',
            style: TextStyle(
              color: AppColors.gold,
              fontSize: 10,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ToolRegistry.futureTools.map((tool) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSoft.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: AppColors.gold.withValues(alpha: 0.18),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _iconForFutureTool(tool.iconName),
                      size: 14,
                      color: AppColors.gold,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      tool.name,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  IconData _iconForFutureTool(String name) {
    switch (name) {
      case 'upload_file':
        return Icons.upload_file;
      case 'image_search':
        return Icons.image_search;
      case 'calculate':
        return Icons.calculate;
      case 'link':
        return Icons.link;
      case 'account_tree':
        return Icons.account_tree;
      case 'hub':
        return Icons.hub;
      default:
        return Icons.auto_awesome_motion;
    }
  }
}

// ============================================================================
// FLUTTER APPLICATION
// ============================================================================

class OmniCoreApp extends StatelessWidget {
  const OmniCoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OmniCore AI',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.cyan,
          secondary: AppColors.blue,
          surface: AppColors.cardBackground,
          onSurface: AppColors.textPrimary,
        ),
        fontFamily: 'Segoe UI',
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isMobile = screenWidth < 768;

    return Scaffold(
      key: _scaffoldKey,
      drawer: isMobile
          ? const Drawer(
              backgroundColor: AppColors.sidebarBackground,
              child: SidebarWidget(isDrawer: true),
            )
          : null,
      body: Row(
        children: [
          if (!isMobile)
            ValueListenableBuilder<bool>(
              valueListenable: AppState.sidebarCollapsed,
              builder: (context, collapsed, _) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: collapsed ? 72 : 280,
                  child: const SidebarWidget(isDrawer: false),
                );
              },
            ),
          Expanded(
            child: ChatAreaWidget(
              onOpenMenu: () {
                if (isMobile) {
                  _scaffoldKey.currentState?.openDrawer();
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// SIDEBAR COMPONENT
// ============================================================================

class SidebarWidget extends StatelessWidget {
  final bool isDrawer;

  const SidebarWidget({super.key, required this.isDrawer});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.sidebarCollapsed,
      builder: (context, collapsed, _) {
        final showFull = !collapsed || isDrawer;

        return Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.sidebarBackground, Color(0xFF0A0C12)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            border: Border(
              right: BorderSide(
                color: AppColors.borderStrong.withValues(alpha: 0.75),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.cyan.withValues(alpha: 0.03),
                blurRadius: 28,
                offset: const Offset(10, 0),
              ),
            ],
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16.0, vertical: 20.0),
                  child: Row(
                    mainAxisAlignment: showFull
                        ? MainAxisAlignment.spaceBetween
                        : MainAxisAlignment.center,
                    children: [
                      if (showFull)
                        const Expanded(
                          child: ShaderMask(
                            shaderCallback: _headerShader,
                            child: Text(
                              'OMNICORE AI',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      if (!isDrawer)
                        IconButton(
                          onPressed: () => AppState.sidebarCollapsed.value =
                              !AppState.sidebarCollapsed.value,
                          icon: Icon(
                            collapsed
                                ? Icons.chevron_right
                                : Icons.chevron_left,
                            color: AppColors.textSecondary,
                            size: 20,
                          ),
                          tooltip:
                              collapsed ? 'Expand Sidebar' : 'Collapse Sidebar',
                        ),
                    ],
                  ),
                ),

                // New Chat Button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: InkWell(
                    onTap: () {
                      AppState.createNewChat();
                      if (isDrawer) Navigator.pop(context);
                    },
                    borderRadius: BorderRadius.circular(12),
                    hoverColor: AppColors.cyan.withValues(alpha: 0.10),
                    splashColor: AppColors.purple.withValues(alpha: 0.12),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 14),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppColors.cyan.withValues(alpha: 0.10),
                            AppColors.purple.withValues(alpha: 0.06),
                          ],
                        ),
                        border: Border.all(
                          color: AppColors.cyan.withValues(alpha: 0.38),
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.cyan.withValues(alpha: 0.08),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: showFull
                            ? MainAxisAlignment.start
                            : MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color:
                                  AppColors.background.withValues(alpha: 0.42),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppColors.cyan.withValues(alpha: 0.24),
                              ),
                            ),
                            child: const Icon(Icons.add,
                                color: AppColors.cyan, size: 18),
                          ),
                          if (showFull) ...[
                            const SizedBox(width: 12),
                            const Text(
                              'New Chat',
                              style: TextStyle(
                                color: AppColors.cyan,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ]
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // History label
                if (showFull)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      child: Text(
                        'RECENT CONVERSATIONS',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textMuted,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                  ),

                // History List
                Expanded(
                  child: ValueListenableBuilder<List<ChatSession>>(
                    valueListenable: AppState.sessions,
                    builder: (context, sessionsList, _) {
                      return ValueListenableBuilder<String>(
                        valueListenable: AppState.selectedSessionId,
                        builder: (context, selectedId, _) {
                          return ListView.builder(
                            itemCount: sessionsList.length,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8.0),
                            itemBuilder: (context, index) {
                              final session = sessionsList[index];
                              final isSelected = session.id == selectedId;

                              if (!showFull) {
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4.0),
                                  child: IconButton(
                                    onPressed: () =>
                                        AppState.selectSession(session.id),
                                    icon: const Icon(Icons.chat_bubble_outline),
                                    color: isSelected
                                        ? AppColors.cyan
                                        : AppColors.textSecondary,
                                    tooltip: session.title,
                                  ),
                                );
                              }

                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2.0),
                                child: InkWell(
                                  onTap: () {
                                    AppState.selectSession(session.id);
                                    if (isDrawer) Navigator.pop(context);
                                  },
                                  borderRadius: BorderRadius.circular(8),
                                  hoverColor:
                                      AppColors.cyan.withValues(alpha: 0.06),
                                  splashColor:
                                      AppColors.purple.withValues(alpha: 0.10),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 160),
                                    curve: Curves.easeOutCubic,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10.0, vertical: 9.0),
                                    decoration: BoxDecoration(
                                      gradient: isSelected
                                          ? LinearGradient(
                                              colors: [
                                                AppColors.cyan
                                                    .withValues(alpha: 0.10),
                                                AppColors.surfaceHigh
                                                    .withValues(alpha: 0.62),
                                              ],
                                            )
                                          : null,
                                      color: isSelected
                                          ? null
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isSelected
                                            ? AppColors.cyan
                                                .withValues(alpha: 0.18)
                                            : Colors.transparent,
                                        width: 1,
                                      ),
                                      boxShadow: isSelected
                                          ? [
                                              BoxShadow(
                                                color: AppColors.cyan
                                                    .withValues(alpha: 0.06),
                                                blurRadius: 14,
                                                offset: const Offset(0, 8),
                                              ),
                                            ]
                                          : null,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.chat_bubble_outline,
                                          size: 16,
                                          color: isSelected
                                              ? AppColors.cyan
                                              : AppColors.textSecondary,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            session.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: isSelected
                                                  ? AppColors.textPrimary
                                                  : AppColors.textSecondary,
                                              fontWeight: isSelected
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                            ),
                                          ),
                                        ),
                                        // Delete Button
                                        IconButton(
                                          onPressed: () =>
                                              AppState.deleteSession(
                                                  session.id),
                                          icon: const Icon(Icons.delete_outline,
                                              size: 14),
                                          color: AppColors.textMuted,
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          splashRadius: 14,
                                          tooltip: 'Delete Chat',
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                ),

                // Settings, layout and auth panel
                Container(
                  padding: const EdgeInsets.all(12.0),
                  decoration: BoxDecoration(
                    color: AppColors.background.withValues(alpha: 0.35),
                    border: Border(
                      top: BorderSide(
                        color: AppColors.borderStrong.withValues(alpha: 0.7),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      ValueListenableBuilder<List<OmniMemory>>(
                        valueListenable: AppState.memories,
                        builder: (context, memories, _) {
                          return _buildMemorySnapshotTile(
                            context,
                            showFull,
                            memories,
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      ValueListenableBuilder<bool>(
                        valueListenable: AppState.compactMode,
                        builder: (context, compact, _) {
                          return _buildCompactModeTile(showFull, compact);
                        },
                      ),
                      const SizedBox(height: 10),
                      StreamBuilder<User?>(
                        stream: AuthService.authStateChanges(),
                        builder: (context, snapshot) {
                          final user = snapshot.data;

                          return AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) {
                              return FadeTransition(
                                opacity: animation,
                                child: SizeTransition(
                                  sizeFactor: animation,
                                  alignment: Alignment.topCenter,
                                  child: child,
                                ),
                              );
                            },
                            child: user == null
                                ? _buildLoggedOutAuth(context, showFull)
                                : _buildUserProfile(context, user, showFull),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCompactModeTile(bool showFull, bool compact) {
    final accent = compact ? AppColors.cyan : AppColors.textSecondary;

    return InkWell(
      onTap: () {
        if (!showFull) {
          AppState.compactMode.value = !AppState.compactMode.value;
        }
      },
      borderRadius: BorderRadius.circular(10),
      hoverColor: AppColors.cyan.withValues(alpha: 0.06),
      splashColor: AppColors.purple.withValues(alpha: 0.08),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        height: 46,
        padding: EdgeInsets.symmetric(horizontal: showFull ? 10 : 0),
        decoration: BoxDecoration(
          color: AppColors.surfaceSoft.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: compact
                ? AppColors.cyan.withValues(alpha: 0.24)
                : AppColors.border.withValues(alpha: 0.8),
          ),
        ),
        child: Row(
          mainAxisAlignment:
              showFull ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [
            Icon(Icons.view_headline, color: accent, size: 19),
            if (showFull) ...[
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Compact View',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Transform.scale(
                scale: 0.82,
                child: Switch(
                  value: compact,
                  onChanged: (val) => AppState.compactMode.value = val,
                  activeThumbColor: AppColors.cyan,
                  activeTrackColor: AppColors.cyan.withValues(alpha: 0.28),
                  inactiveThumbColor: AppColors.textMuted,
                  inactiveTrackColor: AppColors.border,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMemorySnapshotTile(
    BuildContext context,
    bool showFull,
    List<OmniMemory> memories,
  ) {
    final accent =
        memories.isNotEmpty ? AppColors.gold : AppColors.textSecondary;

    return InkWell(
      onTap: showFull ? () => _showMemoriesPanel(context) : null,
      borderRadius: BorderRadius.circular(10),
      hoverColor: AppColors.gold.withValues(alpha: 0.06),
      splashColor: AppColors.gold.withValues(alpha: 0.10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        constraints: const BoxConstraints(minHeight: 46),
        padding: EdgeInsets.symmetric(
          horizontal: showFull ? 10 : 0,
          vertical: showFull ? 10 : 0,
        ),
        decoration: BoxDecoration(
          color: AppColors.surfaceSoft.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: memories.isNotEmpty
                ? AppColors.gold.withValues(alpha: 0.24)
                : AppColors.border.withValues(alpha: 0.8),
          ),
        ),
        child: showFull
            ? Row(
                children: [
                  Icon(Icons.memory, color: accent, size: 19),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Memory Core',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${memories.length} saved',
                          style: TextStyle(
                            fontSize: 10,
                            color: accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    color: AppColors.textMuted,
                    size: 18,
                  ),
                ],
              )
            : Center(
                child: Icon(Icons.memory, color: accent, size: 19),
              ),
      ),
    );
  }

  void _showMemoriesPanel(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.cardBackground,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: ValueListenableBuilder<List<OmniMemory>>(
              valueListenable: AppState.memories,
              builder: (context, memories, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Saved Memories',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (memories.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'No memories saved yet.',
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: memories.length,
                          separatorBuilder: (_, __) => Divider(
                            color: AppColors.border.withValues(alpha: 0.7),
                            height: 1,
                          ),
                          itemBuilder: (context, index) {
                            final memory = memories[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                memory.pinned
                                    ? Icons.push_pin
                                    : Icons.memory_outlined,
                                color: memory.pinned
                                    ? AppColors.gold
                                    : AppColors.textSecondary,
                                size: 20,
                              ),
                              title: Text(
                                memory.text,
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 13,
                                  height: 1.35,
                                ),
                              ),
                              subtitle: Text(
                                memory.type.name,
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 10,
                                ),
                              ),
                              trailing: IconButton(
                                tooltip: 'Forget',
                                icon: const Icon(Icons.delete_outline),
                                color: AppColors.textMuted,
                                onPressed: () =>
                                    AppState.forgetMemory(memory.id),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoggedOutAuth(BuildContext context, bool showFull) {
    if (!showFull) {
      return Column(
        key: const ValueKey('auth-logged-out-compact'),
        children: [
          _compactAuthButton(
            icon: Icons.person_outline,
            accent: AppColors.purple,
            tooltip: 'Continue as Guest',
            onPressed: () => _signInAsGuest(context),
          ),
          const SizedBox(height: 8),
          _compactAuthButton(
            icon: Icons.person_add_alt_1,
            accent: AppColors.cyan,
            tooltip: 'Sign Up',
            onPressed: () =>
                _signInWithGoogle(context, initializeProfile: true),
          ),
          const SizedBox(height: 8),
          _compactAuthButton(
            icon: Icons.login,
            accent: AppColors.blue,
            tooltip: 'Log In',
            onPressed: () =>
                _signInWithGoogle(context, initializeProfile: false),
          ),
        ],
      );
    }

    return Container(
      key: const ValueKey('auth-logged-out'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.surfaceHigh.withValues(alpha: 0.78),
            AppColors.cardBackground.withValues(alpha: 0.58),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cyan.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
            color: AppColors.purple.withValues(alpha: 0.07),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.cyan,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.cyan.withValues(alpha: 0.45),
                      blurRadius: 10,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'ACCESS',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _authActionButton(
            label: 'Continue as Guest',
            icon: Icons.person_outline,
            accent: AppColors.purple,
            filled: true,
            onPressed: () => _signInAsGuest(context),
          ),
          const SizedBox(height: 8),
          _authActionButton(
            label: 'Sign Up',
            icon: Icons.person_add_alt_1,
            accent: AppColors.cyan,
            filled: true,
            onPressed: () =>
                _signInWithGoogle(context, initializeProfile: true),
          ),
          const SizedBox(height: 8),
          _authActionButton(
            label: 'Log In',
            icon: Icons.login,
            accent: AppColors.blue,
            onPressed: () =>
                _signInWithGoogle(context, initializeProfile: false),
          ),
        ],
      ),
    );
  }

  Widget _buildUserProfile(BuildContext context, User user, bool showFull) {
    final initials =
        (user.displayName != null && user.displayName!.trim().isNotEmpty)
            ? user.displayName!
                .trim()
                .split(' ')
                .map((e) => e[0])
                .take(2)
                .join()
                .toUpperCase()
            : 'OP';

    final avatar = Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient:
            const LinearGradient(colors: [AppColors.cyan, AppColors.purple]),
        boxShadow: [
          BoxShadow(
            color: AppColors.cyan.withValues(alpha: 0.18),
            blurRadius: 14,
          ),
        ],
      ),
      child: CircleAvatar(
        radius: showFull ? 18 : 17,
        backgroundColor: AppColors.surfaceSoft,
        backgroundImage:
            user.photoURL != null ? NetworkImage(user.photoURL!) : null,
        child: user.photoURL == null
            ? Text(
                initials,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.cyan,
                  fontWeight: FontWeight.w900,
                ),
              )
            : null,
      ),
    );

    if (!showFull) {
      return Tooltip(
        key: const ValueKey('auth-logged-in-compact'),
        message: user.displayName ?? user.email ?? 'Account',
        child: InkWell(
          onTap: () => showOmniSettingsMenu(context),
          borderRadius: BorderRadius.circular(12),
          hoverColor: AppColors.cyan.withValues(alpha: 0.08),
          child: SizedBox(height: 46, child: Center(child: avatar)),
        ),
      );
    }

    return Container(
      key: const ValueKey('auth-logged-in'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceSoft.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cyan.withValues(alpha: 0.16)),
        boxShadow: [
          BoxShadow(
            color: AppColors.cyan.withValues(alpha: 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.displayName ?? 'Omni Pilot',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  user.email ??
                      (user.isAnonymous ? 'Guest User' : 'Authenticated'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 17),
            color: AppColors.textMuted,
            hoverColor: AppColors.cyan.withValues(alpha: 0.10),
            tooltip: 'Settings',
            onPressed: () => showOmniSettingsMenu(context),
          ),
          IconButton(
            icon: const Icon(Icons.logout, size: 17),
            color: AppColors.textMuted,
            hoverColor: AppColors.stop.withValues(alpha: 0.10),
            tooltip: 'Sign Out',
            onPressed: () => _signOut(context),
          ),
        ],
      ),
    );
  }

  Widget _authActionButton({
    required String label,
    required IconData icon,
    required Color accent,
    required Future<void> Function() onPressed,
    bool filled = false,
  }) {
    return SizedBox(
      height: 40,
      child: ElevatedButton.icon(
        onPressed: () => onPressed(),
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          elevation: filled ? 5 : 0,
          shadowColor: accent.withValues(alpha: 0.18),
          backgroundColor: filled
              ? accent.withValues(alpha: 0.17)
              : AppColors.background.withValues(alpha: 0.20),
          foregroundColor: filled ? AppColors.textPrimary : accent,
          overlayColor: accent.withValues(alpha: 0.12),
          side: BorderSide(
            color: accent.withValues(alpha: filled ? 0.42 : 0.28),
          ),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _compactAuthButton({
    required IconData icon,
    required Color accent,
    required String tooltip,
    required Future<void> Function() onPressed,
  }) {
    return IconButton(
      onPressed: () => onPressed(),
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      color: accent,
      style: IconButton.styleFrom(
        fixedSize: const Size(44, 38),
        backgroundColor: accent.withValues(alpha: 0.10),
        hoverColor: accent.withValues(alpha: 0.16),
        highlightColor: accent.withValues(alpha: 0.20),
        side: BorderSide(color: accent.withValues(alpha: 0.25)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _signInAsGuest(BuildContext context) async {
    try {
      AppState.isLoggingInActive = true;
      final guestUser = await AuthService.signInAnonymously();
      if (guestUser != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Signed in as Guest.'),
            backgroundColor: AppColors.purple,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Guest Login failed: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      AppState.isLoggingInActive = false;
    }
  }

  Future<void> _signInWithGoogle(
    BuildContext context, {
    required bool initializeProfile,
  }) async {
    try {
      AppState.isLoggingInActive = true;
      final signedInUser = await AuthService.signInWithGoogle();
      if (signedInUser != null) {
        if (initializeProfile) {
          final isFirst = await _safeHydrationValue<bool>(
            label: 'Google profile lookup failed.',
            fallback: false,
            task: () => FirestoreService.isFirstTimeUser(signedInUser.uid),
          );
          if (isFirst) {
            await _safeHydrationTask(
              label: 'Google profile creation failed.',
              task: () => FirestoreService.createUserProfile(signedInUser),
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Welcome to OmniCore AI, ${signedInUser.displayName}! Your account has been initialized.',
                  ),
                  backgroundColor: AppColors.cyan,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          } else {
            await _safeHydrationTask(
              label: 'Google profile update failed.',
              task: () => FirestoreService.updateUserLastLogin(
                signedInUser.uid,
              ),
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Welcome back, ${signedInUser.displayName}!'),
                  backgroundColor: AppColors.blue,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          }
        } else {
          await _safeHydrationTask(
            label: 'Google profile update failed.',
            task: () => FirestoreService.updateUserLastLogin(signedInUser.uid),
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Welcome back, ${signedInUser.displayName}!'),
                backgroundColor: AppColors.blue,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Google Sign-In failed: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      AppState.isLoggingInActive = false;
    }
  }

  Future<void> _signOut(BuildContext context) async {
    await AuthService.signOut();
    AppState.selectSession('default');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Successfully signed out.'),
          backgroundColor: AppColors.border,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  static Shader _headerShader(Rect bounds) {
    return const LinearGradient(
      colors: [AppColors.cyan, AppColors.purple],
    ).createShader(bounds);
  }
}

// ============================================================================
// CHAT AREA COMPONENT
// ============================================================================

class ChatAreaWidget extends StatefulWidget {
  final VoidCallback onOpenMenu;

  const ChatAreaWidget({super.key, required this.onOpenMenu});

  @override
  State<ChatAreaWidget> createState() => _ChatAreaWidgetState();
}

class _ChatAreaWidgetState extends State<ChatAreaWidget> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  Timer? _streamUpdateTimer;
  StreamSubscription<String>? _generationSubscription;
  AIGeneration? _activeGeneration;
  int _generationId = 0;
  StringBuffer? _activeResponseBuffer;
  bool _activeResponseBubbleCreated = false;
  bool _showModeSelector = false; // Tracks visibility of mode selector

  @override
  void dispose() {
    _generationId++;
    _streamUpdateTimer?.cancel();
    _generationSubscription?.cancel();
    _activeGeneration?.cancel();
    if (AppState.isTyping.value) {
      AppState.isTyping.value = false;
    }
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    }
  }

  // Handle message sending and stream provider chunks into the active bubble.
  void _submitMessage() {
    final text = _inputController.text.trim();
    if (text.isEmpty || AppState.isTyping.value) return;

    _inputController.clear();
    _beginGeneration(
      text: text,
      mode: AppState.selectedMode.value,
      addUserMessage: true,
    );
  }

  void _beginGeneration({
    required String text,
    required String mode,
    required bool addUserMessage,
  }) {
    _generationId++;
    final generationId = _generationId;
    _streamUpdateTimer?.cancel();
    _generationSubscription?.cancel();
    _activeGeneration?.cancel();
    _activeResponseBuffer = null;
    _activeResponseBubbleCreated = false;

    if (addUserMessage) {
      AppState.addMessage(text, true, customMode: mode);
      unawaited(AppState.captureMemoryCommand(text));
    }
    AppState.isTyping.value = true;

    // Focus back on desktop
    _inputFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    final generation = AIRouter.streamMessage(
      text,
      mode,
      memories: AppState.relevantMemoriesFor(text),
      retrievalPreference: AppState.effectiveRetrievalPreference,
    );
    _activeGeneration = generation;
    _activeResponseBuffer = StringBuffer();

    _generationSubscription = generation.stream.listen(
      (chunk) => _handleAIChunk(chunk, mode, generationId),
      onError: (error) => _handleAIError(error, mode, generationId),
      onDone: () => _handleAIDone(mode, generationId),
      cancelOnError: true,
    );
  }

  bool _isActiveGeneration(int generationId) {
    return AppState.isTyping.value && generationId == _generationId;
  }

  void _finishGeneration(int generationId) {
    if (generationId != _generationId) return;
    _streamUpdateTimer?.cancel();
    _streamUpdateTimer = null;
    _generationSubscription = null;
    _activeGeneration = null;
    _activeResponseBuffer = null;
    _activeResponseBubbleCreated = false;
    AppState.isTyping.value = false;
    AppState.persistActiveSession();
  }

  void _stopGeneration() {
    if (!AppState.isTyping.value) return;

    _generationId++;
    _streamUpdateTimer?.cancel();
    _streamUpdateTimer = null;
    _generationSubscription?.cancel();
    _generationSubscription = null;
    _activeGeneration?.cancel();
    _activeGeneration = null;

    final partialText = _activeResponseBuffer?.toString().trimRight() ?? '';
    if (_activeResponseBubbleCreated && partialText.isEmpty) {
      AppState.updateLastAIMessage('Generation stopped.');
    } else if (_activeResponseBubbleCreated && partialText.isNotEmpty) {
      AppState.updateLastAIMessage(partialText);
    }

    _activeResponseBuffer = null;
    _activeResponseBubbleCreated = false;
    AppState.isTyping.value = false;
    RuntimeDiagnostics.streamingCancelled();
    AppState.persistActiveSession();
    _inputFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _handleAIChunk(String chunk, String mode, int generationId) {
    if (!_isActiveGeneration(generationId)) return;
    dev.log(
      'UI update callback fired: generationId=$generationId chunkSize=${chunk.length} bubbleCreated=$_activeResponseBubbleCreated',
    );

    if (!_activeResponseBubbleCreated) {
      _activeResponseBubbleCreated = true;
      AppState.addMessage(
        '',
        false,
        customMode: mode,
        persistToCloud: false,
      );
      dev.log('UI message state updated: assistant bubble created');
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }

    _activeResponseBuffer?.write(chunk);
    dev.log(
      'UI message state updated: bufferLength=${_activeResponseBuffer?.length ?? 0}',
    );
    _scheduleStreamUpdate(generationId);
  }

  void _scheduleStreamUpdate(int generationId) {
    if (_streamUpdateTimer?.isActive ?? false) return;

    _streamUpdateTimer = Timer(const Duration(milliseconds: 24), () {
      _streamUpdateTimer = null;
      if (!_isActiveGeneration(generationId) || !_activeResponseBubbleCreated) {
        return;
      }

      final text = _activeResponseBuffer?.toString().trimRight() ?? '';
      AppState.updateLastAIMessage(text);
      dev.log(
        'UI message state updated: persisted assistant text length=${text.length}',
      );
      _jumpToBottomIfClose();
    });
  }

  void _handleAIError(Object error, String mode, int generationId) {
    if (!_isActiveGeneration(generationId)) return;

    final message = error is AIServiceException
        ? error.message
        : 'Sorry, the AI service is unavailable right now. Please try again.';
    final partialText = _activeResponseBuffer?.toString().trimRight() ?? '';

    if (_activeResponseBubbleCreated && partialText.isNotEmpty) {
      AppState.updateLastAIMessage('$partialText\n\n$message');
    } else if (_activeResponseBubbleCreated) {
      AppState.updateLastAIMessage(message);
    } else {
      AppState.addMessage(message, false, customMode: mode);
    }

    _finishGeneration(generationId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _copyMessage(Message message) {
    Clipboard.setData(ClipboardData(text: message.text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message.isUser ? 'Prompt copied.' : 'Response copied.'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _editMessage(Message message) async {
    if (AppState.isTyping.value) return;
    final controller = TextEditingController(text: message.text);
    final updatedText = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.cardBackground,
          title: Text(
            message.isUser ? 'Edit Prompt' : 'Edit Message',
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          content: TextField(
            controller: controller,
            maxLines: 8,
            minLines: 3,
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.surfaceSoft,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.border),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    if (updatedText == null || updatedText.isEmpty) return;
    AppState.updateMessageText(message.id, updatedText);
    AppState.persistActiveSession();
  }

  void _retryFromUserMessage(Message message) {
    if (AppState.isTyping.value) return;
    AppState.truncateSessionAfterMessage(message.id);
    _beginGeneration(
      text: message.text,
      mode: message.mode,
      addUserMessage: false,
    );
  }

  void _regenerateFromAIMessage(Message message) {
    if (AppState.isTyping.value) return;
    final messages = AppState.activeSession.value.messages;
    final aiIndex = messages.indexWhere((item) => item.id == message.id);
    if (aiIndex <= 0) return;

    for (var i = aiIndex - 1; i >= 0; i--) {
      if (messages[i].isUser) {
        _retryFromUserMessage(messages[i]);
        return;
      }
    }
  }

  void _handleAIDone(String mode, int generationId) {
    if (!_isActiveGeneration(generationId)) return;
    _streamUpdateTimer?.cancel();
    _streamUpdateTimer = null;

    final text = _activeResponseBuffer?.toString().trimRight() ?? '';
    if (_activeResponseBubbleCreated) {
      AppState.updateLastAIMessage(text.isEmpty
          ? 'Sorry, the AI response was empty. Please try again.'
          : text);
      dev.log(
        'UI message state updated: done persisted text length=${text.length}',
      );
    } else {
      AppState.addMessage(
        'Sorry, the AI response was empty. Please try again.',
        false,
        customMode: mode,
      );
      dev.log('UI message state updated: done fallback bubble created');
    }

    _finishGeneration(generationId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _jumpToBottomIfClose() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 150) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  Widget _inputIconButton({
    Key? key,
    required IconData icon,
    required Color accent,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: key,
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      color: accent,
      style: IconButton.styleFrom(
        fixedSize: const Size(44, 44),
        backgroundColor: accent.withValues(alpha: 0.10),
        hoverColor: accent.withValues(alpha: 0.16),
        highlightColor: accent.withValues(alpha: 0.20),
        side: BorderSide(color: accent.withValues(alpha: 0.24)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  Widget _buildRetrievalActionButton() {
    return ValueListenableBuilder<RetrievalPreference>(
      valueListenable: AppState.retrievalPreference,
      builder: (context, preference, _) {
        final active = preference == RetrievalPreference.force ||
            RuntimeDiagnostics.forceRetrievalMode.value;
        final disabled = preference == RetrievalPreference.disabled ||
            RuntimeDiagnostics.forceGroqOnlyMode.value;
        final accent = active
            ? AppColors.gold
            : disabled
                ? AppColors.textMuted
                : AppColors.cyan;

        return PopupMenuButton<String>(
          tooltip: 'Attach retrieval context',
          color: AppColors.cardBackground,
          elevation: 10,
          offset: const Offset(0, -8),
          onSelected: _handleRetrievalAction,
          itemBuilder: (context) => [
            _retrievalMenuItem(
              value: 'web_search',
              icon: Icons.travel_explore,
              label: 'Web Search',
              subtitle: 'Force live search for next prompt',
            ),
            _retrievalMenuItem(
              value: 'url_retrieval',
              icon: Icons.link,
              label: 'URL Retrieval',
              subtitle: 'Use when the prompt includes a link',
            ),
            _retrievalMenuItem(
              value: 'attach_context',
              icon: Icons.note_add_outlined,
              label: 'Attach Context',
              subtitle: 'Add manual context before sending',
            ),
            _retrievalMenuItem(
              value: 'toggle_auto',
              icon: Icons.radar,
              label: 'Retrieval Auto',
              subtitle: 'Let the router decide',
            ),
            _retrievalMenuItem(
              value: 'toggle_off',
              icon: Icons.search_off,
              label: 'Retrieval Off',
              subtitle: 'Groq answers without live search',
            ),
            _retrievalMenuItem(
              value: 'upload_file',
              icon: Icons.upload_file,
              label: 'Upload File',
              subtitle: 'Future tool placeholder',
            ),
          ],
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: active ? 0.16 : 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accent.withValues(alpha: 0.28)),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.18),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  active
                      ? Icons.travel_explore
                      : disabled
                          ? Icons.search_off
                          : Icons.add_link,
                  color: accent,
                  size: 20,
                ),
                if (active)
                  Positioned(
                    top: 9,
                    right: 9,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: AppColors.gold,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.gold.withValues(alpha: 0.55),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  PopupMenuItem<String> _retrievalMenuItem({
    required String value,
    required IconData icon,
    required String label,
    required String subtitle,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: AppColors.cyan, size: 19),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _handleRetrievalAction(String action) {
    switch (action) {
      case 'web_search':
      case 'url_retrieval':
        AppState.retrievalPreference.value = RetrievalPreference.force;
        _showInputHint('Live search will be attached to the next prompt.');
        _inputFocusNode.requestFocus();
        break;
      case 'attach_context':
        AppState.retrievalPreference.value = RetrievalPreference.force;
        if (_inputController.text.trim().isEmpty) {
          _inputController.text = 'Use live context for: ';
          _inputController.selection = TextSelection.fromPosition(
            TextPosition(offset: _inputController.text.length),
          );
        }
        _inputFocusNode.requestFocus();
        break;
      case 'toggle_auto':
        AppState.retrievalPreference.value = RetrievalPreference.auto;
        _showInputHint('Retrieval is back on auto.');
        break;
      case 'toggle_off':
        AppState.retrievalPreference.value = RetrievalPreference.disabled;
        _showInputHint('Retrieval disabled for upcoming prompts.');
        break;
      case 'upload_file':
        _showInputHint('File analysis hooks are ready for a future tool.');
        break;
    }
  }

  void _showInputHint(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildRetrievalStatusStrip() {
    return ValueListenableBuilder<RetrievalPreference>(
      valueListenable: AppState.retrievalPreference,
      builder: (context, preference, _) {
        return ValueListenableBuilder<RuntimeSnapshot>(
          valueListenable: RuntimeDiagnostics.snapshot,
          builder: (context, snapshot, _) {
            final active = AppState.isTyping.value &&
                (snapshot.retrievalStatus.contains('Searching') ||
                    snapshot.retrievalStatus.contains('Injecting') ||
                    snapshot.retrievalStatus.contains('Retrieved'));
            final visible = preference != RetrievalPreference.auto ||
                active ||
                snapshot.lastError != null;
            if (!visible) {
              return const SizedBox.shrink(
                  key: ValueKey('retrieval-strip-off'));
            }

            final failed = snapshot.lastError != null &&
                snapshot.retrievalStatus.contains('continuing');
            final accent = failed
                ? AppColors.gold
                : preference == RetrievalPreference.disabled
                    ? AppColors.textMuted
                    : AppColors.cyan;
            final text = failed
                ? 'Retrieval unavailable; Groq will answer normally'
                : active
                    ? _friendlyRetrievalStage(snapshot.retrievalStatus)
                    : 'Retrieval ${preference.label}';

            return Align(
              key: const ValueKey('retrieval-strip-on'),
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: accent.withValues(alpha: 0.24)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: active
                          ? CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: accent,
                            )
                          : Icon(
                              failed ? Icons.info_outline : Icons.radar,
                              color: accent,
                              size: 12,
                            ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        text,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accent,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _friendlyRetrievalStage(String status) {
    if (status.contains('Searching')) return 'Searching live web...';
    if (status.contains('Injecting')) return 'Injecting retrieved context...';
    if (status.contains('Retrieved')) return 'Grounding response...';
    return status;
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isMobile = screenWidth < 768;

    return Stack(
      children: [
        Container(
          color: AppColors.background,
          child: Column(
            children: [
              // Navigation / Top Bar
              Container(
                height: 64,
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                decoration: BoxDecoration(
                  color: AppColors.background.withValues(alpha: 0.96),
                  border: Border(
                    bottom: BorderSide(
                      color: AppColors.borderStrong.withValues(alpha: 0.72),
                      width: 1,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    if (isMobile)
                      IconButton(
                        onPressed: widget.onOpenMenu,
                        icon: const Icon(Icons.menu,
                            color: AppColors.textPrimary),
                      ),
                    const SizedBox(width: 8),
                    ValueListenableBuilder<ChatSession>(
                      valueListenable: AppState.activeSession,
                      builder: (context, activeSession, _) {
                        return Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                activeSession.title,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const Text(
                                'OmniCore Core v1.0.0',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    IconButton(
                      onPressed: () => showOmniSettingsMenu(context),
                      icon: const Icon(Icons.settings_outlined, size: 20),
                      color: AppColors.textSecondary,
                      tooltip: 'Settings',
                    ),
                    IconButton(
                      onPressed: () {
                        // Empty chat helper
                        AppState.sessions.value.firstWhere(
                          (s) => s.id == AppState.selectedSessionId.value,
                        );
                        // Reset session
                        AppState.selectSession(
                            AppState.selectedSessionId.value);
                      },
                      icon: const Icon(Icons.refresh, size: 20),
                      color: AppColors.textSecondary,
                      tooltip: 'Reset Session',
                    ),
                    IconButton(
                      onPressed: () {
                        final session = AppState.activeSession.value;
                        final transcript = session.messages
                            .map((message) =>
                                '${message.isUser ? "User" : "OmniCore"} (${message.mode}): ${message.text}')
                            .join('\n\n');
                        Clipboard.setData(ClipboardData(text: transcript));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Conversation copied to clipboard.'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      icon: const Icon(Icons.share, size: 20),
                      color: AppColors.textSecondary,
                      tooltip: 'Share chat',
                    ),
                  ],
                ),
              ),

              // Main Chat content
              Expanded(
                child: ValueListenableBuilder<ChatSession>(
                  valueListenable: AppState.activeSession,
                  builder: (context, session, _) {
                    if (session.messages.isEmpty) {
                      return WelcomePanel(
                        onSuggestionTap: (prompt) {
                          _inputController.text = prompt;
                          _submitMessage();
                        },
                      );
                    }

                    return ValueListenableBuilder<bool>(
                      valueListenable: AppState.compactMode,
                      builder: (context, compact, _) {
                        return ValueListenableBuilder<bool>(
                          valueListenable: AppState.isTyping,
                          builder: (context, typing, _) {
                            final count = session.messages.length +
                                (typing && !_activeResponseBubbleCreated
                                    ? 1
                                    : 0);

                            return Scrollbar(
                              controller: _scrollController,
                              child: ListView.builder(
                                controller: _scrollController,
                                itemCount: count,
                                padding: EdgeInsets.symmetric(
                                  horizontal: isMobile ? 12.0 : 40.0,
                                  vertical: 24.0,
                                ),
                                itemBuilder: (context, index) {
                                  if (index == session.messages.length) {
                                    return const TypingIndicatorWidget();
                                  }

                                  final msg = session.messages[index];
                                  return MessageBubble(
                                    key: ValueKey(msg.id),
                                    message: msg,
                                    compact: compact,
                                    onCopy: () => _copyMessage(msg),
                                    onEdit: () => _editMessage(msg),
                                    onRetry: msg.isUser
                                        ? () => _retryFromUserMessage(msg)
                                        : null,
                                    onRegenerate: msg.isUser
                                        ? null
                                        : () => _regenerateFromAIMessage(msg),
                                  );
                                },
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),

              // Bottom Input Panel
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 12.0 : 40.0,
                  vertical: 14.0,
                ),
                decoration: BoxDecoration(
                  color: AppColors.background.withValues(alpha: 0.96),
                  border: Border(
                    top: BorderSide(
                      color: AppColors.borderStrong.withValues(alpha: 0.72),
                      width: 1,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.cyan.withValues(alpha: 0.035),
                      blurRadius: 24,
                      offset: const Offset(0, -10),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _buildRetrievalStatusStrip(),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _showModeSelector
                          ? const Padding(
                              key: ValueKey('mode-selector-open'),
                              padding: EdgeInsets.only(bottom: 12.0),
                              child: ModeSelectorWidget(),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('mode-selector-closed'),
                            ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppColors.surfaceSoft.withValues(alpha: 0.94),
                            AppColors.cardBackground.withValues(alpha: 0.72),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppColors.cyan.withValues(alpha: 0.13),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.purple.withValues(alpha: 0.06),
                            blurRadius: 22,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          _buildRetrievalActionButton(),
                          const SizedBox(width: 8),
                          _inputIconButton(
                            icon: _showModeSelector ? Icons.close : Icons.add,
                            accent: _showModeSelector
                                ? AppColors.purple
                                : AppColors.cyan,
                            tooltip: 'Select Mode',
                            onPressed: () {
                              setState(() {
                                _showModeSelector = !_showModeSelector;
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _inputController,
                              focusNode: _inputFocusNode,
                              maxLines: null,
                              minLines: 1,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 14.5,
                                height: 1.35,
                              ),
                              decoration: const InputDecoration(
                                hintText: 'Type a message...',
                                hintStyle: TextStyle(
                                  color: AppColors.textMuted,
                                  fontWeight: FontWeight.w500,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8.0,
                                  vertical: 12.0,
                                ),
                              ),
                              onSubmitted: (_) => _submitMessage(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ValueListenableBuilder<bool>(
                            valueListenable: AppState.isTyping,
                            builder: (context, typing, _) {
                              return AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, animation) {
                                  return ScaleTransition(
                                    scale: animation,
                                    child: FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    ),
                                  );
                                },
                                child: _inputIconButton(
                                  key: ValueKey(typing ? 'stop' : 'send'),
                                  icon: typing
                                      ? Icons.stop_rounded
                                      : Icons.send_rounded,
                                  accent:
                                      typing ? AppColors.stop : AppColors.cyan,
                                  tooltip: typing ? 'Stop' : 'Send',
                                  onPressed:
                                      typing ? _stopGeneration : _submitMessage,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: RuntimeDiagnostics.debugOverlayEnabled,
          builder: (context, enabled, _) {
            if (!enabled ||
                !AppState.isDeveloperUser(AuthService.currentUser)) {
              return const SizedBox.shrink();
            }
            return const Positioned(
              right: 18,
              top: 76,
              child: _DebugOverlay(),
            );
          },
        ),
      ],
    );
  }
}

class _DebugOverlay extends StatelessWidget {
  const _DebugOverlay();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RuntimeSnapshot>(
      valueListenable: RuntimeDiagnostics.snapshot,
      builder: (context, snapshot, _) {
        return IgnorePointer(
          child: Container(
            width: 260,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background.withValues(alpha: 0.86),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.cyan.withValues(alpha: 0.22)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.26),
                  blurRadius: 20,
                ),
              ],
            ),
            child: DefaultTextStyle(
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 10.5,
                height: 1.35,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'DEBUG OVERLAY',
                    style: TextStyle(
                      color: AppColors.cyan,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('Stream: ${snapshot.streamState}'),
                  Text('Retrieval: ${snapshot.retrievalStatus}'),
                  Text('Router: ${snapshot.routerDecision}'),
                  Text('Chunks: ${snapshot.chunkCount}'),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ============================================================================
// WELCOME PANEL COMPONENT
// ============================================================================

class WelcomePanel extends StatelessWidget {
  final Function(String) onSuggestionTap;

  const WelcomePanel({super.key, required this.onSuggestionTap});

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isMobile = screenWidth < 768;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 40.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Cyber Orb Logo
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [AppColors.cyan, AppColors.purple],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.cyan.withValues(alpha: 0.3),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.bolt,
                color: Colors.white,
                size: 40,
              ),
            ),
            const SizedBox(height: 24),

            const Text(
              'OMNICORE INTELLIGENCE',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 2.0,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Select an optimization core or write a command below to begin.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 48),

            // Prompt Cards
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: GridView.count(
                crossAxisCount: isMobile ? 1 : 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: isMobile ? 3.5 : 2.5,
                children: [
                  _SuggestionCard(
                    icon: Icons.code,
                    title: 'Optimize Rebuilds',
                    description:
                        'Analyze a Dart performance bottleneck and fix build lag.',
                    onTap: () => onSuggestionTap(
                        'Analyze a Dart performance bottleneck'),
                  ),
                  _SuggestionCard(
                    icon: Icons.restaurant,
                    title: 'Kitchen Analogy',
                    description:
                        'Explain neural networks using a kitchen recipe metaphor.',
                    onTap: () => onSuggestionTap(
                        'Explain neural networks using a kitchen analogy'),
                  ),
                  _SuggestionCard(
                    icon: Icons.email_outlined,
                    title: 'Extension Request',
                    description:
                        'Draft a polite email to request a project deadline extension.',
                    onTap: () => onSuggestionTap(
                        'Draft a polite email to request a deadline extension'),
                  ),
                  _SuggestionCard(
                    icon: Icons.schedule,
                    title: 'Solve Scheduling',
                    description:
                        'Formulate an Integer Linear Programming scheduling solver.',
                    onTap: () => onSuggestionTap(
                        'Solve a scheduling optimization problem'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _SuggestionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      hoverColor: Colors.white.withValues(alpha: 0.02),
      child: Container(
        padding: const EdgeInsets.all(16.0),
        decoration: BoxDecoration(
          color: AppColors.sidebarBackground.withValues(alpha: 0.5),
          border: Border.all(color: AppColors.border, width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: AppColors.cyan, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Text(
                      description,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        height: 1.3,
                      ),
                      overflow: TextOverflow.fade,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// MODE SELECTOR WIDGET
// ============================================================================

class ModeSelectorWidget extends StatelessWidget {
  const ModeSelectorWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppState.selectedMode,
      builder: (context, activeMode, _) {
        return Container(
          padding: const EdgeInsets.all(5.0),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.surfaceSoft.withValues(alpha: 0.94),
                AppColors.cardBackground.withValues(alpha: 0.72),
              ],
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: AppColors.cyan.withValues(alpha: 0.12)),
            boxShadow: [
              BoxShadow(
                color: AppColors.cyan.withValues(alpha: 0.06),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ModeButton(mode: 'Fast', activeMode: activeMode),
                _ModeButton(mode: 'Smart', activeMode: activeMode),
                _ModeButton(mode: 'Code', activeMode: activeMode),
                _ModeButton(mode: 'Creative', activeMode: activeMode),
                _ModeButton(mode: 'Auto', activeMode: activeMode),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String mode;
  final String activeMode;

  const _ModeButton({
    required this.mode,
    required this.activeMode,
  });

  @override
  Widget build(BuildContext context) {
    final bool isSelected = mode == activeMode;
    final Color accentColor = AppColors.getModeColor(mode);

    return InkWell(
      onTap: () => AppState.selectedMode.value = mode,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: isSelected
              ? accentColor.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? accentColor.withValues(alpha: 0.48)
                : Colors.transparent,
            width: 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.10),
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? accentColor : AppColors.textMuted,
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: accentColor.withValues(alpha: 0.55),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              mode,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? Colors.white : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// MESSAGE BUBBLE & PARSING WORKER
// ============================================================================

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool compact;
  final VoidCallback? onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onRetry;
  final VoidCallback? onRegenerate;

  const MessageBubble({
    required this.message,
    required this.compact,
    this.onCopy,
    this.onEdit,
    this.onRetry,
    this.onRegenerate,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final Color modeColor = AppColors.getModeColor(message.mode);

    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 8.0 : 20.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          // AI Icon Avatar
          if (!message.isUser) ...[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    modeColor.withValues(alpha: 0.22),
                    AppColors.surfaceSoft,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(
                  color: modeColor.withValues(alpha: 0.55),
                  width: 1.4,
                ),
                boxShadow: [
                  BoxShadow(
                    color: modeColor.withValues(alpha: 0.12),
                    blurRadius: 14,
                  ),
                ],
              ),
              child: Icon(
                _getModeIcon(message.mode),
                size: 14,
                color: modeColor,
              ),
            ),
            const SizedBox(width: 12),
          ],

          // Bubble Box
          Expanded(
            child: Container(
              alignment:
                  message.isUser ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 850),
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 12.0 : 18.0,
                  vertical: compact ? 10.0 : 15.0,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: message.isUser
                        ? [
                            AppColors.userBubble,
                            const Color(0xFF242844),
                          ]
                        : [
                            AppColors.aiBubble,
                            const Color(0xFF151A2C),
                          ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(message.isUser ? 18 : 6),
                    bottomRight: Radius.circular(message.isUser ? 6 : 18),
                  ),
                  border: Border.all(
                    color: message.isUser
                        ? AppColors.cyan.withValues(alpha: 0.10)
                        : modeColor.withValues(alpha: 0.16),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: message.isUser
                          ? AppColors.blue.withValues(alpha: 0.06)
                          : modeColor.withValues(alpha: 0.08),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${message.isUser ? "YOU" : "OMNICORE"} - ${message.mode.toUpperCase()}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: message.isUser
                                ? AppColors.cyan.withValues(alpha: 0.78)
                                : modeColor,
                            letterSpacing: 0.5,
                          ),
                        ),
                        _MessageActionStrip(
                          isUser: message.isUser,
                          onCopy: onCopy,
                          onEdit: onEdit,
                          onRetry: onRetry,
                          onRegenerate: onRegenerate,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Text Content Block
                    ..._parseMessageContent(message.text, context),
                    if (message.isUser) ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          _formatTime(message.timestamp),
                          style: const TextStyle(
                            fontSize: 9,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // User Avatar Spacer
          if (message.isUser) ...[
            const SizedBox(width: 12),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.cyan.withValues(alpha: 0.10),
                border: Border.all(
                  color: AppColors.cyan.withValues(alpha: 0.32),
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.cyan.withValues(alpha: 0.09),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: const Icon(Icons.person, color: AppColors.cyan, size: 14),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getModeIcon(String mode) {
    switch (mode) {
      case 'Fast':
        return Icons.flash_on;
      case 'Code':
        return Icons.code;
      case 'Creative':
        return Icons.palette;
      case 'Auto':
        return Icons.auto_awesome;
      case 'Smart':
      default:
        return Icons.psychology;
    }
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  // Fast Markdown parser (Splits code blocks, then processes inline formatting)
  List<Widget> _parseMessageContent(String text, BuildContext context) {
    if (text.isEmpty) {
      return [
        const Text(
          'Thinking...',
          style: TextStyle(
              color: AppColors.textMuted, fontStyle: FontStyle.italic),
        )
      ];
    }

    final List<Widget> widgets = [];
    final List<String> parts = text.split('```');

    for (int i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isEmpty) continue;

      if (i % 2 == 1) {
        // Code Segment
        final lines = part.trim().split('\n');
        String lang = 'code';
        String codeBody = part;

        if (lines.isNotEmpty &&
            lines.first.trim().isNotEmpty &&
            lines.first.length < 15 &&
            !lines.first.contains(' ')) {
          lang = lines.first.trim();
          codeBody = lines.sublist(1).join('\n');
        }

        widgets.add(CodeBlockWidget(code: codeBody, language: lang));
      } else {
        // Plain text + Inline formatting (Bold, code)
        widgets.add(_MarkdownTextWidget(text: part));
      }
    }

    return widgets;
  }
}

class _MessageActionStrip extends StatelessWidget {
  const _MessageActionStrip({
    required this.isUser,
    this.onCopy,
    this.onEdit,
    this.onRetry,
    this.onRegenerate,
  });

  final bool isUser;
  final VoidCallback? onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onRetry;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _miniAction(icon: Icons.copy, tooltip: 'Copy', onPressed: onCopy),
        if (isUser)
          _miniAction(
            icon: Icons.edit_outlined,
            tooltip: 'Edit',
            onPressed: onEdit,
          ),
        if (isUser)
          _miniAction(
            icon: Icons.replay,
            tooltip: 'Retry',
            onPressed: onRetry,
          ),
        if (!isUser)
          _miniAction(
            icon: Icons.refresh,
            tooltip: 'Regenerate',
            onPressed: onRegenerate,
          ),
      ],
    );
  }

  Widget _miniAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 14),
      color: AppColors.textMuted,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      style: IconButton.styleFrom(
        hoverColor: AppColors.cyan.withValues(alpha: 0.08),
      ),
    );
  }
}

// ============================================================================
// HIGHLIGHTED CODE BLOCK WIDGET
// ============================================================================

class CodeBlockWidget extends StatelessWidget {
  final String code;
  final String language;

  const CodeBlockWidget({
    required this.code,
    required this.language,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final valueNotifier =
        ValueNotifier<bool>(false); // Tracks if copy completed

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12.0),
      decoration: BoxDecoration(
        color: const Color(0xFF07080D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Bar
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            decoration: const BoxDecoration(
              color: Color(0xFF0F1118),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  language.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textSecondary,
                    letterSpacing: 1.0,
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: valueNotifier,
                  builder: (context, copied, _) {
                    return InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: code));
                        valueNotifier.value = true;
                        Timer(const Duration(seconds: 2), () {
                          valueNotifier.value = false;
                        });
                      },
                      child: Row(
                        children: [
                          Icon(
                            copied ? Icons.check : Icons.copy,
                            size: 13,
                            color: copied
                                ? AppColors.cyan
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            copied ? 'COPIED' : 'COPY CODE',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: copied
                                  ? AppColors.cyan
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          // Scrollable source code panel
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(16.0),
            child: SelectableText.rich(
              _SyntaxHighlighter.highlight(code),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// CUSTOM LIGHTWEIGHT SYNTAX HIGHLIGHTER
// ============================================================================

class _SyntaxHighlighter {
  static TextSpan highlight(String code) {
    final List<TextSpan> spans = [];

    // Pattern catches comments, strings, standard keywords, and numeric entries
    final regExp = RegExp(
      r'(//.*|#.*)|("(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27)|(\b(?:class|void|return|final|const|var|import|extends|implements|function|def|if|else|for|in|while|true|false|void|int|double|bool|String|List|Map|null)\b)|(\b\d+\b)',
      multiLine: true,
    );

    int lastIndex = 0;

    for (final match in regExp.allMatches(code)) {
      // Append raw plain text before match
      if (match.start > lastIndex) {
        spans.add(TextSpan(text: code.substring(lastIndex, match.start)));
      }

      if (match.group(1) != null) {
        // Comment block (grey-purple)
        spans.add(TextSpan(
          text: match.group(1),
          style: const TextStyle(
              color: Color(0xFF6272A4), fontStyle: FontStyle.italic),
        ));
      } else if (match.group(2) != null) {
        // Strings (yellow/green)
        spans.add(TextSpan(
          text: match.group(2),
          style: const TextStyle(color: Color(0xFFE6DB74)),
        ));
      } else if (match.group(3) != null) {
        // Core programming keywords (pink)
        spans.add(TextSpan(
          text: match.group(3),
          style: const TextStyle(
              color: Color(0xFFF92672), fontWeight: FontWeight.bold),
        ));
      } else if (match.group(4) != null) {
        // Numeric tokens (purple)
        spans.add(TextSpan(
          text: match.group(4),
          style: const TextStyle(color: Color(0xFFAE81FF)),
        ));
      }

      lastIndex = match.end;
    }

    if (lastIndex < code.length) {
      spans.add(TextSpan(text: code.substring(lastIndex)));
    }

    return TextSpan(
      style: const TextStyle(
        fontFamily: 'Consolas',
        fontSize: 13.0,
        color: Color(0xFFF8F8F2),
        height: 1.45,
      ),
      children: spans,
    );
  }
}

// ============================================================================
// INLINE TEXT COMPILER
// ============================================================================

class _MarkdownTextWidget extends StatelessWidget {
  final String text;

  const _MarkdownTextWidget({required this.text});

  @override
  Widget build(BuildContext context) {
    final lines = text.trim().split('\n');
    final widgets = <Widget>[];

    for (final line in lines) {
      final trimmed = line.trimRight();
      if (trimmed.trim().isEmpty) {
        widgets.add(const SizedBox(height: 6));
        continue;
      }

      final headingLevel = _headingLevel(trimmed);
      if (headingLevel > 0) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 5),
            child: SelectableText.rich(
              _inlineSpan(trimmed.replaceFirst(RegExp(r'^#{1,3}\s+'), '')),
              style: TextStyle(
                fontSize: headingLevel == 1 ? 18 : 15.5,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w900,
                height: 1.35,
              ),
            ),
          ),
        );
        continue;
      }

      final bulletMatch = RegExp(r'^\s*[-*]\s+(.+)$').firstMatch(trimmed);
      final numberMatch = RegExp(r'^\s*(\d+)[.)]\s+(.+)$').firstMatch(trimmed);
      if (bulletMatch != null || numberMatch != null) {
        final marker = bulletMatch != null ? '•' : '${numberMatch!.group(1)}.';
        final body = bulletMatch?.group(1) ?? numberMatch!.group(2)!;
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    marker,
                    style: const TextStyle(
                      color: AppColors.cyan,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Expanded(child: _SelectableInlineText(span: _inlineSpan(body))),
              ],
            ),
          ),
        );
        continue;
      }

      widgets.add(_SelectableInlineText(span: _inlineSpan(trimmed)));
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widgets,
      ),
    );
  }

  int _headingLevel(String line) {
    if (line.startsWith('# ')) return 1;
    if (line.startsWith('## ')) return 2;
    if (line.startsWith('### ')) return 3;
    return 0;
  }

  TextSpan _inlineSpan(String value) {
    final List<InlineSpan> spans = [];
    final regExp = RegExp(r'(\*\*.*?\*\*)|(`.*?`)');
    int lastIndex = 0;

    for (final match in regExp.allMatches(value)) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(text: value.substring(lastIndex, match.start)));
      }

      final matchedText = match.group(0)!;
      if (matchedText.startsWith('**') && matchedText.endsWith('**')) {
        // Bold formatting
        spans.add(TextSpan(
          text: matchedText.substring(2, matchedText.length - 2),
          style:
              const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ));
      } else if (matchedText.startsWith('`') && matchedText.endsWith('`')) {
        // Inline code markers
        spans.add(TextSpan(
          text: matchedText.substring(1, matchedText.length - 1),
          style: const TextStyle(
            fontFamily: 'Consolas',
            backgroundColor: Color(0xFF1E2235),
            color: AppColors.cyan,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ));
      }

      lastIndex = match.end;
    }

    if (lastIndex < value.length) {
      spans.add(TextSpan(text: value.substring(lastIndex)));
    }

    return TextSpan(
      style: const TextStyle(
        fontSize: 14.5,
        color: AppColors.textPrimary,
        height: 1.55,
      ),
      children: spans,
    );
  }
}

class _SelectableInlineText extends StatelessWidget {
  const _SelectableInlineText({required this.span});

  final TextSpan span;

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(span);
  }
}

// ============================================================================
// TYPING INDICATOR WIDGET
// ============================================================================

class TypingIndicatorWidget extends StatelessWidget {
  const TypingIndicatorWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppState.selectedMode,
      builder: (context, mode, _) {
        final modeColor = AppColors.getModeColor(mode);

        return ValueListenableBuilder<RuntimeSnapshot>(
          valueListenable: RuntimeDiagnostics.snapshot,
          builder: (context, snapshot, _) {
            final label = _typingLabel(snapshot, mode);

            return Padding(
              padding: const EdgeInsets.only(bottom: 20.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          modeColor.withValues(alpha: 0.22),
                          AppColors.surfaceSoft,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      border: Border.all(
                        color: modeColor.withValues(alpha: 0.55),
                        width: 1.4,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: modeColor.withValues(alpha: 0.12),
                          blurRadius: 14,
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.auto_awesome,
                      size: 14,
                      color: modeColor,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                AppColors.aiBubble,
                                Color(0xFF151A2C),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(18),
                              topRight: Radius.circular(18),
                              bottomLeft: Radius.circular(6),
                              bottomRight: Radius.circular(18),
                            ),
                            border: Border.all(
                              color: modeColor.withValues(alpha: 0.16),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: modeColor.withValues(alpha: 0.08),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: modeColor,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  label,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: modeColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _typingLabel(RuntimeSnapshot snapshot, String mode) {
    if (snapshot.retrievalStatus.contains('Searching')) {
      return 'Searching live web...';
    }
    if (snapshot.retrievalStatus.contains('Injecting')) {
      return 'Injecting retrieved context...';
    }
    if (snapshot.retrievalStatus.contains('Retrieved')) {
      return 'Grounding response...';
    }
    return 'OmniCore AI is writing under $mode Mode...';
  }
}
