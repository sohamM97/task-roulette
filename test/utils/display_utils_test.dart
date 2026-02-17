import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/utils/display_utils.dart';

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
}
