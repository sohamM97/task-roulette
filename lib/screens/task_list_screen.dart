import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../widgets/add_task_dialog.dart';
import '../widgets/random_result_dialog.dart';
import '../widgets/task_item.dart';

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
              title: Text(provider.isRoot ? 'TaskRoulette' : provider.currentParent!.name),
              leading: provider.isRoot
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => provider.navigateBack(),
                    ),
            ),
            body: Column(
              children: [
                if (provider.tasks.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      onPressed: _pickRandom,
                      icon: const Icon(Icons.casino),
                      label: const Text('Pick Random'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 56),
                      ),
                    ),
                  ),
                Expanded(
                  child: provider.tasks.isEmpty
                      ? Center(
                          child: Text(
                            provider.isRoot
                                ? 'No tasks yet.\nTap + to add one!'
                                : 'No subtasks yet.\nTap + to add one!',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: provider.tasks.length,
                          itemBuilder: (context, index) {
                            final task = provider.tasks[index];
                            return TaskItem(
                              task: task,
                              onTap: () => provider.navigateInto(task),
                              onDelete: () => provider.deleteTask(task.id!),
                            );
                          },
                        ),
                ),
              ],
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: _addTask,
              child: const Icon(Icons.add),
            ),
          );
        },
      ),
    );
  }
}
