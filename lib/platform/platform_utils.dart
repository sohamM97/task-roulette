// Web/default platform utilities.
// This file is used when dart:io is not available (i.e., web).
import 'dart:typed_data';

bool get isDesktopPlatform => false;

bool get isAndroidPlatform => false;

Future<String> resolveDatabasePath() async => 'task_roulette.db';

bool fileExistsSync(String path) => false;

Future<bool> fileExists(String path) async => false;

Future<void> copyFile(String src, String dst) async {}

Future<int> fileSize(String path) async => 0;

Future<Uint8List> readFileBytes(String path) async => Uint8List(0);

Future<void> openUrlExternally(String url) async {}

String get homeDirectory => '';
