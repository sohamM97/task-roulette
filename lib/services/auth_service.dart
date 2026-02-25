import 'dart:convert';
import 'dart:io' show Platform, Process;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/auth_io.dart' as auth_io;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// User info returned after successful sign-in.
class AuthUser {
  final String uid;
  final String? displayName;
  final String? email;
  final String? photoUrl;

  AuthUser({required this.uid, this.displayName, this.email, this.photoUrl});
}

/// Handles Google Sign-In on Android (via google_sign_in plugin) and
/// Linux (via googleapis_auth browser OAuth), then exchanges the Google
/// ID token for a Firebase ID token via the Firebase Auth REST API.
class AuthService {
  // TODO: Replace with your actual Firebase project values
  static const _firebaseApiKey = String.fromEnvironment(
    'FIREBASE_API_KEY',
    defaultValue: '',
  );
  static const _linuxClientId = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_ID',
    defaultValue: '',
  );
  static const _linuxClientSecret = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_SECRET',
    defaultValue: '',
  );

  // Web client ID (auto-created by Firebase, needed for Android google_sign_in)
  static const _webClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue: '1009352820106-uigevs5kld7t51s1gol27l7n85m2vp36.apps.googleusercontent.com',
  );

  static const _prefsKeyRefreshToken = 'auth_refresh_token';
  static const _prefsKeyUid = 'auth_uid';
  static const _prefsKeyDisplayName = 'auth_display_name';
  static const _prefsKeyEmail = 'auth_email';
  static const _prefsKeyPhotoUrl = 'auth_photo_url';

  String? _firebaseIdToken;
  String? _firebaseRefreshToken;
  DateTime? _tokenExpiresAt;
  AuthUser? _user;

  String? get firebaseIdToken => _firebaseIdToken;
  bool get isTokenExpired =>
      _tokenExpiresAt == null ||
      DateTime.now().isAfter(_tokenExpiresAt!.subtract(const Duration(minutes: 1)));
  AuthUser? get user => _user;
  bool get isSignedIn => _user != null && _firebaseIdToken != null;
  String? get uid => _user?.uid;

  /// True if the required configuration is present.
  bool get isConfigured => _firebaseApiKey.isNotEmpty;

  /// Attempts silent sign-in using stored refresh token.
  Future<bool> silentSignIn() async {
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString(_prefsKeyRefreshToken);
    if (refreshToken == null || _firebaseApiKey.isEmpty) return false;

    try {
      final result = await _refreshFirebaseToken(refreshToken);
      if (result != null) {
        _applyTokenResult(result);
        _user = AuthUser(
          uid: prefs.getString(_prefsKeyUid) ?? '',
          displayName: prefs.getString(_prefsKeyDisplayName),
          email: prefs.getString(_prefsKeyEmail),
          photoUrl: prefs.getString(_prefsKeyPhotoUrl),
        );
        await _persistTokens(prefs);
        return true;
      }
    } catch (e) {
      debugPrint('AuthService: silent sign-in failed: $e');
    }
    return false;
  }

  /// Interactive sign-in. Platform-specific.
  Future<AuthUser?> signIn() async {
    if (_firebaseApiKey.isEmpty) return null;

    String? googleIdToken;
    String? displayName;
    String? email;
    String? photoUrl;

    if (!kIsWeb && (Platform.isLinux || Platform.isWindows)) {
      final result = await _signInDesktop();
      if (result == null) return null;
      googleIdToken = result['idToken'];
      displayName = result['displayName'];
      email = result['email'];
      photoUrl = result['photoUrl'];
    } else {
      // Android / iOS — use google_sign_in plugin
      final result = await _signInMobile();
      if (result == null) return null;
      googleIdToken = result['idToken'];
      displayName = result['displayName'];
      email = result['email'];
      photoUrl = result['photoUrl'];
    }

    if (googleIdToken == null) return null;

    // Exchange Google ID token for Firebase ID token
    final firebaseResult = await _exchangeGoogleToken(googleIdToken);
    if (firebaseResult == null) return null;

    _firebaseIdToken = firebaseResult['idToken'] as String?;
    _firebaseRefreshToken = firebaseResult['refreshToken'] as String?;
    final expiresIn = int.tryParse('${firebaseResult['expiresIn'] ?? ''}');
    _tokenExpiresAt = expiresIn != null
        ? DateTime.now().add(Duration(seconds: expiresIn))
        : null;
    final uid = firebaseResult['localId'] as String? ?? '';

    _user = AuthUser(
      uid: uid,
      displayName: displayName ?? firebaseResult['displayName'] as String?,
      email: email ?? firebaseResult['email'] as String?,
      photoUrl: photoUrl ?? firebaseResult['photoUrl'] as String?,
    );

    final prefs = await SharedPreferences.getInstance();
    await _persistTokens(prefs);
    await _persistUserInfo(prefs);

    return _user;
  }

  Future<void> signOut() async {
    _firebaseIdToken = null;
    _firebaseRefreshToken = null;
    _tokenExpiresAt = null;
    _user = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKeyRefreshToken);
    await prefs.remove(_prefsKeyUid);
    await prefs.remove(_prefsKeyDisplayName);
    await prefs.remove(_prefsKeyEmail);
    await prefs.remove(_prefsKeyPhotoUrl);

    // Sign out of Google on mobile
    if (!kIsWeb && !Platform.isLinux && !Platform.isWindows) {
      try {
        await GoogleSignIn().signOut();
      } catch (e) {
        debugPrint('AuthService: Google sign-out failed: $e');
      }
    }
  }

  /// Refreshes the Firebase ID token. Returns true on success.
  Future<bool> refreshToken() async {
    if (_firebaseRefreshToken == null) return false;
    final result = await _refreshFirebaseToken(_firebaseRefreshToken!);
    if (result != null) {
      _applyTokenResult(result);
      final prefs = await SharedPreferences.getInstance();
      await _persistTokens(prefs);
      return true;
    }
    return false;
  }

  /// Applies id_token, refresh_token, and expires_in from a refresh response.
  void _applyTokenResult(Map<String, dynamic> result) {
    _firebaseIdToken = result['id_token'] as String?;
    _firebaseRefreshToken = result['refresh_token'] as String?;
    final expiresIn = int.tryParse('${result['expires_in'] ?? ''}');
    _tokenExpiresAt = expiresIn != null
        ? DateTime.now().add(Duration(seconds: expiresIn))
        : null;
  }

  // --- Private helpers ---

  Future<Map<String, String>?> _signInMobile() async {
    final googleSignIn = GoogleSignIn(
      scopes: ['email'],
      serverClientId: _webClientId,
    );
    try {
      final account = await googleSignIn.signIn();
      if (account == null) return null;
      final auth = await account.authentication;
      if (auth.idToken == null || auth.idToken!.isEmpty) {
        debugPrint('AuthService: Google sign-in succeeded but idToken is null');
        return null;
      }
      return {
        'idToken': auth.idToken!,
        'displayName': account.displayName ?? '',
        'email': account.email,
        'photoUrl': account.photoUrl ?? '',
      };
    } catch (e) {
      debugPrint('AuthService: Mobile sign-in error: $e');
      return null;
    }
  }

  Future<Map<String, String>?> _signInDesktop() async {
    if (_linuxClientId.isEmpty || _linuxClientSecret.isEmpty) return null;

    final clientId = ClientId(_linuxClientId, _linuxClientSecret);
    final scopes = ['email', 'profile', 'openid'];

    try {
      final client = await auth_io.clientViaUserConsent(
        clientId,
        scopes,
        (url) async {
          // Open browser for OAuth consent
          await Process.start('xdg-open', [url]);
        },
      );

      // Get the ID token from the credentials
      final credentials = client.credentials;
      final idToken = credentials.idToken;
      client.close();

      if (idToken == null) return null;

      // Decode ID token to get user info (JWT payload)
      final parts = idToken.split('.');
      if (parts.length != 3) return null;
      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;

      return {
        'idToken': idToken,
        'displayName': payload['name'] as String? ?? '',
        'email': payload['email'] as String? ?? '',
        'photoUrl': payload['picture'] as String? ?? '',
      };
    } catch (e) {
      return null;
    }
  }

  /// Exchange a Google ID token for a Firebase ID token via REST API.
  Future<Map<String, dynamic>?> _exchangeGoogleToken(String googleIdToken) async {
    final url = Uri.parse(
      'https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=$_firebaseApiKey',
    );
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'postBody': 'id_token=$googleIdToken&providerId=google.com',
        'requestUri': 'http://localhost',
        'returnIdpCredential': true,
        'returnSecureToken': true,
      }),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    debugPrint('AuthService: Firebase token exchange failed: ${response.statusCode} ${response.body}');
    return null;
  }

  /// Refresh Firebase ID token using refresh token.
  Future<Map<String, dynamic>?> _refreshFirebaseToken(String refreshToken) async {
    final url = Uri.parse(
      'https://securetoken.googleapis.com/v1/token?key=$_firebaseApiKey',
    );
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: 'grant_type=refresh_token&refresh_token=$refreshToken',
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    return null;
  }

  Future<void> _persistTokens(SharedPreferences prefs) async {
    if (_firebaseRefreshToken != null) {
      await prefs.setString(_prefsKeyRefreshToken, _firebaseRefreshToken!);
    }
  }

  Future<void> _persistUserInfo(SharedPreferences prefs) async {
    if (_user != null) {
      await prefs.setString(_prefsKeyUid, _user!.uid);
      if (_user!.displayName != null) {
        await prefs.setString(_prefsKeyDisplayName, _user!.displayName!);
      }
      if (_user!.email != null) {
        await prefs.setString(_prefsKeyEmail, _user!.email!);
      }
      if (_user!.photoUrl != null) {
        await prefs.setString(_prefsKeyPhotoUrl, _user!.photoUrl!);
      }
    }
  }
}
