import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task_relationship.dart';

void main() {
  group('TaskRelationship', () {
    test('constructor sets fields', () {
      final rel = TaskRelationship(parentId: 1, childId: 2);
      expect(rel.parentId, 1);
      expect(rel.childId, 2);
    });

    test('toMap returns correct map', () {
      final rel = TaskRelationship(parentId: 10, childId: 20);
      final map = rel.toMap();
      expect(map, {'parent_id': 10, 'child_id': 20});
    });

    test('fromMap creates correct instance', () {
      final map = {'parent_id': 5, 'child_id': 15};
      final rel = TaskRelationship.fromMap(map);
      expect(rel.parentId, 5);
      expect(rel.childId, 15);
    });

    test('round-trip: toMap then fromMap preserves values', () {
      final original = TaskRelationship(parentId: 42, childId: 99);
      final restored = TaskRelationship.fromMap(original.toMap());
      expect(restored.parentId, original.parentId);
      expect(restored.childId, original.childId);
    });
  });
}
