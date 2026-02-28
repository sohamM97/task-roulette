import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../data/database_helper.dart';
import '../platform/platform_utils.dart'
    if (dart.library.io) '../platform/platform_utils_native.dart' as platform;
import '../providers/task_provider.dart';

class BackupService {
  static Future<void> exportDatabase(BuildContext context) async {
    if (kIsWeb) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup is not available on web'), showCloseIcon: true, persist: false),
        );
      }
      return;
    }

    final dbPath = await DatabaseHelper().getDatabasePath();

    if (!platform.fileExistsSync(dbPath)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No database to export'), showCloseIcon: true, persist: false),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup saved'), showCloseIcon: true, persist: false),
        );
      }
      return;
    } else {
      // Linux desktop: copy to ~/Downloads
      final home = platform.homeDirectory;
      final destPath = p.join(home, 'Downloads', fileName);
      await platform.copyFile(dbPath, destPath);
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup saved to Downloads/$fileName'), showCloseIcon: true, persist: false),
        );
      }
    }
  }

  static Future<void> importDatabase(
    BuildContext context,
    TaskProvider provider,
  ) async {
    if (kIsWeb) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Restore is not available on web'), showCloseIcon: true, persist: false),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), showCloseIcon: true, persist: false),
        );
      }
      return;
    }

    await provider.loadRootTasks();

    if (context.mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup restored'), showCloseIcon: true, persist: false),
      );
    }
  }
}
