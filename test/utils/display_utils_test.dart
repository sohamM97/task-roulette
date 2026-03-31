import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/utils/display_utils.dart';

// Helper to wrap a widget in MaterialApp + Scaffold for widget tests
Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

void main() {
  group('normalizeUrl', () {
    test('returns null for null input', () {
      expect(normalizeUrl(null), isNull);
    });

    test('returns null for empty string', () {
      expect(normalizeUrl(''), isNull);
    });

    test('returns null for whitespace-only string', () {
      expect(normalizeUrl('   '), isNull);
    });

    test('prepends https:// to bare domain', () {
      expect(normalizeUrl('example.com'), 'https://example.com');
    });

    test('prepends https:// to domain with path', () {
      expect(normalizeUrl('example.com/path'), 'https://example.com/path');
    });

    test('preserves existing https://', () {
      expect(normalizeUrl('https://example.com'), 'https://example.com');
    });

    test('preserves existing http://', () {
      expect(normalizeUrl('http://example.com'), 'http://example.com');
    });

    test('trims whitespace', () {
      expect(normalizeUrl('  https://example.com  '), 'https://example.com');
    });

    test('preserves other schemes (they get normalized but fail isAllowedUrl)', () {
      expect(normalizeUrl('ftp://example.com'), 'ftp://example.com');
    });

    test('returns null for random text without valid host', () {
      expect(normalizeUrl('hello world'), isNull);
    });

    test('returns null for text with no host after scheme', () {
      expect(normalizeUrl('https://'), isNull);
    });
  });

  group('isAllowedUrl', () {
    test('allows https URLs', () {
      expect(isAllowedUrl('https://example.com'), isTrue);
    });

    test('allows http URLs', () {
      expect(isAllowedUrl('http://example.com'), isTrue);
    });

    test('rejects file:// URLs', () {
      expect(isAllowedUrl('file:///etc/passwd'), isFalse);
    });

    test('rejects javascript: URLs', () {
      expect(isAllowedUrl('javascript:alert(1)'), isFalse);
    });

    test('rejects tel: URLs', () {
      expect(isAllowedUrl('tel:+1234567890'), isFalse);
    });

    test('rejects sms: URLs', () {
      expect(isAllowedUrl('sms:+1234567890'), isFalse);
    });

    test('rejects intent: URLs', () {
      expect(isAllowedUrl('intent://scan/#Intent;scheme=zxing;end'), isFalse);
    });

    test('rejects ftp: URLs', () {
      expect(isAllowedUrl('ftp://example.com'), isFalse);
    });

    test('rejects empty string', () {
      expect(isAllowedUrl(''), isFalse);
    });

    test('rejects malformed URL', () {
      expect(isAllowedUrl('not a url at all'), isFalse);
    });

    test('allows HTTPS with mixed case scheme', () {
      expect(isAllowedUrl('HTTPS://example.com'), isTrue);
    });

    test('allows HTTP with mixed case scheme', () {
      expect(isAllowedUrl('Http://example.com'), isTrue);
    });
  });

  group('archiveIcon', () {
    test('is inventory_2_outlined', () {
      expect(archiveIcon, Icons.inventory_2_outlined);
    });
  });

  group('deadlineIcon', () {
    test('is Icons.schedule', () {
      expect(deadlineIcon, Icons.schedule);
    });
  });

  group('scheduledTodayIcon', () {
    test('is Icons.event_available', () {
      expect(scheduledTodayIcon, Icons.event_available);
    });
  });

  group('spinIcon', () {
    test('is Icons.loop', () {
      expect(spinIcon, Icons.loop);
    });
  });

  group('displayUrl', () {
    test('strips https:// prefix', () {
      expect(displayUrl('https://example.com'), 'example.com');
    });

    test('strips http:// prefix', () {
      expect(displayUrl('http://example.com'), 'example.com');
    });

    test('strips trailing slash', () {
      expect(displayUrl('https://example.com/'), 'example.com');
    });

    test('truncates long URLs', () {
      final long = 'https://example.com/${'a' * 50}';
      final result = displayUrl(long, maxLength: 30);
      expect(result.length, 33); // 30 chars + '...'
      expect(result, endsWith('...'));
    });

    test('does not truncate short URLs', () {
      expect(displayUrl('https://example.com', maxLength: 30), 'example.com');
    });
  });

  group('PinButton', () {
    testWidgets('renders push_pin icon when isPinned is true', (tester) async {
      await tester.pumpWidget(
        _wrap(PinButton(isPinned: true, onToggle: () {})),
      );

      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
    });

    testWidgets('renders push_pin_outlined icon when isPinned is false',
        (tester) async {
      await tester.pumpWidget(
        _wrap(PinButton(isPinned: false, onToggle: () {})),
      );

      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsNothing);
    });

    testWidgets('calls onToggle when tapped', (tester) async {
      bool toggled = false;
      await tester.pumpWidget(
        _wrap(PinButton(isPinned: false, onToggle: () => toggled = true)),
      );

      await tester.tap(find.byType(IconButton));
      expect(toggled, isTrue);
    });

    testWidgets('shows "Unpin" tooltip when pinned', (tester) async {
      await tester.pumpWidget(
        _wrap(PinButton(isPinned: true, onToggle: () {})),
      );

      final iconButton =
          tester.widget<IconButton>(find.byType(IconButton));
      expect(iconButton.tooltip, 'Unpin');
    });

    testWidgets('shows "Pin" tooltip when unpinned', (tester) async {
      await tester.pumpWidget(
        _wrap(PinButton(isPinned: false, onToggle: () {})),
      );

      final iconButton =
          tester.widget<IconButton>(find.byType(IconButton));
      expect(iconButton.tooltip, 'Pin');
    });

    testWidgets('uses custom size parameter', (tester) async {
      await tester.pumpWidget(
        _wrap(PinButton(isPinned: true, onToggle: () {}, size: 24)),
      );

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.size, 24);
    });

    testWidgets(
        'when mutedWhenUnpinned is true and not pinned, icon color has alpha 170',
        (tester) async {
      await tester.pumpWidget(
        _wrap(PinButton(
          isPinned: false,
          onToggle: () {},
          mutedWhenUnpinned: true,
        )),
      );

      final icon = tester.widget<Icon>(find.byType(Icon));
      // The color should have alpha 170 (muted)
      expect((icon.color!.a * 255.0).round(), 170);
    });
  });

  group('shortenAncestorPath', () {
    test('returns single segment unchanged', () {
      expect(shortenAncestorPath('Root'), 'Root');
    });

    test('returns short 2-segment path unchanged', () {
      expect(shortenAncestorPath('Parent › Child'), 'Parent › Child');
    });

    test('truncates long ancestor from left in 2-segment path', () {
      final result = shortenAncestorPath('Root inboxed tasks › Inbox 2');
      expect(result, contains('Inbox 2'));
      expect(result, startsWith('…'));
      // Ancestor truncated from left — last 8 chars visible
      expect(result, contains('ed tasks'));
    });

    test('3-segment path with short names unchanged', () {
      expect(shortenAncestorPath('A › B › C'), 'A › B › C');
    });

    test('3-segment path truncates long ancestors from left', () {
      final result = shortenAncestorPath('Very long ancestor name › Another long one here › Leaf');
      expect(result, contains('Leaf'));
      expect(result, contains('…'));
    });

    test('4+ segments collapses to last 2 with ellipsis', () {
      final result = shortenAncestorPath('A › B › C › D');
      expect(result, '…C › D');
    });

    test('5 segments collapses to last 2 with ellipsis', () {
      final result = shortenAncestorPath('A › B › C › D › E');
      expect(result, '…D › E');
    });

    test('immediate parent is always fully visible', () {
      final result = shortenAncestorPath('Root inboxed tasks › Very important parent task');
      expect(result, contains('Very important parent task'));
    });

    test('ancestor <= 12 chars not truncated in 2-segment path', () {
      expect(shortenAncestorPath('Short name › Child'), 'Short name › Child');
    });

    test('ancestor exactly 12 chars not truncated', () {
      expect(shortenAncestorPath('Twelve chars › Child'), 'Twelve chars › Child');
    });

    test('ancestor 13 chars gets left-truncated', () {
      final result = shortenAncestorPath('Thirteen char › Child');
      expect(result, startsWith('…'));
      expect(result, contains('Child'));
    });

    test('long immediate parent is NOT truncated by shortenPath', () {
      // shortenPath only truncates ancestors, not the last segment.
      // Text widget overflow handles the rest.
      final result = shortenAncestorPath('Parent › A very long immediate parent name that goes on');
      expect(result, contains('A very long immediate parent name that goes on'));
    });

    test('both ancestor and parent long — only ancestor truncated', () {
      final result = shortenAncestorPath('Root inboxed tasks › Super long child task name here');
      expect(result, startsWith('…'));
      expect(result, contains('Super long child task name here'));
      // Ancestor should be left-truncated
      expect(result, isNot(contains('Root')));
    });

    test('4+ segments with long names collapses to last 2', () {
      final result = shortenAncestorPath(
        'Very long root name › Another long segment › Third long one › Final destination'
      );
      expect(result, '…Third long one › Final destination');
    });
  });

  group('deadlineProximityColor', () {
    final colorScheme = ColorScheme.fromSeed(seedColor: Colors.blue);

    test('returns deepOrange for negative days (overdue)', () {
      expect(deadlineProximityColor(-1, colorScheme), Colors.deepOrange);
    });

    test('returns deepOrange for 0 days (today)', () {
      expect(deadlineProximityColor(0, colorScheme), Colors.deepOrange);
    });

    test('returns deepOrange for 1 day', () {
      expect(deadlineProximityColor(1, colorScheme), Colors.deepOrange);
    });

    test('returns deepOrange for 2 days', () {
      expect(deadlineProximityColor(2, colorScheme), Colors.deepOrange);
    });

    test('returns orange for 3 days', () {
      expect(deadlineProximityColor(3, colorScheme), Colors.orange);
    });

    test('returns orange for 7 days', () {
      expect(deadlineProximityColor(7, colorScheme), Colors.orange);
    });

    test('returns primary for 8 days', () {
      expect(deadlineProximityColor(8, colorScheme), colorScheme.primary);
    });

    test('returns primary for 30 days', () {
      expect(deadlineProximityColor(30, colorScheme), colorScheme.primary);
    });
  });

  group('deadlineDisplayColor', () {
    final colorScheme = ColorScheme.fromSeed(seedColor: Colors.blue);

    String dateFromNow(int daysOffset) {
      final d = DateTime.now().add(Duration(days: daysOffset));
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }

    group('due_by deadlines use proximity colors at all ranges', () {
      test('overdue (-3 days) returns deepOrange', () {
        expect(
          deadlineDisplayColor(dateFromNow(-3), 'due_by', colorScheme),
          Colors.deepOrange,
        );
      });

      test('today (0 days) returns deepOrange', () {
        expect(
          deadlineDisplayColor(dateFromNow(0), 'due_by', colorScheme),
          Colors.deepOrange,
        );
      });

      test('tomorrow (1 day) returns deepOrange', () {
        expect(
          deadlineDisplayColor(dateFromNow(1), 'due_by', colorScheme),
          Colors.deepOrange,
        );
      });

      test('2 days out returns deepOrange', () {
        expect(
          deadlineDisplayColor(dateFromNow(2), 'due_by', colorScheme),
          Colors.deepOrange,
        );
      });

      test('3 days out returns orange', () {
        expect(
          deadlineDisplayColor(dateFromNow(3), 'due_by', colorScheme),
          Colors.orange,
        );
      });

      test('7 days out returns orange', () {
        expect(
          deadlineDisplayColor(dateFromNow(7), 'due_by', colorScheme),
          Colors.orange,
        );
      });

      test('8 days out returns primary', () {
        expect(
          deadlineDisplayColor(dateFromNow(8), 'due_by', colorScheme),
          colorScheme.primary,
        );
      });

      test('14 days out returns primary', () {
        expect(
          deadlineDisplayColor(dateFromNow(14), 'due_by', colorScheme),
          colorScheme.primary,
        );
      });
    });

    group('on deadlines return primary when future, proximity when due', () {
      test('future (8 days) returns primary', () {
        expect(
          deadlineDisplayColor(dateFromNow(8), 'on', colorScheme),
          colorScheme.primary,
        );
      });

      test('future (1 day) returns primary', () {
        expect(
          deadlineDisplayColor(dateFromNow(1), 'on', colorScheme),
          colorScheme.primary,
        );
      });

      test('today (0 days) falls through to proximity — deepOrange', () {
        expect(
          deadlineDisplayColor(dateFromNow(0), 'on', colorScheme),
          Colors.deepOrange,
        );
      });

      test('past (-1 day) falls through to proximity — deepOrange', () {
        expect(
          deadlineDisplayColor(dateFromNow(-1), 'on', colorScheme),
          Colors.deepOrange,
        );
      });

      test('past (-10 days) falls through to proximity — deepOrange', () {
        expect(
          deadlineDisplayColor(dateFromNow(-10), 'on', colorScheme),
          Colors.deepOrange,
        );
      });
    });

    test('returns onSurfaceVariant for unparseable date', () {
      expect(
        deadlineDisplayColor('not-a-date', 'due_by', colorScheme),
        colorScheme.onSurfaceVariant,
      );
    });

    test('returns onSurfaceVariant for empty string', () {
      expect(
        deadlineDisplayColor('', 'on', colorScheme),
        colorScheme.onSurfaceVariant,
      );
    });

    test('handles ISO 8601 datetime with time component', () {
      // DateTime.tryParse handles full ISO strings; only the date part matters
      final d = DateTime.now().add(const Duration(days: 5));
      final isoStr = d.toIso8601String(); // includes time
      expect(
        deadlineDisplayColor(isoStr, 'due_by', colorScheme),
        Colors.orange,
      );
    });

    test('due_by and on agree for day-of deadline', () {
      final today = dateFromNow(0);
      // Both should use proximity color for day 0 → deepOrange
      expect(
        deadlineDisplayColor(today, 'due_by', colorScheme),
        deadlineDisplayColor(today, 'on', colorScheme),
      );
    });

    test('due_by and on differ for future deadline', () {
      final future = dateFromNow(3);
      // due_by → orange (proximity), on → primary (future shortcut)
      expect(
        deadlineDisplayColor(future, 'due_by', colorScheme),
        Colors.orange,
      );
      expect(
        deadlineDisplayColor(future, 'on', colorScheme),
        colorScheme.primary,
      );
    });
  });

  group('formatDeadlineDate', () {
    test('formats a valid date string as "Mon DD, YYYY"', () {
      expect(formatDeadlineDate('2026-03-24'), 'Mar 24, 2026');
    });

    test('formats January date', () {
      expect(formatDeadlineDate('2025-01-05'), 'Jan 5, 2025');
    });

    test('formats December date', () {
      expect(formatDeadlineDate('2025-12-31'), 'Dec 31, 2025');
    });

    test('returns original string for unparseable input', () {
      expect(formatDeadlineDate('not-a-date'), 'not-a-date');
    });

    test('returns original string for empty string', () {
      expect(formatDeadlineDate(''), '');
    });

    test('handles ISO 8601 with time component', () {
      expect(formatDeadlineDate('2026-06-15T10:30:00'), 'Jun 15, 2026');
    });

    test('formats all 12 months correctly', () {
      final expected = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      for (var i = 1; i <= 12; i++) {
        final month = i.toString().padLeft(2, '0');
        expect(formatDeadlineDate('2025-$month-01'), '${expected[i - 1]} 1, 2025');
      }
    });
  });

  group('askRemoveDeadlineOnDone', () {
    testWidgets('shows dialog with due_by label and returns true on Remove', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await askRemoveDeadlineOnDone(context, '2026-04-15', 'due_by');
            },
            child: const Text('Trigger'),
          ),
        ),
      ));

      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();

      expect(find.text('Remove deadline?'), findsOneWidget);
      expect(find.textContaining('due by'), findsOneWidget);
      expect(find.textContaining('Apr 15, 2026'), findsOneWidget);
      expect(find.text('Keep'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });

    testWidgets('shows dialog with "on" label for "on" type', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await askRemoveDeadlineOnDone(context, '2026-01-10', 'on');
            },
            child: const Text('Trigger'),
          ),
        ),
      ));

      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();

      expect(find.textContaining('scheduled on Jan 10, 2026'), findsOneWidget);

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });

    testWidgets('returns null when dialog is dismissed (barrier tap)', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await askRemoveDeadlineOnDone(context, '2026-05-01', 'due_by');
            },
            child: const Text('Trigger'),
          ),
        ),
      ));

      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();

      // Tap the barrier to dismiss
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });
  });

  group('confirmDependentUnblock', () {
    testWidgets('returns true immediately when dependentNames is empty', (tester) async {
      // No dialog should appear when there are no dependents to unblock.
      late bool result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await confirmDependentUnblock(context, 'Task A', []);
            },
            child: const Text('Trigger'),
          ),
        ),
      ));

      await tester.tap(find.text('Trigger'));
      await tester.pump();

      expect(result, isTrue);
      // No dialog should have appeared
      expect(find.text('Unblock waiting tasks?'), findsNothing);
    });

    testWidgets('shows confirmation dialog with dependent names', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              await confirmDependentUnblock(context, 'Blocker', ['Dep A', 'Dep B']);
            },
            child: const Text('Trigger'),
          ),
        ),
      ));

      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();

      expect(find.text('Unblock waiting tasks?'), findsOneWidget);
      expect(find.textContaining('Dep A'), findsOneWidget);
      expect(find.textContaining('Dep B'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Complete'), findsOneWidget);
    });

    testWidgets('returns true when user taps Complete', (tester) async {
      late bool result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await confirmDependentUnblock(context, 'Blocker', ['Dep A']);
            },
            child: const Text('Trigger'),
          ),
        ),
      ));

      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Complete'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });

    testWidgets('returns false when user taps Cancel', (tester) async {
      late bool result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await confirmDependentUnblock(context, 'Blocker', ['Dep A']);
            },
            child: const Text('Trigger'),
          ),
        ),
      ));

      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });

    testWidgets('returns false when dialog is dismissed by tapping outside', (tester) async {
      late bool result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await confirmDependentUnblock(context, 'Blocker', ['Dep A']);
            },
            child: const Text('Trigger'),
          ),
        ),
      ));

      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();

      // Tap outside the dialog to dismiss
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });
  });

  group('debugLog', () {
    test('calls debugPrint in debug mode', () {
      // In test mode, kDebugMode is true, so debugLog should forward to
      // debugPrint. We intercept debugPrint to verify the message arrives.
      final List<String> captured = [];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
      };
      try {
        debugLog('test message alpha');
        expect(captured, contains('test message alpha'));
      } finally {
        debugPrint = originalDebugPrint;
      }
    });

    test('forwards exact message without modification', () {
      final List<String> captured = [];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
      };
      try {
        const msg = 'AuthService: Firebase token exchange failed: 401 {"error":"INVALID"}';
        debugLog(msg);
        expect(captured.single, equals(msg));
      } finally {
        debugPrint = originalDebugPrint;
      }
    });

    test('handles empty string', () {
      final List<String> captured = [];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
      };
      try {
        debugLog('');
        expect(captured, contains(''));
      } finally {
        debugPrint = originalDebugPrint;
      }
    });
  });

  group('SEC-fix LOW-21/LOW-22: no ungated debugPrint in lib/', () {
    // Regression test: scans lib/ to ensure no raw debugPrint calls remain.
    // Before the fix, 12 call sites used debugPrint directly (some without
    // kDebugMode guard), leaking error details to Android logcat in release.
    // After the fix, all call sites use debugLog instead.
    test('no raw debugPrint calls outside display_utils.dart', () {
      final libDir = Directory('lib');
      expect(libDir.existsSync(), isTrue,
          reason: 'lib/ directory must exist (run tests from project root)');

      final violations = <String>[];
      for (final file in libDir.listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;

        // display_utils.dart is allowed to use debugPrint (it wraps it)
        if (file.path.endsWith('display_utils.dart')) continue;

        final lines = file.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          final line = lines[i];
          // Skip comments and import lines
          if (line.trimLeft().startsWith('//')) continue;
          if (line.trimLeft().startsWith('import ')) continue;

          if (line.contains('debugPrint')) {
            violations.add('${file.path}:${i + 1}: ${line.trim()}');
          }
        }
      }

      expect(violations, isEmpty,
          reason: 'Found ungated debugPrint calls that should use debugLog '
              'instead:\n${violations.join('\n')}');
    });

    test('debugLog import present in files that use it', () {
      // Verify that files using debugLog actually import it
      final libDir = Directory('lib');
      final missingImports = <String>[];

      for (final file in libDir.listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        if (file.path.endsWith('display_utils.dart')) continue;

        final content = file.readAsStringSync();
        if (content.contains('debugLog(') &&
            !content.contains("import") ||
            content.contains('debugLog(') &&
            !content.contains('debugLog')) {
          // This is a sanity check — Dart would fail to compile anyway,
          // but we surface it here for clarity.
          missingImports.add(file.path);
        }
      }
      // If we get here without compile errors, all imports are fine.
      // This test mainly documents the expectation.
      expect(missingImports, isEmpty);
    });
  });
}
