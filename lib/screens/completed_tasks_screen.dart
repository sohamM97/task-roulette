import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';

class CompletedTasksScreen extends StatefulWidget {
  const CompletedTasksScreen({super.key});

  @override
  State<CompletedTasksScreen> createState() => _CompletedTasksScreenState();
}

class _CompletedTasksScreenState extends State<CompletedTasksScreen> {
  List<Task> _completedTasks = [];
  Map<int, List<String>> _parentNamesMap = {};
  bool _loading = true;

  static const _cardColors = [
    Color(0xFFE8DEF8), // purple
    Color(0xFFD0E8FF), // blue
    Color(0xFFDCEDC8), // green
    Color(0xFFFFE0B2), // orange
    Color(0xFFF8BBD0), // pink
    Color(0xFFB2EBF2), // cyan
    Color(0xFFFFF9C4), // yellow
    Color(0xFFD1C4E9), // lavender
  ];

  static const _cardColorsDark = [
    Color(0xFF352E4D), // purple
    Color(0xFF2E354D), // blue
    Color(0xFF2E3E35), // sage
    Color(0xFF3E3530), // warm grey
    Color(0xFF3E2E38), // mauve
    Color(0xFF2E3E3E), // teal
    Color(0xFF38362E), // taupe
    Color(0xFF302E45), // slate
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final provider = context.read<TaskProvider>();
    final tasks = await provider.getCompletedTasks();
    final taskIds = tasks.map((t) => t.id!).toList();
    final parentNames = await provider.getParentNamesForTaskIds(taskIds);

    if (!mounted) return;
    setState(() {
      _completedTasks = tasks;
      _parentNamesMap = parentNames;
      _loading = false;
    });
  }

  Color _cardColor(int taskId) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark ? _cardColorsDark : _cardColors;
    return colors[taskId % colors.length];
  }

  String _completedLabel(int completedAtMs) {
    final completedDate = DateTime.fromMillisecondsSinceEpoch(completedAtMs);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final completedDay = DateTime(
      completedDate.year,
      completedDate.month,
      completedDate.day,
    );
    final diff = today.difference(completedDay).inDays;

    if (diff == 0) return 'Completed today';
    if (diff == 1) return 'Completed yesterday';
    if (diff < 7) return 'Completed $diff days ago';

    // For older dates, show the date
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final month = months[completedDate.month - 1];
    if (completedDate.year == now.year) {
      return 'Completed $month ${completedDate.day}';
    }
    return 'Completed $month ${completedDate.day}, ${completedDate.year}';
  }

  Future<void> _restoreTask(Task task) async {
    final provider = context.read<TaskProvider>();
    await provider.uncompleteTask(task.id!);

    if (!mounted) return;

    setState(() {
      _completedTasks.removeWhere((t) => t.id == task.id);
    });

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Restored "${task.name}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await provider.reCompleteTask(task.id!);
            await _loadData();
          },
        ),
        showCloseIcon: true,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Completed Tasks'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _completedTasks.isEmpty
              ? _buildEmptyState()
              : _buildList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.task_alt,
            size: 64,
            color: Theme.of(context).colorScheme.onSurface.withAlpha(100),
          ),
          const SizedBox(height: 16),
          Text(
            'No completed tasks',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(150),
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tasks you mark as done will appear here',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(100),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _completedTasks.length,
      itemBuilder: (context, index) {
        final task = _completedTasks[index];
        final parentNames = _parentNamesMap[task.id];
        return _buildTaskItem(task, parentNames);
      },
    );
  }

  Widget _buildTaskItem(Task task, List<String>? parentNames) {
    final completedLabel = _completedLabel(task.completedAt!);
    final parentLabel = parentNames != null && parentNames.isNotEmpty
        ? 'Was under ${parentNames.join(', ')}'
        : null;

    return Dismissible(
      key: ValueKey(task.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: Theme.of(context).colorScheme.primary,
        child: Icon(
          Icons.restore,
          color: Theme.of(context).colorScheme.onPrimary,
        ),
      ),
      onDismissed: (_) => _restoreTask(task),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        color: _cardColor(task.id!),
        child: ListTile(
          title: Text(task.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(completedLabel),
              if (parentLabel != null) Text(parentLabel),
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.restore),
            tooltip: 'Restore',
            onPressed: () => _restoreTask(task),
          ),
        ),
      ),
    );
  }
}
