import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../data/database_helper.dart';
import '../providers/task_provider.dart';

class BackupService {
  static Future<void> exportDatabase(BuildContext context) async {
    final dbPath = await DatabaseHelper().getDatabasePath();
    final dbFile = File(dbPath);

    if (!dbFile.existsSync()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No database to export')),
        );
      }
      return;
    }

    // Copy to Downloads with a dated filename
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final fileName = 'task_roulette_backup_$date.db';

    final downloadsDir = Directory('/storage/emulated/0/Download');
    final String destPath;
    if (downloadsDir.existsSync()) {
      // Android
      destPath = p.join(downloadsDir.path, fileName);
    } else {
      // Linux desktop fallback: ~/Downloads
      final home = Platform.environment['HOME'] ?? '.';
      destPath = p.join(home, 'Downloads', fileName);
    }

    await dbFile.copy(destPath);

    // Open share sheet (Android only — not supported on Linux desktop)
    if (Platform.isAndroid) {
      await Share.shareXFiles([XFile(destPath)]);
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup saved to Downloads/$fileName')),
      );
    }
  }

  static Future<void> importDatabase(
    BuildContext context,
    TaskProvider provider,
  ) async {
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
          SnackBar(content: Text(e.message)),
        );
      }
      return;
    }

    await provider.loadRootTasks();

    if (context.mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup restored')),
      );
    }
  }
}
