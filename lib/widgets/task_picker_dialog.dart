import 'package:flutter/material.dart';
import '../models/task.dart';

class TaskPickerDialog extends StatefulWidget {
  final List<Task> candidates;
  final String title;
  /// Map of task ID → list of parent names, for showing context.
  final Map<int, List<String>> parentNamesMap;

  const TaskPickerDialog({
    super.key,
    required this.candidates,
    this.title = 'Select a task',
    this.parentNamesMap = const {},
  });

  @override
  State<TaskPickerDialog> createState() => _TaskPickerDialogState();
}

class _TaskPickerDialogState extends State<TaskPickerDialog> {
  String _filter = '';

  List<Task> get _filtered {
    if (_filter.isEmpty) return widget.candidates;
    final lower = _filter.toLowerCase();
    return widget.candidates
        .where((t) =>
            t.name.toLowerCase().contains(lower) ||
            (_contextFor(t.id!)?.toLowerCase().contains(lower) ?? false))
        .toList();
  }

  String? _contextFor(int taskId) {
    final parents = widget.parentNamesMap[taskId];
    if (parents == null || parents.isEmpty) return null;
    return parents.join(', ');
  }

  @override
  Widget build(BuildContext context) {
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
                child: _filtered.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No matching tasks'),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: _filtered.length,
                        itemBuilder: (context, index) {
                          final task = _filtered[index];
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
