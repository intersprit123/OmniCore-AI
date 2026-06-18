import 'dart:async';
import 'dart:developer' as dev;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../firebase_options.dart';

class AuthService {
  static bool _initialized = false;
  static Future<void>? _initializationFuture;
  static final StreamController<User?> _authController =
      StreamController<User?>.broadcast();
  static StreamSubscription<User?>? _authSubscription;

  static bool get isInitialized => _initialized;

  /// Initialize Firebase app.
  static Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    _initializationFuture ??= _doInitialize().whenComplete(() {
      if (!_initialized) _initializationFuture = null;
    });
    return _initializationFuture!;
  }

  static Future<bool> ensureInitialized({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_initialized) return true;
    try {
      await initialize().timeout(timeout);
      return _initialized;
    } catch (error, stackTrace) {
      dev.log(
        'Firebase initialization failed.',
        error: error,
        stackTrace: stackTrace,
      );
      _authController.add(null);
      return false;
    }
  }

  static Future<void> _doInitialize() async {
    if (_initialized) return;
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    _initialized = true;
    await _authSubscription?.cancel();
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen(
          _authController.add,
          onError: _authController.addError,
        );
    _authController.add(FirebaseAuth.instance.currentUser);
  }

  /// Sign in anonymously.
  static Future<User?> signInAnonymously() async {
    if (!await ensureInitialized()) return null;
    final credential = await FirebaseAuth.instance.signInAnonymously();
    return credential.user;
  }

  /// Sign in with Google (Web).
  static Future<User?> signInWithGoogle() async {
    if (!await ensureInitialized()) return null;
    final provider = GoogleAuthProvider();
    final credential = await FirebaseAuth.instance.signInWithPopup(provider);
    return credential.user;
  }

  static Stream<User?> authStateChanges() => _authController.stream;

  static Future<void> signOut() async {
    if (!await ensureInitialized()) return;
    await FirebaseAuth.instance.signOut();
  }

  static User? get currentUser =>
      _initialized ? FirebaseAuth.instance.currentUser : null;
}
