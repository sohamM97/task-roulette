import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/providers/auth_provider.dart';

void main() {
  group('AuthProvider', () {
    late AuthProvider provider;

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
    });
  });
}
