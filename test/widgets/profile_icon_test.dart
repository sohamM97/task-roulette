import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/auth_provider.dart';
import 'package:task_roulette/services/auth_service.dart';
import 'package:task_roulette/services/sync_service.dart';
import 'package:task_roulette/widgets/profile_icon.dart';

import '../helpers/async_pump.dart';

/// Configured auth whose signed-in state and sign-in outcome the test sets.
/// No network or secure storage is touched.
class _FakeAuthProvider extends AuthProvider {
  _FakeAuthProvider({this.signedIn = false, this.fakeUser, this.signInSucceeds = true});

  bool signedIn;
  AuthUser? fakeUser;
  bool signInSucceeds;
  int signInCalls = 0;

  @override
  bool get isConfigured => true;
  @override
  bool get isSignedIn => signedIn;
  @override
  AuthUser? get user => signedIn ? fakeUser : null;
  @override
  String? get uid => signedIn ? 'test-uid' : null;

  @override
  Future<bool> signIn() async {
    signInCalls++;
    if (signInSucceeds) signedIn = true;
    notifyListeners();
    return signInSucceeds;
  }

  @override
  Future<void> signOut() async {
    signedIn = false;
    setSyncStatus(SyncStatus.idle);
  }
}

/// Records which sync entry points [ProfileIcon] calls. The answers to
/// [needsInitialMigration] and [hasCloudData] are set per test.
class _FakeSyncService extends SyncService {
  _FakeSyncService(this.auth, {this.needsMigration = false, this.cloudHasData = false})
      : super(auth);

  final _FakeAuthProvider auth;
  bool needsMigration;
  bool cloudHasData;
  final calls = <String>[];

  @override
  Future<bool> needsInitialMigration() async => needsMigration;
  @override
  Future<bool> hasCloudData() async => cloudHasData;
  @override
  Future<void> initialMigration() async => calls.add('initialMigration');
  @override
  Future<void> replaceLocalWithCloud() async => calls.add('replaceLocalWithCloud');
  @override
  Future<void> replaceCloudWithLocal() async => calls.add('replaceCloudWithLocal');
  @override
  Future<void> mergeBoth() async => calls.add('mergeBoth');
  @override
  void startPeriodicPull() => calls.add('startPeriodicPull');
  @override
  Future<void> syncNow() async => calls.add('syncNow');
  @override
  Future<void> handleSignOut() async {
    calls.add('handleSignOut');
    await auth.signOut();
  }
}

void main() {
  late DatabaseHelper db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = DatabaseHelper();
    await db.reset();
    await db.database;
  });

  tearDown(() async {
    await db.reset();
  });

  Widget buildTestWidget({required AuthProvider auth, SyncService? syncService}) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          actions: [
            MultiProvider(
              providers: [
                ChangeNotifierProvider<AuthProvider>.value(value: auth),
                Provider<SyncService>.value(value: syncService ?? SyncService(auth)),
              ],
              child: const ProfileIcon(),
            ),
          ],
        ),
      ),
    );
  }

  final someUser = AuthUser(
    uid: 'test-uid',
    displayName: 'Ada Lovelace',
    email: 'ada@example.com',
  );

  group('ProfileIcon unconfigured', () {
    testWidgets('shows nothing when not configured', (tester) async {
      // Default AuthProvider (unconfigured without dart-define)
      final auth = AuthProvider();

      await tester.pumpWidget(buildTestWidget(auth: auth));
      await tester.pump();

      expect(find.byType(IconButton), findsNothing);
    });
  });

  group('ProfileIcon app bar icon', () {
    testWidgets('signed out shows the outlined account icon and "Sign in" tooltip', (tester) async {
      await tester.pumpWidget(buildTestWidget(auth: _FakeAuthProvider()));

      expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
      expect(find.byType(CircleAvatar), findsNothing);
      expect(tester.widget<IconButton>(find.byType(IconButton)).tooltip, 'Sign in');
    });

    testWidgets('signed in shows an avatar and "Account" tooltip', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        auth: _FakeAuthProvider(signedIn: true, fakeUser: someUser),
      ));

      expect(find.byIcon(Icons.account_circle_outlined), findsNothing);
      expect(find.byType(CircleAvatar), findsOneWidget);
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(tester.widget<IconButton>(find.byType(IconButton)).tooltip, 'Account');
    });

    testWidgets('an https photo URL loads as a NetworkImage', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        auth: _FakeAuthProvider(
          signedIn: true,
          fakeUser: AuthUser(uid: 'u', photoUrl: 'https://example.com/me.png'),
        ),
      ));

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.foregroundImage, isA<NetworkImage>());
      expect((avatar.foregroundImage! as NetworkImage).url, 'https://example.com/me.png');
    });

    testWidgets('a non-http photo URL is not loaded', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        auth: _FakeAuthProvider(
          signedIn: true,
          fakeUser: AuthUser(uid: 'u', photoUrl: 'file:///etc/passwd'),
        ),
      ));

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.foregroundImage, isNull);
    });
  });

  group('ProfileIcon sync badge', () {
    Finder badgeDot(Color color) => find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).color == color &&
        (w.decoration! as BoxDecoration).shape == BoxShape.circle);

    testWidgets('idle shows no badge', (tester) async {
      final auth = _FakeAuthProvider(signedIn: true, fakeUser: someUser);
      await tester.pumpWidget(buildTestWidget(auth: auth));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(badgeDot(Colors.green), findsNothing);
      expect(badgeDot(Colors.red), findsNothing);
    });

    testWidgets('syncing shows a spinner', (tester) async {
      final auth = _FakeAuthProvider(signedIn: true, fakeUser: someUser)
        ..setSyncStatus(SyncStatus.syncing);
      await tester.pumpWidget(buildTestWidget(auth: auth));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('synced shows a green dot', (tester) async {
      final auth = _FakeAuthProvider(signedIn: true, fakeUser: someUser)
        ..setSyncStatus(SyncStatus.synced);
      await tester.pumpWidget(buildTestWidget(auth: auth));

      expect(badgeDot(Colors.green), findsOneWidget);
      expect(badgeDot(Colors.red), findsNothing);
    });

    testWidgets('error shows a red dot', (tester) async {
      final auth = _FakeAuthProvider(signedIn: true, fakeUser: someUser)
        ..setSyncStatus(SyncStatus.error, error: 'boom');
      await tester.pumpWidget(buildTestWidget(auth: auth));

      expect(badgeDot(Colors.red), findsOneWidget);
      expect(badgeDot(Colors.green), findsNothing);
    });

    testWidgets('badge follows status changes without a remount', (tester) async {
      final auth = _FakeAuthProvider(signedIn: true, fakeUser: someUser);
      await tester.pumpWidget(buildTestWidget(auth: auth));

      auth.setSyncStatus(SyncStatus.syncing);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      auth.setSyncStatus(SyncStatus.synced);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(badgeDot(Colors.green), findsOneWidget);
    });

    testWidgets('signed out shows no badge even with an error status', (tester) async {
      final auth = _FakeAuthProvider()..setSyncStatus(SyncStatus.error);
      await tester.pumpWidget(buildTestWidget(auth: auth));

      expect(badgeDot(Colors.red), findsNothing);
    });
  });

  group('ProfileIcon signed-out sheet', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
    }

    Future<void> tapSignIn(WidgetTester tester) async {
      await tester.tap(find.text('Sign in with Google'));
      await pumpAsync(tester);
      await tester.pumpAndSettle();
    }

    testWidgets('tapping the icon opens the sign-in sheet', (tester) async {
      await tester.pumpWidget(buildTestWidget(auth: _FakeAuthProvider()));
      await openSheet(tester);

      expect(find.text('Sync across devices'), findsOneWidget);
      expect(find.text('Sign in with Google'), findsOneWidget);
    });

    testWidgets('failed sign-in closes the sheet and shows a snackbar', (tester) async {
      final auth = _FakeAuthProvider(signInSucceeds: false);
      final sync = _FakeSyncService(auth);
      await tester.pumpWidget(buildTestWidget(auth: auth, syncService: sync));
      await openSheet(tester);
      await tapSignIn(tester);

      expect(auth.signInCalls, 1);
      expect(find.text('Sync across devices'), findsNothing);
      expect(find.text('Sign-in failed. Please try again.'), findsOneWidget);
      expect(sync.calls, isEmpty);
      expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
    });

    testWidgets('sign-in with migration already done only starts the periodic pull', (tester) async {
      final auth = _FakeAuthProvider();
      final sync = _FakeSyncService(auth, needsMigration: false);
      await tester.pumpWidget(buildTestWidget(auth: auth, syncService: sync));
      await openSheet(tester);
      await tapSignIn(tester);

      expect(sync.calls, ['startPeriodicPull']);
      expect(find.byType(CircleAvatar), findsOneWidget, reason: 'icon now signed in');
    });

    testWidgets('first sign-in with an empty cloud pushes local data', (tester) async {
      final auth = _FakeAuthProvider();
      final sync = _FakeSyncService(auth, needsMigration: true, cloudHasData: false);
      await tester.pumpWidget(buildTestWidget(auth: auth, syncService: sync));
      await openSheet(tester);
      await tapSignIn(tester);

      expect(sync.calls, ['initialMigration', 'startPeriodicPull']);
    });

    testWidgets('first sign-in with cloud data and no local tasks pulls cloud data', (tester) async {
      final auth = _FakeAuthProvider();
      final sync = _FakeSyncService(auth, needsMigration: true, cloudHasData: true);
      await tester.pumpWidget(buildTestWidget(auth: auth, syncService: sync));
      await openSheet(tester);
      await tapSignIn(tester);

      expect(sync.calls, ['replaceLocalWithCloud', 'startPeriodicPull']);
      expect(find.text('Cloud data found'), findsNothing);
    });
  });

  group('ProfileIcon migration choice sheet', () {
    /// Signs in with cloud data present and one local root task, which
    /// leaves the "Cloud data found" sheet open.
    Future<_FakeSyncService> reachChoiceSheet(
      WidgetTester tester, {
      Size screen = const Size(800, 1200),
    }) async {
      // The sheet is not scroll-controlled, so it is capped at 9/16 of the
      // screen height. The default 800x600 test screen is too short for it
      // (see the overflow test below), so the flow tests use a tall screen.
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() => db.insertTask(Task(name: 'Local task')));
      final auth = _FakeAuthProvider();
      final sync = _FakeSyncService(auth, needsMigration: true, cloudHasData: true);
      await tester.pumpWidget(buildTestWidget(auth: auth, syncService: sync));
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in with Google'));
      await pumpAsync(tester);
      await tester.pumpAndSettle();
      return sync;
    }

    testWidgets('both sides having data asks the user and offers three choices', (tester) async {
      final sync = await reachChoiceSheet(tester);

      expect(find.text('Cloud data found'), findsOneWidget);
      expect(find.text('Use cloud data'), findsOneWidget);
      expect(find.text('Merge both'), findsOneWidget);
      expect(find.text("Use this device's data"), findsOneWidget);
      expect(sync.calls, isEmpty, reason: 'nothing runs until the user chooses');
    });

    testWidgets('the choice sheet cannot be dismissed by tapping outside', (tester) async {
      await reachChoiceSheet(tester);

      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();

      expect(find.text('Cloud data found'), findsOneWidget);
    });

    testWidgets('"Use cloud data" replaces local data', (tester) async {
      final sync = await reachChoiceSheet(tester);

      await tester.tap(find.text('Use cloud data'));
      await tester.pumpAndSettle();

      expect(find.text('Cloud data found'), findsNothing);
      expect(sync.calls, ['replaceLocalWithCloud', 'startPeriodicPull']);
    });

    testWidgets('"Merge both" merges', (tester) async {
      final sync = await reachChoiceSheet(tester);

      await tester.tap(find.text('Merge both'));
      await tester.pumpAndSettle();

      expect(find.text('Cloud data found'), findsNothing);
      expect(sync.calls, ['mergeBoth', 'startPeriodicPull']);
    });

    testWidgets('"Use this device\'s data" replaces cloud data', (tester) async {
      final sync = await reachChoiceSheet(tester);

      await tester.tap(find.text("Use this device's data"));
      await tester.pumpAndSettle();

      expect(find.text('Cloud data found'), findsNothing);
      expect(sync.calls, ['replaceCloudWithLocal', 'startPeriodicPull']);
    });

    // BUG (lib/widgets/profile_icon.dart, _showMigrationChoiceDialog): the
    // sheet is opened without isScrollControlled and its Column does not
    // scroll, so it is capped at 9/16 of the screen height. Its content needs
    // about 517 px before any text wraps, which is more than 9/16 of a
    // 411x914 phone screen (514 px). With the test font it overflows by 54 px
    // there. The test records that behaviour; it should expect no exception
    // once the sheet scrolls or is scroll-controlled.
    testWidgets('overflows on a phone-sized screen (411x914) (bug)', (tester) async {
      await reachChoiceSheet(tester, screen: const Size(411, 914));

      expect(find.text('Cloud data found'), findsOneWidget);
      final error = tester.takeException();
      expect(error, isA<FlutterError>());
      expect(error.toString(), contains('overflowed'));
    });
  });

  group('ProfileIcon signed-in sheet', () {
    Future<_FakeSyncService> openSignedInSheet(
      WidgetTester tester, {
      AuthUser? user,
      SyncStatus status = SyncStatus.idle,
      String? error,
    }) async {
      final auth = _FakeAuthProvider(signedIn: true, fakeUser: user ?? someUser)
        ..setSyncStatus(status, error: error);
      final sync = _FakeSyncService(auth);
      await tester.pumpWidget(buildTestWidget(auth: auth, syncService: sync));
      await tester.tap(find.byType(IconButton));
      // The syncing spinner never settles, so pump a fixed time.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      return sync;
    }

    testWidgets('shows name, email and the two actions', (tester) async {
      await openSignedInSheet(tester);

      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('ada@example.com'), findsOneWidget);
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('omits name and email when the account has none', (tester) async {
      await openSignedInSheet(tester, user: AuthUser(uid: 'u'));

      expect(find.text('Ada Lovelace'), findsNothing);
      expect(find.text('ada@example.com'), findsNothing);
      expect(find.text('Sync now'), findsOneWidget);
    });

    for (final (status, error, label, icon) in [
      (SyncStatus.idle, null, 'Not synced yet', Icons.cloud_off),
      (SyncStatus.syncing, null, 'Syncing...', Icons.sync),
      (SyncStatus.synced, null, 'Synced', Icons.cloud_done),
      (SyncStatus.error, 'Sync failed — check your connection',
          'Sync failed — check your connection', Icons.cloud_off),
      (SyncStatus.error, null, 'Sync error', Icons.cloud_off),
    ]) {
      testWidgets('status row for ${status.name}${error == null ? '' : ' with message'} reads "$label"',
          (tester) async {
        await openSignedInSheet(tester, status: status, error: error);

        expect(find.text(label), findsOneWidget);
        final row = find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
        expect(find.descendant(of: row, matching: find.byIcon(icon)), findsOneWidget);
      });
    }

    testWidgets('Sync now closes the sheet and syncs', (tester) async {
      final sync = await openSignedInSheet(tester);

      await tester.tap(find.text('Sync now'));
      await tester.pumpAndSettle();

      expect(find.text('Sync now'), findsNothing);
      expect(sync.calls, ['syncNow']);
    });

    testWidgets('Sign out closes the sheet and the icon returns to signed out', (tester) async {
      final sync = await openSignedInSheet(tester);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('Sign out'), findsNothing);
      expect(sync.calls, ['handleSignOut']);
      expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
    });

    testWidgets('https photo shows in the sheet avatar', (tester) async {
      await openSignedInSheet(
        tester,
        user: AuthUser(uid: 'u', photoUrl: 'https://example.com/me.png'),
      );

      final avatars = tester.widgetList<CircleAvatar>(find.byType(CircleAvatar)).toList();
      expect(avatars, hasLength(2), reason: 'app bar + sheet');
      expect(avatars.last.radius, 32);
      expect(avatars.last.foregroundImage, isA<NetworkImage>());
    });

    // BUG (lib/widgets/profile_icon.dart, signed-in sheet avatar): the sheet
    // sets onForegroundImageError whenever photoUrl is non-null, but sets
    // foregroundImage only for a non-empty http(s) URL. With photoUrl '' (or a
    // non-http URL) CircleAvatar's debug assert
    // `foregroundImage != null || onForegroundImageError == null` fails, so
    // the sheet throws in debug builds. The app bar avatar checks the same
    // condition for both fields and is fine. This test records that behaviour.
    testWidgets('empty photo URL trips the CircleAvatar assert in the sheet (bug)', (tester) async {
      await openSignedInSheet(tester, user: AuthUser(uid: 'u', photoUrl: ''));

      final error = tester.takeException();
      expect(error, isA<AssertionError>());
      expect(error.toString(), contains('onForegroundImageError'));
    });
  });
}
