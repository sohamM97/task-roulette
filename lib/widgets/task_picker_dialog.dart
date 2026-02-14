import 'package:flutter/material.dart';
import '../models/task.dart';

class TaskPickerDialog extends StatefulWidget {
  final List<Task> candidates;
  final String title;
  /// Map of task ID → list of parent names, for showing context.
  final Map<int, List<String>> parentNamesMap;
  /// Task IDs to show first (e.g. current siblings).
  final Set<int> priorityIds;

  const TaskPickerDialog({
    super.key,
    required this.candidates,
    this.title = 'Select a task',
    this.parentNamesMap = const {},
    this.priorityIds = const {},
  });

  @override
  State<TaskPickerDialog> createState() => _TaskPickerDialogState();
}

class _TaskPickerDialogState extends State<TaskPickerDialog> {
  String _filter = '';

  List<Task> get _filtered {
    final base = _filter.isEmpty
        ? widget.candidates
        : widget.candidates
            .where((t) =>
                t.name.toLowerCase().contains(_filter.toLowerCase()) ||
                (_contextFor(t.id!)?.toLowerCase().contains(_filter.toLowerCase()) ?? false))
            .toList();
    if (widget.priorityIds.isEmpty) return base;
    final priority = <Task>[];
    final rest = <Task>[];
    for (final t in base) {
      if (widget.priorityIds.contains(t.id)) {
        priority.add(t);
      } else {
        rest.add(t);
      }
    }
    return [...priority, ...rest];
  }

  String? _contextFor(int taskId) {
    final parents = widget.parentNamesMap[taskId];
    if (parents == null || parents.isEmpty) return null;
    return parents.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered; // compute once, not per-access
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 500),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search tasks...',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _filter = value),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: filtered.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No matching tasks'),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final task = filtered[index];
                          final context_ = _contextFor(task.id!);
                          return ListTile(
                            title: Text(task.name),
                            subtitle: context_ != null
                                ? Text(
                                    'under $context_',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  )
                                : null,
                            onTap: () => Navigator.pop(context, task),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
