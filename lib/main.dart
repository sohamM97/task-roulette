import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'platform/platform_utils.dart'
    if (dart.library.io) 'platform/platform_utils_native.dart' as platform;
import 'providers/auth_provider.dart';
import 'providers/progression_provider.dart';
import 'providers/task_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/starred_screen.dart';
import 'screens/stats_screen.dart';
import 'screens/task_list_screen.dart';
import 'screens/todays_five_screen.dart';
import 'services/notification_service.dart';
import 'services/sync_service.dart';
import 'utils/display_utils.dart' show debugLog;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    databaseFactory = databaseFactoryFfiWeb;
  } else if (platform.isDesktopPlatform) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await NotificationService.init();
  runApp(const TaskRouletteApp());
}

class TaskRouletteApp extends StatelessWidget {
  const TaskRouletteApp({super.key});

  static ThemeData _buildTheme(Brightness brightness) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: brightness,
      ),
      useMaterial3: true,
      cardTheme: CardThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TaskProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ProgressionProvider()),
        ProxyProvider<AuthProvider, SyncService>(
          update: (_, auth, previous) => previous ?? SyncService(auth),
          dispose: (_, sync) => sync.dispose(),
        ),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return MaterialApp(
            title: 'TaskRoulette',
            debugShowCheckedModeBanner: false,
            theme: _buildTheme(Brightness.light),
            darkTheme: _buildTheme(Brightness.dark),
            themeMode: themeProvider.themeMode,
            home: const AppShell(),
          );
        },
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 0;
  final _todaysFiveKey = GlobalKey<TodaysFiveScreenState>();
  final _starredKey = GlobalKey<StarredScreenState>();
  final _taskListKey = GlobalKey<TaskListScreenState>();
  final _statsKey = GlobalKey<StatsScreenState>();
  final _pageController = PageController();

  @override
  void initState() {
    super.initState();
    NotificationService.onNotificationTap = _navigateToToday;
    _initAuth();
  }

  void _navigateToToday() {
    if (!mounted) return;
    _todaysFiveKey.currentState?.refreshSnapshots();
    _pageController.animateToPage(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _initAuth() async {
    final authProvider = context.read<AuthProvider>();
    final syncService = context.read<SyncService>();
    final taskProvider = context.read<TaskProvider>();
    final progressionProvider = context.read<ProgressionProvider>();

    // Load root tasks early so TaskListScreen doesn't need to call it
    // in initState (which would race with navigateToTask from Today's 5).
    taskProvider.loadRootTasks();

    // Initialize progression system (runs backfill on first launch after v24)
    progressionProvider.init();

    // Wire up mutation callback so sync triggers on local changes
    taskProvider.onMutation = () => syncService.schedulePush();

    // Wire up XP callback so progression updates on task actions from All Tasks.
    // Today's 5 screen handles its own XP awards (it has pinned/Today's 5 context).
    taskProvider.onXpEarned = (eventType, xpAmount, taskId, {isHighPriority = false}) {
      progressionProvider.awardXpWithBonuses(
        eventType: eventType,
        baseXp: xpAmount,
        taskId: taskId ?? 0,
        isInTodaysFive: false, // All Tasks context — never in Today's 5
        isHighPriority: isHighPriority,
        isPinned: false,
      );
    };

    // Wire up data-changed callback so UI refreshes on remote changes
    syncService.onDataChanged = () {
      if (mounted) taskProvider.refreshCurrentView();
    };

    try {
      await authProvider.init();
      if (authProvider.isSignedIn && mounted) {
        final needsMigration = await syncService.needsInitialMigration();
        if (needsMigration) {
          await syncService.initialMigration();
        }
        syncService.startPeriodicPull();
      }
    } catch (e) {
      // SEC-fix LOW-21: use debugLog to prevent leaking auth/sync error
      // details (keyring paths, Firestore errors) to logcat in release.
      debugLog('Failed to initialize auth/sync: $e');
    }
  }

  @override
  void dispose() {
    NotificationService.onNotificationTap = null;
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        physics: const _LessAggressivePagePhysics(),
        onPageChanged: (index) {
          if (index == 0) {
            _todaysFiveKey.currentState?.refreshSnapshots();
          } else if (index == 2) {
            _taskListKey.currentState?.loadTodaysFiveIds();
          } else if (index == 3) {
            _statsKey.currentState?.refresh();
          }
          setState(() {
            _currentIndex = index;
          });
        },
        children: [
          TodaysFiveScreen(
            key: _todaysFiveKey,
            onNavigateToTask: (task) async {
              await context.read<TaskProvider>().navigateToTask(task);
              if (!mounted) return;
              _pageController.animateToPage(
                2,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            },
          ),
          StarredScreen(
            key: _starredKey,
            onNavigateToTask: (task) async {
              await context.read<TaskProvider>().navigateToTask(task);
              if (!mounted) return;
              _pageController.animateToPage(
                2,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            },
          ),
          TaskListScreen(key: _taskListKey),
          StatsScreen(key: _statsKey),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          // Refresh happens in onPageChanged — no need to duplicate here.
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.star_outline),
            selectedIcon: Icon(Icons.star),
            label: 'Starred',
          ),
          NavigationDestination(
            icon: Icon(Icons.list_outlined),
            selectedIcon: Icon(Icons.list),
            label: 'All Tasks',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Stats',
          ),
        ],
      ),
    );
  }
}

/// PageScrollPhysics with a higher drag start threshold so small
/// horizontal movements (common with thumb taps) don't steal taps
/// from child widgets like task cards.
class _LessAggressivePagePhysics extends PageScrollPhysics {
  const _LessAggressivePagePhysics({super.parent});

  @override
  _LessAggressivePagePhysics applyTo(ScrollPhysics? ancestor) {
    return _LessAggressivePagePhysics(parent: buildParent(ancestor));
  }

  @override
  double get dragStartDistanceMotionThreshold => 24.0;
}
