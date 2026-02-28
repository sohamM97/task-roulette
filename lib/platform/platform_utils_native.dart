// Native platform utilities using dart:io.
// This file is used when dart:io is available (Linux, Android, etc.).
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

bool get isDesktopPlatform => Platform.isLinux || Platform.isWindows;

bool get isAndroidPlatform => Platform.isAndroid;

Future<String> resolveDatabasePath() async {
  final appDir = await getApplicationSupportDirectory();
  return p.join(appDir.path, 'task_roulette.db');
}

bool fileExistsSync(String path) => File(path).existsSync();

Future<bool> fileExists(String path) async => File(path).exists();

Future<void> copyFile(String src, String dst) async {
  await File(src).copy(dst);
}

Future<int> fileSize(String path) async => File(path).length();

Future<Uint8List> readFileBytes(String path) async => File(path).readAsBytes();

Future<void> openUrlExternally(String url) async {
  await Process.start('xdg-open', [url]);
}

String get homeDirectory => Platform.environment['HOME'] ?? '.';
