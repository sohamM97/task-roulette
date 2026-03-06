class TaskSchedule {
  final int? id;
  final int taskId;
  final int dayOfWeek; // 1=Mon..7=Sun (ISO 8601)
  final String? syncId;
  final int? updatedAt;

  TaskSchedule({
    this.id,
    required this.taskId,
    required this.dayOfWeek,
    this.syncId,
    this.updatedAt,
  });

  bool isActiveOn(DateTime date) => date.weekday == dayOfWeek;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'task_id': taskId,
      'schedule_type': 'weekly',
      'day_of_week': dayOfWeek,
      'sync_id': syncId,
      'updated_at': updatedAt,
    };
  }

  factory TaskSchedule.fromMap(Map<String, dynamic> map) {
    return TaskSchedule(
      id: map['id'] as int?,
      taskId: map['task_id'] as int,
      dayOfWeek: map['day_of_week'] as int,
      syncId: map['sync_id'] as String?,
      updatedAt: map['updated_at'] as int?,
    );
  }

  TaskSchedule copyWith({
    int? id,
    int? taskId,
    int? dayOfWeek,
    String? syncId,
    int? updatedAt,
  }) {
    return TaskSchedule(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      syncId: syncId ?? this.syncId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
