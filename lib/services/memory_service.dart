import 'dart:convert';
import 'dart:async';
import 'dart:developer' as dev;

import 'package:hive_flutter/hive_flutter.dart';

import '../models/ai_memory.dart';
import '../models/chat_message.dart';

class MemoryService {
  static Box? _box;

  static const String _sessionsKey = 'sessions';
  static const String _selectedSessionIdKey = 'selectedSessionId';
  static const String _selectedModeKey = 'selectedMode';
  static const String _memoriesKey = 'omniMemories';

  static bool get isReady => _box != null;

  /// Initialize Hive and open the box.
  static Future<void> init() async {
    try {
      await Hive.initFlutter().timeout(const Duration(seconds: 3));
      _box = await Hive.openBox('app_state').timeout(
        const Duration(seconds: 3),
      );
    } catch (error, stackTrace) {
      dev.log(
        'Local memory initialization failed; continuing without Hive cache.',
        error: error,
        stackTrace: stackTrace,
      );
      _box = null;
    }
  }

  /// Save only the sessions list to Hive.
  static Future<void> saveSessions(List<ChatSession> sessions) async {
    final box = _box;
    if (box == null) return;
    try {
      final sessionsJson =
          jsonEncode(sessions.map((s) => s.toJson()).toList());
      await box.put(_sessionsKey, sessionsJson);
    } catch (error, stackTrace) {
      dev.log(
        'Failed to save local sessions.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Save only the selected session ID to Hive.
  static Future<void> saveSelectedSessionId(String selectedSessionId) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(_selectedSessionIdKey, selectedSessionId);
    } catch (error, stackTrace) {
      dev.log(
        'Failed to save selected session.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Save only the selected mode to Hive.
  static Future<void> saveSelectedMode(String selectedMode) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(_selectedModeKey, selectedMode);
    } catch (error, stackTrace) {
      dev.log(
        'Failed to save selected mode.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Save all relevant app state to Hive.
  static Future<void> saveState({
    required List<ChatSession> sessions,
    required String selectedSessionId,
    required String selectedMode,
  }) async {
    final box = _box;
    if (box == null) return;
    try {
      final sessionsJson =
          jsonEncode(sessions.map((s) => s.toJson()).toList());
      await box.put(_sessionsKey, sessionsJson);
      await box.put(_selectedSessionIdKey, selectedSessionId);
      await box.put(_selectedModeKey, selectedMode);
    } catch (error, stackTrace) {
      dev.log(
        'Failed to save local app state.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Load stored state. Returns null fields if not present.
  static List<ChatSession>? loadSessions() {
    final box = _box;
    if (box == null) return null;
    try {
      final jsonStr = box.get(_sessionsKey) as String?;
      if (jsonStr == null) return null;
      final List<dynamic> list = jsonDecode(jsonStr);
      return list
          .map((e) => ChatSession.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (error, stackTrace) {
      dev.log(
        'Failed to load local sessions.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  static Future<void> saveMemories(List<OmniMemory> memories) async {
    final box = _box;
    if (box == null) return;
    try {
      final memoriesJson =
          jsonEncode(memories.map((m) => m.toJson()).toList());
      await box.put(_memoriesKey, memoriesJson);
    } catch (error, stackTrace) {
      dev.log(
        'Failed to save local memories.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static List<OmniMemory>? loadMemories() {
    final box = _box;
    if (box == null) return null;
    try {
      final jsonStr = box.get(_memoriesKey) as String?;
      if (jsonStr == null) return null;
      final List<dynamic> list = jsonDecode(jsonStr);
      return list
          .map((e) => OmniMemory.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (error, stackTrace) {
      dev.log(
        'Failed to load local memories.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  static String? loadSelectedSessionId() {
    final box = _box;
    if (box == null) return null;
    try {
      return box.get(_selectedSessionIdKey) as String?;
    } catch (error, stackTrace) {
      dev.log(
        'Failed to load selected session.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  static String? loadSelectedMode() {
    final box = _box;
    if (box == null) return null;
    try {
      return box.get(_selectedModeKey) as String?;
    } catch (error, stackTrace) {
      dev.log(
        'Failed to load selected mode.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}
