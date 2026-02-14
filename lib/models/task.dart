class Task {
  final int? id;
  final String name;
  final int createdAt;
  final int? completedAt;
  final int? startedAt;
  final String? url;
  final int? skippedAt;
  final int priority;
  /// Reinterpreted: 0 = normal, 1 = quick task. DB column kept as `difficulty`.
  final int difficulty;
  final int? lastWorkedAt;
  final String? repeatInterval;
  final int? nextDueAt;

  static const priorityLabels = ['Normal', 'High'];

  Task({
    this.id,
    required this.name,
    int? createdAt,
    this.completedAt,
    this.startedAt,
    this.url,
    this.skippedAt,
    this.priority = 0,
    this.difficulty = 0,
    this.lastWorkedAt,
    this.repeatInterval,
    this.nextDueAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  bool get isCompleted => completedAt != null;
  bool get isSkipped => skippedAt != null;
  bool get isStarted => startedAt != null && !isCompleted;
  bool get hasUrl => url != null && url!.isNotEmpty;

  bool get isHighPriority => priority >= 1;
  String get priorityLabel => isHighPriority ? 'High' : 'Normal';
  bool get isQuickTask => difficulty == 1;
  bool get isRepeating => repeatInterval != null;
  bool get isDue => nextDueAt == null || nextDueAt! <= DateTime.now().millisecondsSinceEpoch;

  bool get isWorkedOnToday {
    if (lastWorkedAt == null) return false;
    final worked = DateTime.fromMillisecondsSinceEpoch(lastWorkedAt!);
    final now = DateTime.now();
    return worked.year == now.year &&
        worked.month == now.month &&
        worked.day == now.day;
  }

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
      'last_worked_at': lastWorkedAt,
      'repeat_interval': repeatInterval,
      'next_due_at': nextDueAt,
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
      priority: (map['priority'] as int? ?? 0).clamp(0, 1),
      difficulty: map['difficulty'] as int? ?? 0,
      lastWorkedAt: map['last_worked_at'] as int?,
      repeatInterval: map['repeat_interval'] as String?,
      nextDueAt: map['next_due_at'] as int?,
    );
  }
}
