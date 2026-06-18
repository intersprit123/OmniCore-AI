import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/ai_memory.dart';
import '../models/chat_message.dart';

class FirestoreService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static String _userChatsPath(String uid) => 'users/$uid/chats';
  static String _userMemoriesPath(String uid) => 'users/$uid/memories';

  static Future<void> saveSession(String uid, ChatSession session) async {
    final path = '${_userChatsPath(uid)}/${session.id}';
    await _db.doc(path).set(session.toJson());
  }

  static Future<void> deleteSession(String uid, String sessionId) async {
    final path = '${_userChatsPath(uid)}/$sessionId';
    await _db.doc(path).delete();
  }

  static Future<List<ChatSession>> loadSessions(String uid) async {
    final snapshot = await _db.collection(_userChatsPath(uid)).get();
    return snapshot.docs
        .map((doc) => ChatSession.fromJson(doc.data()))
        .toList();
  }

  static Future<void> saveMemory(String uid, OmniMemory memory) async {
    final path = '${_userMemoriesPath(uid)}/${memory.id}';
    await _db.doc(path).set(memory.toJson());
  }

  static Future<void> deleteMemory(String uid, String memoryId) async {
    final path = '${_userMemoriesPath(uid)}/$memoryId';
    await _db.doc(path).delete();
  }

  static Future<List<OmniMemory>> loadMemories(String uid) async {
    final snapshot = await _db
        .collection(_userMemoriesPath(uid))
        .orderBy('updatedAt', descending: true)
        .get();
    return snapshot.docs.map((doc) => OmniMemory.fromJson(doc.data())).toList();
  }

  static Future<bool> isFirstTimeUser(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    return !doc.exists;
  }

  static Future<void> createUserProfile(User user) async {
    final docRef = _db.collection('users').doc(user.uid);
    await docRef.set({
      'uid': user.uid,
      'displayName': user.displayName ?? 'Omni Pilot',
      'email': user.email,
      'photoURL': user.photoURL,
      'createdAt': FieldValue.serverTimestamp(),
      'lastLogin': FieldValue.serverTimestamp(),
      'preferences': {
        'theme': 'dark',
        'compactMode': false,
        'selectedMode': 'Smart',
      }
    });
  }

  static Future<void> updateUserLastLogin(String uid) async {
    await _db.collection('users').doc(uid).update({
      'lastLogin': FieldValue.serverTimestamp(),
    });
  }
}
