import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/database_helper.dart';
import '../data/xp_config.dart';

/// Manages XP, rank, streaks, and weekly stats for the progression system.
///
/// Follows the same ChangeNotifier pattern as TaskProvider and ThemeProvider.
/// Call [init] once on app startup (from _initAuth in main.dart).
class ProgressionProvider extends ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper();

  // --- XP & Rank state ---
  int _totalXp = 0;
  int get totalXp => _totalXp;

  String _rankTitle = 'Novice';
  int _tierIndex = 0;
  int _currentMin = 0;
  int? _nextMin;

  String get rankTitle => _rankTitle;
  int get tierIndex => _tierIndex;
  int get currentMin => _currentMin;
  int? get nextMin => _nextMin;

  /// Progress fraction (0.0–1.0) within the current rank tier.
  double get rankProgress =>
      RankConfig.progressFraction(_totalXp, _currentMin, _nextMin);

  // --- Class selection ---
  RankClass _rankClass = RankClass.adventurer;
  RankClass get rankClass => _rankClass;

  static const _rankClassKey = 'progression_rank_class';
  static const _backfillDoneKey = 'progression_backfill_done';

  /// Whether the user has chosen a class yet (false = show class picker).
  bool _classChosen = false;
  bool get classChosen => _classChosen;

  // --- Streaks ---
  int _currentStreak = 0;
  int _bestStreak = 0;
  int get currentStreak => _currentStreak;
  int get bestStreak => _bestStreak;

  // --- Weekly stats ---
  List<int> _weeklyCompletions = List.filled(7, 0);
  List<int> _weeklyXp = List.filled(7, 0);
  int _weekActiveDays = 0;

  List<int> get weeklyCompletions => _weeklyCompletions;
  List<int> get weeklyXp => _weeklyXp;
  int get weekActiveDays => _weekActiveDays;

  /// Initializes the progression system: runs backfill if needed, loads state.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    // Load class selection
    final classIndex = prefs.getInt(_rankClassKey);
    if (classIndex != null && classIndex >= 0 && classIndex < RankClass.values.length) {
      _rankClass = RankClass.values[classIndex];
      _classChosen = true;
    }

    // Run backfill if this is the first launch after v24 migration
    final backfillDone = prefs.getBool(_backfillDoneKey) ?? false;
    if (!backfillDone) {
      await _db.backfillXpEvents();
      await prefs.setBool(_backfillDoneKey, true);
    }

    await refresh();
  }

  /// Reloads all progression data from the database.
  Future<void> refresh() async {
    _totalXp = await _db.getTotalXp();
    _updateRank();

    final streak = await _db.getActiveDaysStreak();
    _currentStreak = streak.current;
    _bestStreak = streak.best;

    final monday = _currentMonday();
    _weeklyCompletions = await _db.getCompletionsForWeek(monday);
    _weeklyXp = await _db.getXpForWeek(monday);
    _weekActiveDays = await _db.getWeekActiveDays(monday);

    notifyListeners();
  }

  /// Sets the user's chosen class and persists it.
  Future<void> setRankClass(RankClass rankClass) async {
    _rankClass = rankClass;
    _classChosen = true;
    _updateRank();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_rankClassKey, rankClass.index);

    notifyListeners();
  }

  /// Awards XP for an action. Call this after task mutations.
  ///
  /// [eventType] is one of [XpEventType] constants.
  /// [xpAmount] is the XP to award.
  /// [taskId] is optional (null for special events like all-Today's-5-complete).
  Future<void> awardXp(String eventType, int xpAmount, {int? taskId}) async {
    final date = _todayDateKey();
    await _db.insertXpEvent(
      eventType: eventType,
      xpAmount: xpAmount,
      taskId: taskId,
      date: date,
    );
    await refresh();
  }

  /// Awards base XP plus any applicable bonuses for a task action.
  ///
  /// Checks if the task is in Today's 5, high priority, or pinned,
  /// and awards bonus XP accordingly.
  Future<void> awardXpWithBonuses({
    required String eventType,
    required int baseXp,
    required int taskId,
    required bool isInTodaysFive,
    required bool isHighPriority,
    required bool isPinned,
  }) async {
    final date = _todayDateKey();

    // Base XP
    await _db.insertXpEvent(
      eventType: eventType,
      xpAmount: baseXp,
      taskId: taskId,
      date: date,
    );

    // Bonus XP (separate events for clean revocation)
    if (isInTodaysFive) {
      await _db.insertXpEvent(
        eventType: XpEventType.todaysFiveBonus,
        xpAmount: XpAmounts.todaysFiveBonus,
        taskId: taskId,
        date: date,
      );
    }
    if (isHighPriority) {
      await _db.insertXpEvent(
        eventType: XpEventType.highPriorityBonus,
        xpAmount: XpAmounts.highPriorityBonus,
        taskId: taskId,
        date: date,
      );
    }
    if (isPinned) {
      await _db.insertXpEvent(
        eventType: XpEventType.pinnedBonus,
        xpAmount: XpAmounts.pinnedBonus,
        taskId: taskId,
        date: date,
      );
    }

    await refresh();
  }

  /// Revokes XP for an undone action (e.g. uncomplete, un-worked-on).
  /// Removes the base event + all bonuses for that task on today's date.
  Future<void> revokeXp(String eventType, int taskId) async {
    final date = _todayDateKey();
    await _db.deleteXpEventsForTask(taskId, eventType, date);
    await _db.deleteXpBonusesForTask(taskId, date);
    await refresh();
  }

  void _updateRank() {
    final rank = RankConfig.rankFor(_totalXp, _rankClass);
    _rankTitle = rank.title;
    _tierIndex = rank.tierIndex;
    _currentMin = rank.currentMin;
    _nextMin = rank.nextMin;
  }

  /// Returns YYYY-MM-DD for today.
  static String _todayDateKey() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// Returns YYYY-MM-DD for the Monday of the current week.
  static String _currentMonday() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return '${monday.year.toString().padLeft(4, '0')}-'
        '${monday.month.toString().padLeft(2, '0')}-'
        '${monday.day.toString().padLeft(2, '0')}';
  }
}
