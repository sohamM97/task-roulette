import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/task_provider.dart';
import 'package:task_roulette/services/backup_service.dart';

import '../helpers/async_pump.dart';

/// Returns a preset result from `pickFiles` and records how it was called.
class _FakeFilePicker extends FilePicker {
  FilePickerResult? result;
  int pickCalls = 0;
  FileType? lastType;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    pickCalls++;
    lastType = type;
    return result;
  }
}

FilePickerResult _picked(String? path) => FilePickerResult([
      PlatformFile(path: path, name: 'backup.db', size: 0),
    ]);

/// A [File] that sends copies aimed at `$HOME/Downloads` to [downloadsDir],
/// so the Linux export branch never writes into the real home directory.
class _RedirectingFile implements File {
  _RedirectingFile(this.path, this.downloadsDir);

  @override
  final String path;
  final String downloadsDir;

  // Files made in the root zone skip the IOOverrides below.
  File get _real => Zone.root.run(() => File(path));

  @override
  bool existsSync() => _real.existsSync();

  @override
  Future<Uint8List> readAsBytes() => _real.readAsBytes();

  @override
  Future<File> copy(String newPath) {
    final realDownloads = p.join(Platform.environment['HOME'] ?? '.', 'Downloads');
    final target = p.isWithin(realDownloads, newPath)
        ? p.join(downloadsDir, p.relative(newPath, from: realDownloads))
        : newPath;
    // Only the File is made in the root zone. The copy runs in the caller's
    // zone, so its error reaches the caller's await rather than the root
    // zone's uncaught-error handler.
    return _real.copy(target);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('_RedirectingFile: ${invocation.memberName}');
}

/// Runs [body] with every `File(path)` replaced by a [_RedirectingFile].
Future<T> _withDownloadsAt<T>(String downloadsDir, Future<T> Function() body) =>
    IOOverrides.runZoned(
      body,
      createFile: (path) => _RedirectingFile(path, downloadsDir),
    );

String _todayFileName() =>
    'task_roulette_backup_${DateTime.now().toIso8601String().substring(0, 10)}.db';

/// A screen with one button per backup action, so tests get a real
/// BuildContext under a ScaffoldMessenger.
Widget _host({required TaskProvider provider, required List<Future<void>> calls}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Column(
          children: [
            TextButton(
              onPressed: () => calls.add(BackupService.exportDatabase(context)),
              child: const Text('export'),
            ),
            TextButton(
              onPressed: () =>
                  calls.add(BackupService.importDatabase(context, provider)),
              child: const Text('import'),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  late Directory tmp;
  late String dbPath;
  late _FakeFilePicker picker;
  late TaskProvider provider;
  late List<Future<void>> calls;
  final db = DatabaseHelper();

  setUpAll(() {
    sqfliteFfiInit();
    // Widget tests run in FakeAsync; the isolate-based factory hangs there.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('backup_service_test_');
    dbPath = p.join(tmp.path, 'task_roulette.db');
    DatabaseHelper.testDatabasePath = dbPath;
    await db.reset();
    picker = _FakeFilePicker();
    FilePicker.platform = picker;
    provider = TaskProvider();
    calls = [];
  });

  tearDown(() async {
    await db.reset();
    DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
    tmp.deleteSync(recursive: true);
  });

  group('exportDatabase (Linux desktop)', () {
    late Directory downloads;

    setUp(() {
      downloads = Directory(p.join(tmp.path, 'Downloads'))..createSync();
    });

    Future<void> export(WidgetTester tester) async {
      await tester.pumpWidget(_host(provider: provider, calls: calls));
      await tester.runAsync(() => _withDownloadsAt(downloads.path, () async {
            await tester.tap(find.text('export'));
            await calls.single;
          }));
      await tester.pump();
    }

    testWidgets('copies the database to Downloads under a dated file name',
        (tester) async {
      File(dbPath).writeAsBytesSync([1, 2, 3, 4]);

      await export(tester);

      final saved = File(p.join(downloads.path, _todayFileName()));
      expect(saved.existsSync(), isTrue);
      expect(saved.readAsBytesSync(), [1, 2, 3, 4]);
      expect(find.text('Backup saved to Downloads/${_todayFileName()}'),
          findsOneWidget);
      // The source database is left in place.
      expect(File(dbPath).readAsBytesSync(), [1, 2, 3, 4]);
    });

    testWidgets('a second export on the same day overwrites the first',
        (tester) async {
      File(p.join(downloads.path, _todayFileName()))
          .writeAsBytesSync([9, 9, 9]);
      File(dbPath).writeAsBytesSync([5, 6]);

      await export(tester);

      expect(File(p.join(downloads.path, _todayFileName())).readAsBytesSync(),
          [5, 6]);
    });

    testWidgets('shows "No database to export" when the file is missing',
        (tester) async {
      await export(tester);

      expect(find.text('No database to export'), findsOneWidget);
      expect(downloads.listSync(), isEmpty);
    });

    testWidgets(
        'throws FileSystemException with no snackbar when Downloads is missing',
        (tester) async {
      // Documents current behaviour: the Linux copy is not wrapped in a
      // try/catch, so a missing ~/Downloads surfaces as an uncaught error
      // from the button handler instead of a message to the user.
      File(dbPath).writeAsBytesSync([1]);
      downloads.deleteSync();
      await tester.pumpWidget(_host(provider: provider, calls: calls));

      Object? error;
      await tester.runAsync(() => _withDownloadsAt(downloads.path, () async {
            await tester.tap(find.text('export'));
            try {
              await calls.single;
            } catch (e) {
              error = e;
            }
          }));
      await tester.pump();

      expect(error, isA<FileSystemException>());
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('importDatabase', () {
    late String backupPath;

    /// Builds a valid backup holding one task named 'From backup', then
    /// starts a fresh live database holding one task named 'Current'.
    Future<void> seed(WidgetTester tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'From backup'));
        await db.reset();
        backupPath = p.join(tmp.path, 'picked.db');
        File(dbPath).copySync(backupPath);
        File(dbPath).deleteSync();
        await db.insertTask(Task(name: 'Current'));
        await provider.loadRootTasks();
      });
    }

    Future<List<String>> liveTaskNames(WidgetTester tester) async {
      final tasks = await tester.runAsync(() => db.getAllTasks());
      return tasks!.map((t) => t.name).toList();
    }

    Future<void> startImport(WidgetTester tester) async {
      await tester.pumpWidget(_host(provider: provider, calls: calls));
      await tester.tap(find.text('import'));
      await pumpAsync(tester, rounds: 3);
    }

    testWidgets('does nothing when the picker is cancelled', (tester) async {
      await seed(tester);
      picker.result = null;

      await startImport(tester);

      expect(picker.pickCalls, 1);
      expect(picker.lastType, FileType.any);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(await liveTaskNames(tester), ['Current']);
    });

    testWidgets('does nothing when the picked file has no path',
        (tester) async {
      await seed(tester);
      picker.result = _picked(null);

      await startImport(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(await liveTaskNames(tester), ['Current']);
    });

    testWidgets('asks for confirmation before replacing data', (tester) async {
      await seed(tester);
      picker.result = _picked(backupPath);

      await startImport(tester);

      expect(find.text('Restore backup?'), findsOneWidget);
      expect(
          find.text('This will replace ALL your current tasks and cannot be '
              'undone. Continue?'),
          findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
    });

    testWidgets('Cancel leaves the database untouched', (tester) async {
      await seed(tester);
      picker.result = _picked(backupPath);

      await startImport(tester);
      await tester.tap(find.text('Cancel'));
      await pumpAsync(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(await liveTaskNames(tester), ['Current']);
      expect(File('$dbPath.bak').existsSync(), isFalse);
    });

    testWidgets('dismissing the dialog by tapping outside also cancels',
        (tester) async {
      await seed(tester);
      picker.result = _picked(backupPath);

      await startImport(tester);
      await tester.tapAt(const Offset(5, 5));
      await pumpAsync(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(await liveTaskNames(tester), ['Current']);
    });

    testWidgets('Restore replaces the data and reloads the provider',
        (tester) async {
      await seed(tester);
      picker.result = _picked(backupPath);
      expect(provider.tasks.map((t) => t.name), ['Current']);

      await startImport(tester);
      await tester.tap(find.text('Restore'));
      await pumpAsync(tester);

      expect(find.text('Backup restored'), findsOneWidget);
      expect(await liveTaskNames(tester), ['From backup']);
      expect(provider.tasks.map((t) => t.name), ['From backup']);
      // The database it replaced is kept beside it as a safety copy.
      expect(File('$dbPath.bak').existsSync(), isTrue);

      // The restore reopened the database inside the widget test's fake
      // zone. Closing it from tearDown, outside that zone, never completes,
      // so close it here.
      await tester.runAsync(() => db.reset());
    });

    testWidgets('an invalid file shows the validation message and keeps data',
        (tester) async {
      await seed(tester);
      final bogus = File(p.join(tmp.path, 'notes.txt'))
        ..writeAsStringSync('not a database');
      picker.result = _picked(bogus.path);

      await startImport(tester);
      await tester.tap(find.text('Restore'));
      await pumpAsync(tester);

      expect(find.text('Not a valid database file'), findsOneWidget);
      expect(find.text('Backup restored'), findsNothing);
      expect(await liveTaskNames(tester), ['Current']);
      expect(provider.tasks.map((t) => t.name), ['Current']);
    });
  });
}
