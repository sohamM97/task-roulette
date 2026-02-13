class Task {
  final int? id;
  final String name;
  final int createdAt;
  final int? completedAt;
  final int? startedAt;
  final String? url;
  final int? skippedAt;
  final int priority;
  final int difficulty;

  static const priorityLabels = ['Low', 'Medium', 'High'];
  static const difficultyLabels = ['Easy', 'Medium', 'Hard'];

  Task({
    this.id,
    required this.name,
    int? createdAt,
    this.completedAt,
    this.startedAt,
    this.url,
    this.skippedAt,
    this.priority = 1,
    this.difficulty = 1,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  bool get isCompleted => completedAt != null;
  bool get isSkipped => skippedAt != null;
  bool get isStarted => startedAt != null && !isCompleted;
  bool get hasUrl => url != null && url!.isNotEmpty;

  String get priorityLabel => priorityLabels[priority];
  String get difficultyLabel => difficultyLabels[difficulty];

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'created_at': createdAt,
      'completed_at': completedAt,
      'started_at': startedAt,
      'url': url,
      'skipped_at': skippedAt,
      'priority': priority,
      'difficulty': difficulty,
    };
  }

  factory Task.fromMap(Map<String, dynamic> map) {
    return Task(
      id: map['id'] as int,
      name: map['name'] as String,
      createdAt: map['created_at'] as int,
      completedAt: map['completed_at'] as int?,
      startedAt: map['started_at'] as int?,
      url: map['url'] as String?,
      skippedAt: map['skipped_at'] as int?,
      priority: map['priority'] as int? ?? 1,
      difficulty: map['difficulty'] as int? ?? 1,
    );
  }
}
