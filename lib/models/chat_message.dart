/// Chat message and session models for OmniCore AI.
/// These models handle serialization for Hive local storage.
///
/// Used by:
///   - AppState (main.dart) for runtime state management
///   - MemoryService for local persistence via Hive
library;

class Message {
  final String id;
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final String mode;

  const Message({
    required this.id,
    required this.text,
    required this.isUser,
    required this.timestamp,
    required this.mode,
  });

  /// Create a copy with an optionally updated text field.
  /// Used for streaming AI response updates.
  Message copyWith({String? text}) {
    return Message(
      id: id,
      text: text ?? this.text,
      isUser: isUser,
      timestamp: timestamp,
      mode: mode,
    );
  }

  /// Serialize to JSON-compatible map for Hive storage.
  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'isUser': isUser,
        'timestamp': timestamp.toIso8601String(),
        'mode': mode,
      };

  /// Deserialize from a JSON-compatible map.
  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        text: json['text'] as String,
        isUser: json['isUser'] as bool,
        timestamp: DateTime.parse(json['timestamp'] as String),
        mode: json['mode'] as String,
      );
}

class ChatSession {
  final String id;
  final String title;
  final List<Message> messages;
  final DateTime lastInteraction;

  const ChatSession({
    required this.id,
    required this.title,
    required this.messages,
    required this.lastInteraction,
  });

  /// Serialize to JSON-compatible map for Hive storage.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'messages': messages.map((m) => m.toJson()).toList(),
        'lastInteraction': lastInteraction.toIso8601String(),
      };

  /// Deserialize from a JSON-compatible map.
  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json['id'] as String,
        title: json['title'] as String,
        messages: (json['messages'] as List<dynamic>)
            .map((e) => Message.fromJson(e as Map<String, dynamic>))
            .toList(),
        lastInteraction: DateTime.parse(json['lastInteraction'] as String),
      );
}
