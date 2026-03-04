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

    test('at midnight returns today at 8:00 AM', () {
      final now = tz.TZDateTime(tz.local, 2026, 3, 3, 0, 0); // exactly midnight
      final result = NotificationService.nextEightAM(now: now);

      expect(result.day, 3); // today, not tomorrow
      expect(result.hour, 8);
    });

    test('just before midnight returns tomorrow at 8:00 AM', () {
      final now = tz.TZDateTime(tz.local, 2026, 3, 3, 23, 59); // 11:59 PM
      final result = NotificationService.nextEightAM(now: now);

      expect(result.day, 4); // tomorrow
      expect(result.hour, 8);
    });

    test('handles DST spring-forward correctly', () {
      // US Eastern: clocks spring forward on March 8, 2026 (2 AM → 3 AM)
      final now = tz.TZDateTime(tz.local, 2026, 3, 8, 1, 30); // 1:30 AM on spring-forward day
      final result = NotificationService.nextEightAM(now: now);

      expect(result.day, 8); // same day
      expect(result.hour, 8);
      expect(result.minute, 0);
    });

    test('preserves timezone location from input', () {
      final chicago = tz.getLocation('America/Chicago');
      final now = tz.TZDateTime(chicago, 2026, 6, 15, 10, 0);
      final result = NotificationService.nextEightAM(now: now);

      expect(result.location, chicago);
      expect(result.day, 16); // tomorrow (past 8 AM)
      expect(result.hour, 8);
    });
  });

  group('onNotificationTap callback', () {
    tearDown(() {
      NotificationService.onNotificationTap = null;
      NotificationService.pendingTap = false;
    });

    test('starts as null', () {
      expect(NotificationService.onNotificationTap, isNull);
    });

    test('can be set and invoked', () {
      var called = false;
      NotificationService.onNotificationTap = () => called = true;

      NotificationService.onNotificationTap!();
      expect(called, isTrue);
    });

    test('drains pendingTap when callback is registered', () {
      // Simulate a notification tap arriving before UI is ready
      NotificationService.pendingTap = true;

      var called = false;
      // Setting the callback should immediately invoke it and clear the flag
      NotificationService.onNotificationTap = () => called = true;

      expect(called, isTrue);
      expect(NotificationService.pendingTap, isFalse);
    });

    test('does not invoke callback when no pendingTap', () {
      var called = false;
      NotificationService.onNotificationTap = () => called = true;

      // No pending tap → callback should NOT have been invoked by the setter
      expect(called, isFalse);
    });
  });
}
