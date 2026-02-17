import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'providers/auth_provider.dart';
import 'providers/task_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/task_list_screen.dart';
import 'screens/todays_five_screen.dart';
import 'services/sync_service.dart';

void main() {
  if (!kIsWeb && (Platform.isLinux || Platform.isWindows)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const TaskRouletteApp());
}

class TaskRouletteApp extends StatelessWidget {
  const TaskRouletteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TaskProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
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
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
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
            ),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.deepPurple,
                brightness: Brightness.dark,
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
            ),
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
  final _pageController = PageController();

  @override
  void initState() {
    super.initState();
    _initAuth();
  }

  Future<void> _initAuth() async {
    final authProvider = context.read<AuthProvider>();
    final syncService = context.read<SyncService>();
    final taskProvider = context.read<TaskProvider>();

    // Wire up mutation callback so sync triggers on local changes
    taskProvider.onMutation = () => syncService.schedulePush();

    // Wire up data-changed callback so UI refreshes on remote changes
    syncService.onDataChanged = () {
      if (mounted) taskProvider.loadRootTasks();
    };

    await authProvider.init();
    if (authProvider.isSignedIn && mounted) {
      final needsMigration = await syncService.needsInitialMigration();
      if (needsMigration) {
        await syncService.initialMigration();
      }
      syncService.startPeriodicPull();
    }
  }

  @override
  void dispose() {
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
              _pageController.animateToPage(
                1,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            },
          ),
          const TaskListScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          if (index == 0) {
            _todaysFiveKey.currentState?.refreshSnapshots();
          }
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
            icon: Icon(Icons.list_outlined),
            selectedIcon: Icon(Icons.list),
            label: 'All Tasks',
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
