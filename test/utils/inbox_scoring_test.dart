import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/utils/inbox_scoring.dart';

void main() {
  group('tokenize', () {
    test('basic tokenization', () {
      expect(tokenize('Buy groceries'), {'buy', 'groceries'});
    });

    test('filters stop words', () {
      expect(tokenize('a task for the project'), {'task', 'project'});
    });

    test('case insensitivity', () {
      expect(tokenize('BUY Milk'), {'buy', 'milk'});
    });

    test('splits on punctuation and special characters', () {
      expect(tokenize('work-life balance'), {'work', 'life', 'balance'});
    });

    test('empty string returns empty set', () {
      expect(tokenize(''), <String>{});
    });

    test('all stop words returns empty set', () {
      expect(tokenize('a the in'), <String>{});
    });
  });

  group('jaccardSimilarity', () {
    test('identical sets return 1.0', () {
      expect(jaccardSimilarity({'a', 'b', 'c'}, {'a', 'b', 'c'}), 1.0);
    });

    test('disjoint sets return 0.0', () {
      expect(jaccardSimilarity({'a', 'b'}, {'c', 'd'}), 0.0);
    });

    test('both empty returns 0.0', () {
      expect(jaccardSimilarity(<String>{}, <String>{}), 0.0);
    });

    test('partial overlap returns correct ratio', () {
      // intersection = {b, c} (2), union = {a, b, c, d} (4) → 0.5
      expect(jaccardSimilarity({'a', 'b', 'c'}, {'b', 'c', 'd'}), 0.5);
    });

    test('one empty and one non-empty returns 0.0', () {
      expect(jaccardSimilarity(<String>{}, {'a', 'b'}), 0.0);
      expect(jaccardSimilarity({'a', 'b'}, <String>{}), 0.0);
    });
  });
}
