import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/add_task_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/leaf_task_detail.dart';
import '../widgets/random_result_dialog.dart';
import '../widgets/task_card.dart';
import '../widgets/task_picker_dialog.dart';

class TaskListScreen extends StatefulWidget {
  const TaskListScreen({super.key});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  @override
  void initState() {
    super.initState();
    context.read<TaskProvider>().loadRootTasks();
  }

  Future<void> _addTask() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const AddTaskDialog(),
    );
    if (name != null && mounted) {
      await context.read<TaskProvider>().addTask(name);
    }
  }

  void _showFabOptions() {
    final provider = context.read<TaskProvider>();
    if (provider.isRoot) {
      _addTask();
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Create new task'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _addTask();
                },
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Link existing task here'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _linkExistingTask();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _linkExistingTask() async {
    final provider = context.read<TaskProvider>();
    final currentParent = provider.currentParent;
    if (currentParent == null) return;

    final allTasks = await provider.getAllTasks();
    final parentNamesMap = await provider.getParentNamesMap();
    final existingChildIds = await provider.getChildIds(currentParent.id!);
    final existingChildIdSet = existingChildIds.toSet();

    // Filter out: the current task itself, its existing children
    final candidates = allTasks.where((t) {
      if (t.id == currentParent.id) return false;
      if (existingChildIdSet.contains(t.id)) return false;
      return true;
    }).toList();

    if (!mounted) return;

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: candidates,
        title: 'Link task under "${currentParent.name}"',
        parentNamesMap: parentNamesMap,
      ),
    );

    if (selected == null || !mounted) return;

    final success = await provider.linkChildToCurrent(selected.id!);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot link: would create a cycle')),
      );
    }
  }

  Future<void> _addParentToTask(Task task) async {
    final provider = context.read<TaskProvider>();

    final allTasks = await provider.getAllTasks();
    final parentNamesMap = await provider.getParentNamesMap();
    final existingParentIds = await provider.getParentIds(task.id!);
    final existingParentIdSet = existingParentIds.toSet();

    // Filter out: the task itself, its existing parents
    final candidates = allTasks.where((t) {
      if (t.id == task.id) return false;
      if (existingParentIdSet.contains(t.id)) return false;
      return true;
    }).toList();

    if (!mounted) return;

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: candidates,
        title: 'Also show "${task.name}" under...',
        parentNamesMap: parentNamesMap,
      ),
    );

    if (selected == null || !mounted) return;

    final success = await provider.addParentToTask(task.id!, selected.id!);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot link: would create a cycle')),
      );
    }
  }

  Future<void> _renameTask(Task task) async {
    final controller = TextEditingController(text: task.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Task name'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != task.name && mounted) {
      await context.read<TaskProvider>().renameTask(task.id!, newName);
    }
  }

  Future<void> _unlinkTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final parentIds = await provider.getParentIds(task.id!);

    if (parentIds.length <= 1) {
      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Move to top level?'),
          content: Text(
            '"${task.name}" is only listed here. '
            'Removing it will move it to the top level.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Move to top level'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }

    await provider.unlinkFromCurrentParent(task.id!);
  }

  Future<void> _deleteTaskWithUndo(Task task) async {
    final provider = context.read<TaskProvider>();
    final deleted = await provider.deleteTask(task.id!);

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted "${task.name}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            provider.restoreTask(deleted.task, deleted.parentIds, deleted.childIds);
          },
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _completeTaskWithUndo(Task task) async {
    final provider = context.read<TaskProvider>();
    await provider.completeTask(task.id!);

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('"${task.name}" marked done!'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            provider.uncompleteTask(task.id!);
          },
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Widget _buildLeafTaskDetail(TaskProvider provider) {
    final task = provider.currentParent!;
    return FutureBuilder<List<Task>>(
      future: provider.getParents(task.id!),
      builder: (context, snapshot) {
        final parentNames = snapshot.data?.map((t) => t.name).toList() ?? [];
        return LeafTaskDetail(
          task: task,
          parentNames: parentNames,
          onDone: () => _completeTaskWithUndo(task),
          onAddParent: () => _addParentToTask(task),
        );
      },
    );
  }

  Future<void> _pickRandom() async {
    final provider = context.read<TaskProvider>();
    final picked = provider.pickRandom();
    if (picked == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No tasks to pick from')),
        );
      }
      return;
    }
    await _showRandomResult(picked);
  }

  Future<void> _showRandomResult(Task task) async {
    final provider = context.read<TaskProvider>();
    final children = await provider.getChildren(task.id!);

    if (!mounted) return;

    final action = await showDialog<RandomResultAction>(
      context: context,
      builder: (_) => RandomResultDialog(
        task: task,
        hasChildren: children.isNotEmpty,
      ),
    );

    if (!mounted) return;

    switch (action) {
      case RandomResultAction.goDeeper:
        // Pick random from this task's children
        if (children.isNotEmpty) {
          final deeper = children[
              (children.length == 1) ? 0 : DateTime.now().millisecondsSinceEpoch % children.length];
          await _showRandomResult(deeper);
        }
      case RandomResultAction.goToTask:
        await provider.navigateInto(task);
      case null:
        break;
    }
  }

  Widget _buildBreadcrumb(TaskProvider provider) {
    final crumbs = provider.breadcrumb;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(128),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < crumbs.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              if (i < crumbs.length - 1)
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => provider.navigateToLevel(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      crumbs[i] == null ? 'Task Roulette' : crumbs[i]!.name,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    crumbs[i]!.name,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  int _crossAxisCount(double width) {
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }

  double _childAspectRatio(int columns) {
    if (columns == 1) return 3.0;
    return 1.0;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final provider = context.read<TaskProvider>();
        final navigator = Navigator.of(context);
        final navigated = await provider.navigateBack();
        if (!navigated && mounted) {
          navigator.maybePop();
        }
      },
      child: Consumer<TaskProvider>(
        builder: (context, provider, _) {
          return Scaffold(
            appBar: AppBar(
              title: provider.isRoot
                  ? Text(
                      'Task Roulette',
                      style: GoogleFonts.outfit(
                        fontSize: 30,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.3,
                      ),
                    )
                  : Text(provider.currentParent!.name),
              leading: provider.isRoot
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => provider.navigateBack(),
                    ),
              actions: [
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, _) {
                    return IconButton(
                      icon: Icon(themeProvider.icon, size: 28),
                      onPressed: themeProvider.toggle,
                      tooltip: 'Toggle theme',
                    );
                  },
                ),
              ],
            ),
            body: Column(
              children: [
                if (!provider.isRoot)
                  _buildBreadcrumb(provider),
                Expanded(
                  child: provider.tasks.isEmpty
                    ? (provider.isRoot
                        ? const EmptyState(isRoot: true)
                        : _buildLeafTaskDetail(provider))
                    : LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = _crossAxisCount(constraints.maxWidth);
                      return GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          childAspectRatio: _childAspectRatio(columns),
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: provider.tasks.length,
                        itemBuilder: (context, index) {
                          final task = provider.tasks[index];
                          return TaskCard(
                            task: task,
                            onTap: () => provider.navigateInto(task),
                            onDelete: () => _deleteTaskWithUndo(task),
                            onAddParent: () => _addParentToTask(task),
                            onUnlink: provider.isRoot
                                ? null
                                : () => _unlinkTask(task),
                            onRename: () => _renameTask(task),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
            floatingActionButton: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (provider.tasks.isNotEmpty)
                  FloatingActionButton(
                    heroTag: 'pickRandom',
                    onPressed: _pickRandom,
                    child: const Icon(Icons.shuffle),
                  ),
                if (provider.tasks.isNotEmpty)
                  const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'addTask',
                  onPressed: _showFabOptions,
                  child: const Icon(Icons.add),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
