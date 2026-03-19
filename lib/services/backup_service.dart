import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../data/database_helper.dart';
import '../platform/platform_utils.dart'
    if (dart.library.io) '../platform/platform_utils_native.dart' as platform;
import '../providers/task_provider.dart';
import '../utils/display_utils.dart' show showInfoSnackBar;

class BackupService {
  static Future<void> exportDatabase(BuildContext context) async {
    if (kIsWeb) {
      if (context.mounted) {
        showInfoSnackBar(context, 'Backup is not available on web');
      }
      return;
    }

    final dbPath = await DatabaseHelper().getDatabasePath();

    if (!platform.fileExistsSync(dbPath)) {
      if (context.mounted) {
        showInfoSnackBar(context, 'No database to export');
      }
      return;
    }

    final date = DateTime.now().toIso8601String().substring(0, 10);
    final fileName = 'task_roulette_backup_$date.db';

    if (platform.isAndroidPlatform) {
      // Use SAF save dialog — direct file copy to Downloads fails on Android 11+.
      final bytes = await platform.readFileBytes(dbPath);
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save backup',
        fileName: fileName,
        bytes: bytes,
      );
      if (result != null && context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        showInfoSnackBar(context, 'Backup saved');
      }
      return;
    } else {
      // Linux desktop: copy to ~/Downloads
      final home = platform.homeDirectory;
      final destPath = p.join(home, 'Downloads', fileName);
      await platform.copyFile(dbPath, destPath);
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        showInfoSnackBar(context, 'Backup saved to Downloads/$fileName');
      }
    }
  }

  static Future<void> importDatabase(
    BuildContext context,
    TaskProvider provider,
  ) async {
    if (kIsWeb) {
      if (context.mounted) {
        showInfoSnackBar(context, 'Restore is not available on web');
      }
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
    );

    if (result == null || result.files.single.path == null) return;
    final pickedPath = result.files.single.path!;

    if (!context.mounted) return;

    // Show warning dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore backup?'),
        content: const Text(
          'This will replace ALL your current tasks and cannot be undone. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await DatabaseHelper().importDatabase(pickedPath);
    } on FormatException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        showInfoSnackBar(context, e.message);
      }
      return;
    }

    await provider.loadRootTasks();

    if (context.mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      showInfoSnackBar(context, 'Backup restored');
    }
  }
}
