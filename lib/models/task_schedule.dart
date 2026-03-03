class TaskSchedule {
  final int? id;
  final int taskId;
  final String scheduleType; // 'weekly' or 'oneoff'
  final int? dayOfWeek; // 1=Mon..7=Sun (ISO 8601)
  final String? specificDate; // 'YYYY-MM-DD'
  final String? syncId;
  final int? updatedAt;

  TaskSchedule({
    this.id,
    required this.taskId,
    required this.scheduleType,
    this.dayOfWeek,
    this.specificDate,
    this.syncId,
    this.updatedAt,
  });

  bool get isWeekly => scheduleType == 'weekly';
  bool get isOneOff => scheduleType == 'oneoff';

  bool isActiveOn(DateTime date) {
    if (isWeekly) {
      return date.weekday == dayOfWeek;
    }
    if (isOneOff && specificDate != null) {
      final d = DateTime.parse(specificDate!);
      return d.year == date.year && d.month == date.month && d.day == date.day;
    }
    return false;
  }

  bool get isExpired {
    if (!isOneOff || specificDate == null) return false;
    final d = DateTime.parse(specificDate!);
    final now = DateTime.now();
    return DateTime(d.year, d.month, d.day)
        .isBefore(DateTime(now.year, now.month, now.day));
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'task_id': taskId,
      'schedule_type': scheduleType,
      'day_of_week': dayOfWeek,
      'specific_date': specificDate,
      'sync_id': syncId,
      'updated_at': updatedAt,
    };
  }

  factory TaskSchedule.fromMap(Map<String, dynamic> map) {
    return TaskSchedule(
      id: map['id'] as int?,
      taskId: map['task_id'] as int,
      scheduleType: map['schedule_type'] as String,
      dayOfWeek: map['day_of_week'] as int?,
      specificDate: map['specific_date'] as String?,
      syncId: map['sync_id'] as String?,
      updatedAt: map['updated_at'] as int?,
    );
  }

  TaskSchedule copyWith({
    int? id,
    int? taskId,
    String? scheduleType,
    int? Function()? dayOfWeek,
    String? Function()? specificDate,
    String? syncId,
    int? updatedAt,
  }) {
    return TaskSchedule(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      scheduleType: scheduleType ?? this.scheduleType,
      dayOfWeek: dayOfWeek != null ? dayOfWeek() : this.dayOfWeek,
      specificDate:
          specificDate != null ? specificDate() : this.specificDate,
      syncId: syncId ?? this.syncId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
