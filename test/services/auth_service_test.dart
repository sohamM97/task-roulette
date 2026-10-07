import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:task_roulette/services/auth_service.dart';

/// `AuthService` reads its Firebase API key from a compile-time
/// `--dart-define`. Without it, every network path returns early, so the
/// tests that reach the token endpoints run only when the key is defined:
///
///   flutter test --dart-define=FIREBASE_API_KEY=test-key \
///       test/services/auth_service_test.dart
const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
const _needsKey = _apiKey == ''
    ? 'needs --dart-define=FIREBASE_API_KEY=<any value>'
    : false;

const _secureKey = 'auth_refresh_token';

/// A successful response from the securetoken.googleapis.com refresh endpoint.
http.Response _refreshResponse({
  String idToken = 'new-id-token',
  String refreshToken = 'new-refresh-token',
  String expiresIn = '3600',
}) =>
    http.Response(
      json.encode({
        'id_token': idToken,
        'refresh_token': refreshToken,
        'expires_in': expiresIn,
      }),
      200,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Held by reference by the test storage platform, so tests can inspect
  // and change what the service reads and writes.
  late Map<String, String> secure;

  setUp(() {
    secure = {};
    FlutterSecureStorage.setMockInitialValues(secure);
    SharedPreferences.setMockInitialValues({});
  });

  group('initial state', () {
    test('a new service is signed out with an expired token', () {
      final auth = AuthService();
      expect(auth.isSignedIn, isFalse);
      expect(auth.user, isNull);
      expect(auth.uid, isNull);
      expect(auth.firebaseIdToken, isNull);
      expect(auth.isTokenExpired, isTrue);
    });

    test('isConfigured reflects whether FIREBASE_API_KEY is defined', () {
      expect(AuthService().isConfigured, _apiKey.isNotEmpty);
    });
  });

  group('silentSignIn token storage', () {
    test('returns false when no refresh token is stored anywhere', () async {
      expect(await AuthService().silentSignIn(), isFalse);
      expect(secure, isEmpty);
    });

    test('migrates a legacy SharedPreferences token to secure storage',
        () async {
      SharedPreferences.setMockInitialValues(
          {'auth_refresh_token': 'legacy-token'});

      // With no API key the method returns false after the migration step;
      // with a key it would try the network, so block that here.
      await http.runWithClient(
        () => AuthService().silentSignIn(),
        () => MockClient((_) async => http.Response('', 500)),
      );

      expect(secure[_secureKey], 'legacy-token');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_refresh_token'), isNull);
    });

    test('a token already in secure storage wins over a legacy one', () async {
      secure[_secureKey] = 'secure-token';
      SharedPreferences.setMockInitialValues(
          {'auth_refresh_token': 'legacy-token'});

      await http.runWithClient(
        () => AuthService().silentSignIn(),
        () => MockClient((_) async => http.Response('', 500)),
      );

      expect(secure[_secureKey], 'secure-token');
      // The legacy key is left alone: migration only runs when secure
      // storage is empty. signOut() is what removes it.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_refresh_token'), 'legacy-token');
    });

    test('returns false without an API key even when a token is stored',
        () async {
      secure[_secureKey] = 'secure-token';
      var requests = 0;
      final result = await http.runWithClient(
        () => AuthService().silentSignIn(),
        () => MockClient((_) async {
          requests++;
          return http.Response('', 500);
        }),
      );
      expect(result, isFalse);
      expect(requests, 0);
    }, skip: _apiKey.isNotEmpty ? 'only meaningful without an API key' : false);
  });

  group('silentSignIn refresh (needs API key)', () {
    test('posts the stored refresh token and restores the user from prefs',
        () async {
      secure[_secureKey] = 'stored+token/with=chars';
      SharedPreferences.setMockInitialValues({
        'auth_uid': 'uid-1',
        'auth_display_name': 'Ada',
        'auth_email': 'ada@example.com',
        'auth_photo_url': 'https://example.com/a.png',
      });
      late http.Request sent;

      final auth = AuthService();
      final result = await http.runWithClient(
        () => auth.silentSignIn(),
        () => MockClient((request) async {
          sent = request;
          return _refreshResponse();
        }),
      );

      expect(result, isTrue);
      expect(sent.url.host, 'securetoken.googleapis.com');
      expect(sent.url.queryParameters['key'], _apiKey);
      expect(sent.headers['Content-Type'],
          startsWith('application/x-www-form-urlencoded'));
      // The refresh token is form-encoded, so '+', '/' and '=' survive.
      expect(Uri.splitQueryString(sent.body), {
        'grant_type': 'refresh_token',
        'refresh_token': 'stored+token/with=chars',
      });

      expect(auth.isSignedIn, isTrue);
      expect(auth.firebaseIdToken, 'new-id-token');
      expect(auth.isTokenExpired, isFalse);
      expect(auth.uid, 'uid-1');
      expect(auth.user!.displayName, 'Ada');
      expect(auth.user!.email, 'ada@example.com');
      expect(auth.user!.photoUrl, 'https://example.com/a.png');
      // The rotated refresh token replaces the stored one.
      expect(secure[_secureKey], 'new-refresh-token');
    }, skip: _needsKey);

    test('a non-200 refresh response leaves the service signed out',
        () async {
      secure[_secureKey] = 'revoked-token';
      final auth = AuthService();
      final result = await http.runWithClient(
        () => auth.silentSignIn(),
        () => MockClient((_) async => http.Response('{"error":{}}', 400)),
      );
      expect(result, isFalse);
      expect(auth.isSignedIn, isFalse);
      expect(secure[_secureKey], 'revoked-token');
    }, skip: _needsKey);

    test('a network exception is caught and reported as false', () async {
      secure[_secureKey] = 'token';
      final auth = AuthService();
      final result = await http.runWithClient(
        () => auth.silentSignIn(),
        () => MockClient((_) async => throw http.ClientException('offline')),
      );
      expect(result, isFalse);
      expect(auth.isSignedIn, isFalse);
    }, skip: _needsKey);

    test('a missing expires_in leaves the token marked expired', () async {
      secure[_secureKey] = 'token';
      final auth = AuthService();
      await http.runWithClient(
        () => auth.silentSignIn(),
        () => MockClient((_) async => _refreshResponse(expiresIn: '')),
      );
      expect(auth.firebaseIdToken, 'new-id-token');
      expect(auth.isTokenExpired, isTrue);
    }, skip: _needsKey);

    test('expires_in under one minute counts as already expired', () async {
      secure[_secureKey] = 'token';
      final auth = AuthService();
      await http.runWithClient(
        () => auth.silentSignIn(),
        () => MockClient((_) async => _refreshResponse(expiresIn: '30')),
      );
      expect(auth.isTokenExpired, isTrue);
    }, skip: _needsKey);
  });

  group('refreshToken', () {
    test('returns false when there is no refresh token', () async {
      expect(await AuthService().refreshToken(), isFalse);
    });

    test('concurrent calls share one Future', () async {
      final auth = AuthService();
      final first = auth.refreshToken();
      final second = auth.refreshToken();
      expect(identical(first, second), isTrue);
      await first;
      // Once it completes, the next call starts a new refresh.
      expect(identical(auth.refreshToken(), first), isFalse);
    });

    test('concurrent calls make one HTTP request (needs API key)', () async {
      secure[_secureKey] = 'token-0';
      final auth = AuthService();
      var requests = 0;
      final gate = Completer<void>();

      await http.runWithClient(
        () => auth.silentSignIn(),
        () => MockClient((_) async => _refreshResponse()),
      );

      final results = await http.runWithClient(
        () {
          final a = auth.refreshToken();
          final b = auth.refreshToken();
          gate.complete();
          return Future.wait([a, b]);
        },
        () => MockClient((_) async {
          requests++;
          await gate.future;
          return _refreshResponse(idToken: 'id-2', refreshToken: 'token-2');
        }),
      );

      expect(results, [true, true]);
      expect(requests, 1);
      expect(auth.firebaseIdToken, 'id-2');
      expect(secure[_secureKey], 'token-2');
    }, skip: _needsKey);

    test('a failed refresh keeps the previous tokens (needs API key)',
        () async {
      secure[_secureKey] = 'token-0';
      final auth = AuthService();
      await http.runWithClient(
        () => auth.silentSignIn(),
        () => MockClient((_) async => _refreshResponse()),
      );

      final result = await http.runWithClient(
        () => auth.refreshToken(),
        () => MockClient((_) async => http.Response('', 401)),
      );

      expect(result, isFalse);
      expect(auth.firebaseIdToken, 'new-id-token');
      expect(secure[_secureKey], 'new-refresh-token');
    }, skip: _needsKey);
  });

  group('signIn', () {
    test('returns null on Linux when the desktop OAuth client is not defined',
        () async {
      var requests = 0;
      final user = await http.runWithClient(
        () => AuthService().signIn(),
        () => MockClient((_) async {
          requests++;
          return http.Response('', 500);
        }),
      );
      expect(user, isNull);
      expect(requests, 0);
    });
  });

  group('signOut', () {
    test('clears in-memory state, secure storage and every prefs key',
        () async {
      secure[_secureKey] = 'token';
      SharedPreferences.setMockInitialValues({
        'auth_refresh_token': 'legacy',
        'auth_uid': 'uid-1',
        'auth_display_name': 'Ada',
        'auth_email': 'ada@example.com',
        'auth_photo_url': 'https://example.com/a.png',
        'unrelated_key': 'kept',
      });
      final auth = AuthService();
      if (_apiKey.isNotEmpty) {
        await http.runWithClient(
          () => auth.silentSignIn(),
          () => MockClient((_) async => _refreshResponse()),
        );
        expect(auth.isSignedIn, isTrue);
      }

      await auth.signOut();

      expect(auth.isSignedIn, isFalse);
      expect(auth.user, isNull);
      expect(auth.firebaseIdToken, isNull);
      expect(auth.isTokenExpired, isTrue);
      expect(secure, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {'unrelated_key'});
      // With the refresh token gone, a later refresh has nothing to send.
      expect(await auth.refreshToken(), isFalse);
    });
  });
}
