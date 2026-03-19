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
}
