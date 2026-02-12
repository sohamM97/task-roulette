class TaskRelationship {
  final int parentId;
  final int childId;

  TaskRelationship({
    required this.parentId,
    required this.childId,
  });

  Map<String, dynamic> toMap() {
    return {
      'parent_id': parentId,
      'child_id': childId,
    };
  }

  factory TaskRelationship.fromMap(Map<String, dynamic> map) {
    return TaskRelationship(
      parentId: map['parent_id'] as int,
      childId: map['child_id'] as int,
    );
  }
}
