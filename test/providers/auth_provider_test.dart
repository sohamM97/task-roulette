import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/providers/auth_provider.dart';

void main() {
  group('AuthProvider', () {
    late AuthProvider provider;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      // Stub out flutter_secure_storage platform channel
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (MethodCall methodCall) async => null,
      );
      // Stub out shared_preferences platform channel
      // shared_preferences v2 uses SharedPreferencesStorePlatform via method channel
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/shared_preferences'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'getAll') return <String, dynamic>{};
          if (methodCall.method == 'remove') return true;
          if (methodCall.method == 'setBool') return true;
          if (methodCall.method == 'setString') return true;
          if (methodCall.method == 'setInt') return true;
          return null;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/shared_preferences_async'),
        (MethodCall methodCall) async => null,
      );
      // Stub out google_sign_in platform channel
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/google_sign_in'),
        (MethodCall methodCall) async => null,
      );
    });

    setUp(() {
      provider = AuthProvider();
    });

    group('setSyncStatus', () {
      test('updates sync status', () {
        provider.setSyncStatus(SyncStatus.syncing);
        expect(provider.syncStatus, SyncStatus.syncing);
      });

      test('updates to synced', () {
        provider.setSyncStatus(SyncStatus.synced);
        expect(provider.syncStatus, SyncStatus.synced);
      });

      test('updates to error with message', () {
        provider.setSyncStatus(SyncStatus.error, error: 'Network failed');
        expect(provider.syncStatus, SyncStatus.error);
        expect(provider.syncError, 'Network failed');
      });

      test('clears error when status changes to non-error', () {
        provider.setSyncStatus(SyncStatus.error, error: 'Oops');
        provider.setSyncStatus(SyncStatus.synced);
        expect(provider.syncStatus, SyncStatus.synced);
        expect(provider.syncError, isNull);
      });

      test('notifies listeners', () {
        int notifyCount = 0;
        provider.addListener(() => notifyCount++);
        provider.setSyncStatus(SyncStatus.syncing);
        expect(notifyCount, 1);
      });

      test('initial status is idle', () {
        expect(provider.syncStatus, SyncStatus.idle);
        expect(provider.syncError, isNull);
      });
    });

    group('isConfigured', () {
      test('returns false without dart-define', () {
        // Without FIREBASE_PROJECT_ID dart-define, AuthService is not configured
        expect(provider.isConfigured, isFalse);
      });
    });

    group('initial state', () {
      test('is not signed in initially', () {
        expect(provider.isSignedIn, isFalse);
      });

      test('user is null initially', () {
        expect(provider.user, isNull);
      });

      test('uid is null initially', () {
        expect(provider.uid, isNull);
      });

      test('firebaseIdToken is null initially', () {
        expect(provider.firebaseIdToken, isNull);
      });

      test('token is considered expired when no token exists', () {
        expect(provider.isTokenExpired, isTrue);
      });
    });

    group('init', () {
      test('does not crash when not configured', () async {
        // Without --dart-define, isConfigured is false — init returns early
        await provider.init();
        expect(provider.isSignedIn, isFalse);
      });

      test('does not notify listeners when not configured', () async {
        int notifyCount = 0;
        provider.addListener(() => notifyCount++);
        await provider.init();
        // When unconfigured, init returns early before notifyListeners
        expect(notifyCount, 0);
      });
    });

    group('signIn', () {
      test('returns false when not configured', () async {
        // AuthService.signIn returns null when _firebaseApiKey is empty
        final result = await provider.signIn();
        expect(result, isFalse);
      });

      test('notifies listeners after signIn attempt', () async {
        int notifyCount = 0;
        provider.addListener(() => notifyCount++);
        await provider.signIn();
        expect(notifyCount, 1);
      });
    });

    group('signOut', () {
      test('resets sync state and notifies', () async {
        provider.setSyncStatus(SyncStatus.synced);
        int notifyCount = 0;
        provider.addListener(() => notifyCount++);

        await provider.signOut();

        expect(provider.syncStatus, SyncStatus.idle);
        expect(provider.syncError, isNull);
        expect(notifyCount, 1);
      });

      test('clears error on signOut', () async {
        provider.setSyncStatus(SyncStatus.error, error: 'some error');
        await provider.signOut();
        expect(provider.syncError, isNull);
        expect(provider.syncStatus, SyncStatus.idle);
      });
    });

    group('refreshToken', () {
      test('returns false when no refresh token exists', () async {
        final result = await provider.refreshToken();
        expect(result, isFalse);
      });
    });

    group('SyncStatus enum', () {
      test('has all expected values', () {
        expect(SyncStatus.values.length, 4);
        expect(SyncStatus.values, containsAll([
          SyncStatus.idle,
          SyncStatus.syncing,
          SyncStatus.synced,
          SyncStatus.error,
        ]));
      });
    });
  });
}
