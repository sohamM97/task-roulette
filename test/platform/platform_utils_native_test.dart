import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/platform/platform_utils_native.dart' as platform;

void main() {
  group('platform checks', () {
    test('isDesktopPlatform is true on Linux', () {
      // Tests run on Linux, so this should be true
      expect(platform.isDesktopPlatform, Platform.isLinux || Platform.isWindows);
    });

    test('isAndroidPlatform is false on Linux', () {
      expect(platform.isAndroidPlatform, false);
    });

    test('homeDirectory returns HOME env var', () {
      expect(platform.homeDirectory, Platform.environment['HOME'] ?? '.');
      expect(platform.homeDirectory, isNotEmpty);
    });
  });

  group('file operations', () {
    late String tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('platform_test_').path;
    });

    tearDown(() {
      final dir = Directory(tempDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('fileExistsSync returns true for existing file', () {
      final path = '$tempDir/test.txt';
      File(path).writeAsStringSync('hello');
      expect(platform.fileExistsSync(path), true);
    });

    test('fileExistsSync returns false for non-existing file', () {
      expect(platform.fileExistsSync('$tempDir/nope.txt'), false);
    });

    test('fileExists async returns true for existing file', () async {
      final path = '$tempDir/test.txt';
      File(path).writeAsStringSync('hello');
      expect(await platform.fileExists(path), true);
    });

    test('fileExists async returns false for non-existing file', () async {
      expect(await platform.fileExists('$tempDir/nope.txt'), false);
    });

    test('copyFile copies file contents', () async {
      final src = '$tempDir/src.txt';
      final dst = '$tempDir/dst.txt';
      File(src).writeAsStringSync('test data');
      await platform.copyFile(src, dst);
      expect(File(dst).readAsStringSync(), 'test data');
    });

    test('fileSize returns correct byte count', () async {
      final path = '$tempDir/sized.txt';
      File(path).writeAsBytesSync([1, 2, 3, 4, 5]);
      expect(await platform.fileSize(path), 5);
    });

    test('readFileBytes returns file contents as Uint8List', () async {
      final path = '$tempDir/bytes.bin';
      final data = Uint8List.fromList([10, 20, 30]);
      File(path).writeAsBytesSync(data);
      final result = await platform.readFileBytes(path);
      expect(result, data);
    });
  });
}
