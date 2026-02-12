class Task {
  final int? id;
  final String name;
  final int createdAt;

  Task({
    this.id,
    required this.name,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'created_at': createdAt,
    };
  }

  factory Task.fromMap(Map<String, dynamic> map) {
    return Task(
      id: map['id'] as int,
      name: map['name'] as String,
      createdAt: map['created_at'] as int,
    );
  }
}
