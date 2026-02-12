class Task {
  final int? id;
  final String name;
  final int createdAt;
  final int? completedAt;

  Task({
    this.id,
    required this.name,
    int? createdAt,
    this.completedAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  bool get isCompleted => completedAt != null;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'created_at': createdAt,
      'completed_at': completedAt,
    };
  }

  factory Task.fromMap(Map<String, dynamic> map) {
    return Task(
      id: map['id'] as int,
      name: map['name'] as String,
      createdAt: map['created_at'] as int,
      completedAt: map['completed_at'] as int?,
    );
  }
}
