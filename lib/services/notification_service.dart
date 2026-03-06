import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../platform/platform_utils.dart'
    if (dart.library.io) '../platform/platform_utils_native.dart' as platform;

/// Handles daily 8 AM notification scheduling on Android.
///
/// No-op on web and desktop platforms. Safe to call `init()` on every app
/// launch — uses a fixed notification ID so re-scheduling is idempotent.
class NotificationService {
  NotificationService._();

  static const _notificationId = 0;
  static const _channelId = 'daily_reminder';
  static const _channelName = 'Daily Reminder';

  static final _plugin = FlutterLocalNotificationsPlugin();

  /// Whether a notification tap arrived before the UI callback was registered.
  @visibleForTesting
  static bool pendingTap = false;

  /// Callback invoked when user taps the notification.
  /// Set by AppShell to navigate to Today's 5 tab.
  ///
  /// If a tap arrived during init (cold start from notification), the setter
  /// invokes the callback immediately so the navigate intent isn't lost.
  static void Function()? _onNotificationTap;

  static void Function()? get onNotificationTap => _onNotificationTap;

  static set onNotificationTap(void Function()? cb) {
    _onNotificationTap = cb;
    if (cb != null && pendingTap) {
      pendingTap = false;
      cb();
    }
  }

  /// Initialize notification scheduling. Android-only; no-op elsewhere.
  static Future<void> init() async {
    if (kIsWeb || !platform.isAndroidPlatform) return;

    // Set up timezone database and resolve device's local timezone
    tz.initializeTimeZones();
    final timezoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timezoneName));

    // Initialize the plugin with Android settings
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (_) {
        if (_onNotificationTap != null) {
          _onNotificationTap!();
        } else {
          pendingTap = true;
        }
      },
    );

    // Request POST_NOTIFICATIONS permission (Android 13+; auto-granted on older)
    final androidPlugin =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final granted =
        await androidPlugin?.requestNotificationsPermission() ?? false;

    if (granted) {
      try {
        await _scheduleDailyNotification();
      } catch (_) {
        // Non-fatal — app works fine without notifications
      }
    }
  }

  static Future<void> _scheduleDailyNotification() async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Daily reminder to check your tasks',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.zonedSchedule(
      _notificationId,
      'Good morning!',
      '5 tasks are lined up for your day. Tap to see them.',
      nextEightAM(),
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  /// Returns the next occurrence of 8:00 AM in the device's local timezone.
  ///
  /// If it's already past 8 AM today, returns tomorrow at 8 AM.
  @visibleForTesting
  static tz.TZDateTime nextEightAM({tz.TZDateTime? now}) {
    final current = now ?? tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      current.location,
      current.year,
      current.month,
      current.day,
      8,
    );

    if (scheduled.isBefore(current)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    return scheduled;
  }
}
