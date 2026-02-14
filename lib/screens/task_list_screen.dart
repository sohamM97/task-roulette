import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/add_task_dialog.dart';
import '../widgets/brain_dump_dialog.dart';
import '../widgets/completion_animation.dart';
import '../widgets/empty_state.dart';
import '../widgets/leaf_task_detail.dart';
import '../widgets/random_result_dialog.dart';
import '../widgets/task_card.dart';
import '../widgets/task_picker_dialog.dart';
import '../services/backup_service.dart';
import 'completed_tasks_screen.dart';
import 'dag_view_screen.dart';

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
    _addTask();
  }

  Future<void> _brainDump() async {
    final names = await showDialog<List<String>>(
      context: context,
      builder: (_) => const BrainDumpDialog(),
    );
    if (names != null && names.isNotEmpty && mounted) {
      final provider = context.read<TaskProvider>();
      for (final name in names) {
        await provider.addTask(name);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added ${names.length} tasks')),
        );
      }
    }
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

    final siblingIds = provider.tasks
        .map((t) => t.id!)
        .toSet();

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: candidates,
        title: 'Link task under "${currentParent.name}"',
        parentNamesMap: parentNamesMap,
        priorityIds: siblingIds,
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

    final siblingIds = provider.tasks
        .map((t) => t.id!)
        .where((id) => id != task.id)
        .toSet();

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: candidates,
        title: 'Also show "${task.name}" under...',
        parentNamesMap: parentNamesMap,
        priorityIds: siblingIds,
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

  Future<void> _updateUrl(Task task, String? url) async {
    await context.read<TaskProvider>().updateTaskUrl(task.id!, url);
  }

  Future<void> _moveTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final currentParent = provider.currentParent;
    if (currentParent == null) return;

    final allTasks = await provider.getAllTasks();
    final parentNamesMap = await provider.getParentNamesMap();

    // Filter out: the task itself, the current parent (already here)
    final candidates = allTasks.where((t) {
      if (t.id == task.id) return false;
      if (t.id == currentParent.id) return false;
      return true;
    }).toList();

    if (!mounted) return;

    final siblingIds = provider.tasks
        .map((t) => t.id!)
        .where((id) => id != task.id && id != currentParent.id)
        .toSet();

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: candidates,
        title: 'Move "${task.name}" to...',
        parentNamesMap: parentNamesMap,
        priorityIds: siblingIds,
      ),
    );

    if (selected == null || !mounted) return;

    final success = await provider.moveTask(task.id!, selected.id!);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot move: would create a cycle')),
      );
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
            provider.restoreTask(
              deleted.task,
              deleted.parentIds,
              deleted.childIds,
              dependsOnIds: deleted.dependsOnIds,
              dependedByIds: deleted.dependedByIds,
            );
          },
        ),
        showCloseIcon: true,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _toggleStarted(Task task) async {
    final provider = context.read<TaskProvider>();
    if (task.isStarted) {
      await provider.unstartTask(task.id!);
    } else {
      await provider.startTask(task.id!);
    }
  }

  Future<void> _skipTaskWithUndo(Task task) async {
    final provider = context.read<TaskProvider>();

    await provider.skipTask(task.id!);

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Skipped "${task.name}"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => provider.unskipTask(task.id!),
        ),
        showCloseIcon: true,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _completeTaskWithUndo(Task task) async {
    final provider = context.read<TaskProvider>();

    // Show celebratory animation before completing
    await showCompletionAnimation(context);

    if (!mounted) return;

    await provider.completeTask(task.id!);

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('"${task.name}" done!'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => provider.uncompleteTask(task.id!),
        ),
        showCloseIcon: true,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Widget _buildLeafTaskDetail(TaskProvider provider) {
    final task = provider.currentParent!;
    return FutureBuilder<List<Task>>(
      future: provider.getDependencies(task.id!),
      builder: (context, snapshot) {
        final deps = snapshot.data ?? [];
        return LeafTaskDetail(
          task: task,
          onDone: () => _completeTaskWithUndo(task),
          onSkip: () => _skipTaskWithUndo(task),
          onToggleStarted: () => _toggleStarted(task),
          onRename: () => _renameTask(task),
          onUpdateUrl: (url) => _updateUrl(task, url),
          dependencies: deps,
          onRemoveDependency: (depId) async {
            await provider.removeDependency(task.id!, depId);
          },
          onAddDependency: () => _addDependencyToTask(task),
        );
      },
    );
  }

  Future<void> _searchTask() async {
    final provider = context.read<TaskProvider>();
    final allTasks = await provider.getAllTasks();
    final parentNamesMap = await provider.getParentNamesMap();

    if (!mounted) return;

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: allTasks,
        title: 'Search tasks',
        parentNamesMap: parentNamesMap,
      ),
    );

    if (selected == null || !mounted) return;
    await provider.navigateToTask(selected);
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
    final childIds = children.map((c) => c.id!).toList();
    final blockedIds = await provider.getBlockedChildIds(childIds);
    final eligible = children.where((c) => !blockedIds.contains(c.id)).toList();

    if (!mounted) return;

    final action = await showDialog<RandomResultAction>(
      context: context,
      builder: (_) => RandomResultDialog(
        task: task,
        hasChildren: eligible.isNotEmpty,
      ),
    );

    if (!mounted) return;

    switch (action) {
      case RandomResultAction.goDeeper:
        // Pick random from this task's non-blocked children
        if (eligible.isNotEmpty) {
          final deeper = eligible[
              (eligible.length == 1) ? 0 : DateTime.now().millisecondsSinceEpoch % eligible.length];
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

  Future<void> _addDependencyToTask(Task task) async {
    final provider = context.read<TaskProvider>();
    final allTasks = await provider.getAllTasks();
    final parentNamesMap = await provider.getParentNamesMap();

    // Filter out: the task itself
    final candidates = allTasks.where((t) => t.id != task.id).toList();

    // Prioritize siblings (other tasks under the same parent).
    // On leaf view, provider.tasks is empty — look up siblings from the parent.
    Set<int> siblingIds;
    if (provider.tasks.isNotEmpty) {
      siblingIds = provider.tasks
          .map((t) => t.id!)
          .where((id) => id != task.id)
          .toSet();
    } else {
      // Leaf view: get siblings from the parent above
      final parentIds = await provider.getParentIds(task.id!);
      if (parentIds.isNotEmpty) {
        final siblings = await provider.getChildren(parentIds.first);
        siblingIds = siblings
            .map((t) => t.id!)
            .where((id) => id != task.id)
            .toSet();
      } else {
        siblingIds = {};
      }
    }

    if (!mounted) return;

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => TaskPickerDialog(
        candidates: candidates,
        title: 'Do "${task.name}" after...',
        parentNamesMap: parentNamesMap,
        priorityIds: siblingIds,
      ),
    );

    if (selected == null || !mounted) return;

    final success = await provider.addDependency(task.id!, selected.id!);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot add: would create a cycle')),
      );
    }
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
                      style: const TextStyle(
                        fontFamily: 'Outfit',
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
                if (!provider.isRoot && provider.currentParent?.hasUrl == true && provider.tasks.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.link),
                    onPressed: () {
                      final uri = Uri.tryParse(provider.currentParent!.url!);
                      if (uri != null) {
                        launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
                    tooltip: 'Open link',
                  ),
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _searchTask,
                  tooltip: 'Search',
                ),
                IconButton(
                  icon: const Icon(Icons.archive_outlined),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CompletedTasksScreen(),
                      ),
                    );
                  },
                  tooltip: 'Archive',
                ),
                IconButton(
                  icon: const Icon(Icons.account_tree_outlined),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const DagViewScreen(),
                      ),
                    );
                  },
                  tooltip: 'Task graph',
                ),
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, _) {
                    return IconButton(
                      icon: Icon(themeProvider.icon, size: 28),
                      onPressed: themeProvider.toggle,
                      tooltip: 'Toggle theme',
                    );
                  },
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (value) {
                    final task = provider.currentParent;
                    switch (value) {
                      case 'rename':
                        if (task != null) _renameTask(task);
                      case 'add_parent':
                        if (task != null) _addParentToTask(task);
                      case 'edit_link':
                        if (task != null) {
                          LeafTaskDetail.showEditUrlDialog(
                            context,
                            task.url,
                            (url) => _updateUrl(task, url),
                          );
                        }
                      case 'do_after':
                        if (task != null) _addDependencyToTask(task);
                      case 'export':
                        BackupService.exportDatabase(context);
                      case 'import':
                        BackupService.importDatabase(
                          context,
                          context.read<TaskProvider>(),
                        );
                    }
                  },
                  itemBuilder: (_) => [
                    if (!provider.isRoot && provider.tasks.isEmpty) ...[
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Rename'),
                      ),
                      const PopupMenuItem(
                        value: 'add_parent',
                        child: Text('Also show under...'),
                      ),
                    ],
                    if (!provider.isRoot && provider.tasks.isNotEmpty) ...[
                      PopupMenuItem(
                        value: 'edit_link',
                        child: Text(
                          provider.currentParent?.hasUrl == true
                              ? 'Edit link'
                              : 'Add link',
                        ),
                      ),
                    ],
                    if (!provider.isRoot) ...[
                      const PopupMenuItem(
                        value: 'do_after',
                        child: Text('Do after...'),
                      ),
                      const PopupMenuDivider(),
                    ],
                    const PopupMenuItem(
                      value: 'export',
                      child: Text('Export backup'),
                    ),
                    const PopupMenuItem(
                      value: 'import',
                      child: Text('Import backup'),
                    ),
                  ],
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
                            onMove: provider.isRoot
                                ? null
                                : () => _moveTask(task),
                            onRename: () => _renameTask(task),
                            onAddDependency: () => _addDependencyToTask(task),
                            hasStartedDescendant: provider.startedDescendantIds.contains(task.id),
                            isBlocked: provider.blockedTaskIds.contains(task.id),
                            blockedByName: provider.blockedByNames[task.id],
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
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (provider.tasks.isNotEmpty)
                  FloatingActionButton(
                    heroTag: 'pickRandom',
                    onPressed: _pickRandom,
                    child: const Icon(Icons.shuffle),
                  ),
                if (provider.tasks.isNotEmpty)
                  const SizedBox(height: 12),
                if (!provider.isRoot)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton(
                        heroTag: 'linkTask',
                        onPressed: _linkExistingTask,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        foregroundColor: Theme.of(context).colorScheme.onSurface,
                        child: const Icon(Icons.link),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onLongPress: _brainDump,
                        child: FloatingActionButton(
                          heroTag: 'addTask',
                          onPressed: _showFabOptions,
                          child: const Icon(Icons.add),
                        ),
                      ),
                    ],
                  )
                else
                  GestureDetector(
                    onLongPress: _brainDump,
                    child: FloatingActionButton(
                      heroTag: 'addTask',
                      onPressed: _showFabOptions,
                      child: const Icon(Icons.add),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
