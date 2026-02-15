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
  List<Task> _archivedTasks = [];
  Map<int, List<String>> _parentNamesMap = {};
  /// Precomputed archive labels keyed by task ID.
  Map<int, String> _archivedLabels = {};
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
    final tasks = await provider.getArchivedTasks();
    final taskIds = tasks.map((t) => t.id!).toList();
    final parentNames = await provider.getParentNamesForTaskIds(taskIds);

    if (!mounted) return;
    // Precompute archive labels once using a single "now" snapshot.
    final labels = <int, String>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (final task in tasks) {
      labels[task.id!] = _computeArchivedLabel(task, now, today);
    }
    setState(() {
      _archivedTasks = tasks;
      _parentNamesMap = parentNames;
      _archivedLabels = labels;
      _loading = false;
    });
  }

  Color _cardColor(int taskId) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark ? _cardColorsDark : _cardColors;
    return colors[taskId % colors.length];
  }

  static String _computeArchivedLabel(Task task, DateTime now, DateTime today) {
    final isSkipped = task.isSkipped;
    final prefix = isSkipped ? 'Skipped' : 'Completed';
    final timestampMs = isSkipped ? task.skippedAt! : task.completedAt!;
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final taskDay = DateTime(date.year, date.month, date.day);
    final diff = today.difference(taskDay).inDays;

    if (diff == 0) return '$prefix today';
    if (diff == 1) return '$prefix yesterday';
    if (diff < 7) return '$prefix $diff days ago';

    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final month = months[date.month - 1];
    if (date.year == now.year) {
      return '$prefix $month ${date.day}';
    }
    return '$prefix $month ${date.day}, ${date.year}';
  }

  Future<void> _permanentlyDeleteTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final deleted = await provider.permanentlyDeleteTask(task.id!, task);

    if (!mounted) return;

    setState(() {
      _archivedTasks.removeWhere((t) => t.id == task.id);
    });

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Permanently deleted "${task.name}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await provider.restoreTask(
              deleted.task,
              deleted.parentIds,
              deleted.childIds,
              dependsOnIds: deleted.dependsOnIds,
              dependedByIds: deleted.dependedByIds,
            );
            if (task.isSkipped) {
              await provider.reSkipTask(task.id!);
            } else {
              await provider.reCompleteTask(task.id!);
            }
            await _loadData();
          },
        ),
        showCloseIcon: true,
        persist: false,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _restoreTask(Task task) async {
    final provider = context.read<TaskProvider>();
    if (task.isSkipped) {
      await provider.unskipTask(task.id!);
    } else {
      await provider.uncompleteTask(task.id!);
    }

    if (!mounted) return;

    setState(() {
      _archivedTasks.removeWhere((t) => t.id == task.id);
    });

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Restored "${task.name}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            if (task.isSkipped) {
              await provider.reSkipTask(task.id!);
            } else {
              await provider.reCompleteTask(task.id!);
            }
            await _loadData();
          },
        ),
        showCloseIcon: true,
        persist: false,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Archive'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _archivedTasks.isEmpty
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
            'No archived tasks',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(150),
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tasks you complete or skip will appear here',
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
      itemCount: _archivedTasks.length,
      itemBuilder: (context, index) {
        final task = _archivedTasks[index];
        final parentNames = _parentNamesMap[task.id];
        return _buildTaskItem(task, parentNames);
      },
    );
  }

  Widget _buildTaskItem(Task task, List<String>? parentNames) {
    final archivedLabel = _archivedLabels[task.id] ?? '';
    final parentLabel = parentNames != null && parentNames.isNotEmpty
        ? 'Was under ${parentNames.join(', ')}'
        : null;

    return Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        color: _cardColor(task.id!),
        child: ListTile(
          leading: Icon(
            task.isSkipped ? Icons.not_interested : Icons.task_alt,
            color: task.isSkipped
                ? Theme.of(context).colorScheme.onSurfaceVariant
                : Theme.of(context).colorScheme.primary,
          ),
          title: Text(task.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(archivedLabel),
              if (parentLabel != null) Text(parentLabel),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete permanently',
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('Delete permanently?'),
                      content: Text('"${task.name}" will be gone forever.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    _permanentlyDeleteTask(task);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.restore),
                tooltip: 'Restore',
                onPressed: () => _restoreTask(task),
              ),
            ],
          ),
        ),
    );
  }
}
