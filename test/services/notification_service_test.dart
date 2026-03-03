import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'package:task_roulette/services/notification_service.dart';

void main() {
  setUpAll(() {
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('America/New_York'));
  });

  group('nextEightAM', () {
    test('before 8 AM returns today at 8:00 AM', () {
      final now = tz.TZDateTime(tz.local, 2026, 3, 3, 6, 30); // 6:30 AM
      final result = NotificationService.nextEightAM(now: now);

      expect(result.year, 2026);
      expect(result.month, 3);
      expect(result.day, 3);
      expect(result.hour, 8);
      expect(result.minute, 0);
      expect(result.second, 0);
    });

    test('after 8 AM returns tomorrow at 8:00 AM', () {
      final now = tz.TZDateTime(tz.local, 2026, 3, 3, 10, 0); // 10:00 AM
      final result = NotificationService.nextEightAM(now: now);

      expect(result.year, 2026);
      expect(result.month, 3);
      expect(result.day, 4); // tomorrow
      expect(result.hour, 8);
      expect(result.minute, 0);
      expect(result.second, 0);
    });

    test('at exactly 8:00 AM returns same time', () {
      final now = tz.TZDateTime(tz.local, 2026, 3, 3, 8, 0); // exactly 8 AM
      final result = NotificationService.nextEightAM(now: now);

      expect(result.year, 2026);
      expect(result.month, 3);
      expect(result.day, 3); // today — not before, so no rollover
      expect(result.hour, 8);
      expect(result.minute, 0);
    });

    test('rolls over month boundary correctly', () {
      final now = tz.TZDateTime(tz.local, 2026, 3, 31, 22, 0); // 10 PM on March 31
      final result = NotificationService.nextEightAM(now: now);

      expect(result.year, 2026);
      expect(result.month, 4);
      expect(result.day, 1); // rolls to April 1
      expect(result.hour, 8);
      expect(result.minute, 0);
    });

    test('rolls over year boundary correctly', () {
      final now = tz.TZDateTime(tz.local, 2026, 12, 31, 9, 0); // 9 AM on Dec 31
      final result = NotificationService.nextEightAM(now: now);

      expect(result.year, 2027);
      expect(result.month, 1);
      expect(result.day, 1); // rolls to Jan 1
      expect(result.hour, 8);
      expect(result.minute, 0);
    });
  });
}
