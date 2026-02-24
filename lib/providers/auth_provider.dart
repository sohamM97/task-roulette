import 'package:flutter/foundation.dart';
import '../services/auth_service.dart';

enum SyncStatus { idle, syncing, synced, error }

class AuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();

  AuthUser? get user => _authService.user;
  bool get isSignedIn => _authService.isSignedIn;
  String? get uid => _authService.uid;
  String? get firebaseIdToken => _authService.firebaseIdToken;
  bool get isTokenExpired => _authService.isTokenExpired;
  bool get isConfigured => _authService.isConfigured;

  SyncStatus _syncStatus = SyncStatus.idle;
  SyncStatus get syncStatus => _syncStatus;

  String? _syncError;
  String? get syncError => _syncError;

  /// Called once at app startup to attempt silent sign-in.
  Future<void> init() async {
    if (!_authService.isConfigured) return;
    await _authService.silentSignIn();
    notifyListeners();
  }

  Future<bool> signIn() async {
    final user = await _authService.signIn();
    notifyListeners();
    return user != null;
  }

  Future<void> signOut() async {
    await _authService.signOut();
    _syncStatus = SyncStatus.idle;
    _syncError = null;
    notifyListeners();
  }

  Future<bool> refreshToken() async {
    final success = await _authService.refreshToken();
    if (!success) {
      // Token refresh failed — user needs to sign in again
      await _authService.signOut();
      notifyListeners();
    }
    return success;
  }

  void setSyncStatus(SyncStatus status, {String? error}) {
    _syncStatus = status;
    _syncError = error;
    notifyListeners();
  }
}
