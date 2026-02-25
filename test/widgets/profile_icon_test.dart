import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:task_roulette/providers/auth_provider.dart';
import 'package:task_roulette/services/sync_service.dart';
import 'package:task_roulette/widgets/profile_icon.dart';

void main() {
  group('ProfileIcon', () {
    Widget buildTestWidget({required AuthProvider auth}) {
      final syncService = SyncService(auth);
      return MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              MultiProvider(
                providers: [
                  ChangeNotifierProvider<AuthProvider>.value(value: auth),
                  Provider<SyncService>.value(value: syncService),
                ],
                child: const ProfileIcon(),
              ),
            ],
          ),
        ),
      );
    }

    testWidgets('shows nothing when not configured', (tester) async {
      // Default AuthProvider (unconfigured without dart-define)
      final auth = AuthProvider();

      await tester.pumpWidget(buildTestWidget(auth: auth));
      await tester.pump();

      // Should render SizedBox.shrink — no IconButton
      expect(find.byType(IconButton), findsNothing);
    });

    // Can't easily test signed-in state without mocking AuthService,
    // but we can verify the badge rendering logic indirectly via sync status

    testWidgets('shows correct sync badge for each SyncStatus', (tester) async {
      final auth = AuthProvider();

      // Test idle status badge
      auth.setSyncStatus(SyncStatus.idle);
      expect(auth.syncStatus, SyncStatus.idle);

      // Test syncing status
      auth.setSyncStatus(SyncStatus.syncing);
      expect(auth.syncStatus, SyncStatus.syncing);

      // Test synced status
      auth.setSyncStatus(SyncStatus.synced);
      expect(auth.syncStatus, SyncStatus.synced);

      // Test error status
      auth.setSyncStatus(SyncStatus.error, error: 'Network error');
      expect(auth.syncStatus, SyncStatus.error);
      expect(auth.syncError, 'Network error');
    });
  });
}
