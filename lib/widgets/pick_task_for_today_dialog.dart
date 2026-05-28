import 'package:flutter/material.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';

/// Dialog for picking an existing task to pin into Today's 5.
/// Mirrors the triage dialog pattern: always-visible search bar at top
/// and a browse tree below. Search overrides the browse view when the
/// filter is non-empty.
///
/// Returns the selected [Task] (always a leaf), or `null` if cancelled.
class PickTaskForTodayDialog extends StatefulWidget {
  final TaskProvider provider;

  /// Task IDs to hide (typically tasks already in Today's 5).
  final Set<int> excludeIds;

  const PickTaskForTodayDialog({
    super.key,
    required this.provider,
    this.excludeIds = const {},
  });

  @override
  State<PickTaskForTodayDialog> createState() => _PickTaskForTodayDialogState();
}

class _PickTaskForTodayDialogState extends State<PickTaskForTodayDialog> {
  // Browse state
  final List<Task?> _browseStack = [];
  Task? _browseParent;
  List<Task> _browseChildren = [];
  bool _browseLoading = true;
  bool _browseShowAll = false;

  // Search state (lazy-loaded on first keystroke)
  final _searchController = TextEditingController();
  String _searchFilter = '';
  List<Task>? _allLeaves;
  Map<int, List<String>>? _parentNamesMap;

  // Set of leaf task IDs — used in browse to decide tap = pin vs drill in.
  Set<int>? _leafIds;

  @override
  void initState() {
    super.initState();
    _loadBrowseChildren();
    _loadLeafIds();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLeafIds() async {
    final leaves = await widget.provider.getAllLeafTasks();
    if (!mounted) return;
    setState(() => _leafIds = leaves.map((t) => t.id!).toSet());
  }

  Future<void> _loadBrowseChildren() async {
    setState(() => _browseLoading = true);
    try {
      final children = _browseParent == null
          ? await widget.provider.getRootTasks()
          : await widget.provider.getChildren(_browseParent!.id!);
      // At root, hide inbox tasks — they're not natural pin targets.
      // Always hide tasks already in Today's 5.
      final filtered = children.where((t) {
        if (widget.excludeIds.contains(t.id)) return false;
        if (_browseParent == null && t.isInbox) return false;
        return true;
      }).toList();
      filtered.sort((a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _browseChildren = filtered;
        _browseLoading = false;
        _browseShowAll = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _browseChildren = [];
        _browseLoading = false;
      });
    }
  }

  Future<void> _browseInto(Task task) async {
    _browseStack.add(_browseParent);
    setState(() => _browseParent = task);
    await _loadBrowseChildren();
  }

  Future<void> _browseBack() async {
    if (_browseStack.isEmpty) return;
    setState(() => _browseParent = _browseStack.removeLast());
    await _loadBrowseChildren();
  }

  Future<void> _loadSearchData() async {
    if (_allLeaves != null) return;
    try {
      final leaves = await widget.provider.getAllLeafTasks();
      final parentNamesMap = await widget.provider.getParentNamesMap();
      if (!mounted) return;
      setState(() {
        _allLeaves = leaves
            .where((t) => !widget.excludeIds.contains(t.id))
            .toList();
        _parentNamesMap = parentNamesMap;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _allLeaves = [];
        _parentNamesMap = {};
      });
    }
  }

  List<Task> get _filteredSearch {
    if (_allLeaves == null) return [];
    final lower = _searchFilter.toLowerCase();
    return _allLeaves!.where((t) {
      if (t.name.toLowerCase().contains(lower)) return true;
      final parents = _parentNamesMap?[t.id!];
      if (parents != null) {
        return parents.any((p) => p.toLowerCase().contains(lower));
      }
      return false;
    }).toList();
  }

  bool get _isSearching => _searchFilter.isNotEmpty;

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
                "Pin a task to Today’s 5",
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                maxLength: 500,
                decoration: InputDecoration(
                  hintText: 'Search tasks...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  counterText: '',
                  suffixIcon: _isSearching
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchFilter = '');
                          },
                        )
                      : null,
                ),
                onChanged: (value) {
                  if (value.isNotEmpty && _allLeaves == null) {
                    _loadSearchData();
                  }
                  setState(() => _searchFilter = value);
                },
              ),
              const SizedBox(height: 8),
              Flexible(
                child: _isSearching
                    ? _buildSearchResults()
                    : _buildBrowseTree(),
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

  Widget _buildTaskCard(
    Task task, {
    String? subtitle,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: colorScheme.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(
                  // Folder icon for non-leaves, push-pin outline for leaves —
                  // hints at what the tap will do (drill in vs. pin).
                  _leafIds?.contains(task.id) ?? false
                      ? Icons.push_pin_outlined
                      : Icons.folder_outlined,
                  size: 18,
                  color: colorScheme.primary.withAlpha(180),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.name,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_allLeaves == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final filtered = _filteredSearch;
    if (filtered.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No matching tasks'),
        ),
      );
    }
    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final task = filtered[index];
        final parents = _parentNamesMap?[task.id!];
        final subtitle = parents != null && parents.isNotEmpty
            ? 'under ${parents.join(', ')}'
            : null;
        return _buildTaskCard(
          task,
          subtitle: subtitle,
          onTap: () => Navigator.pop(context, task),
        );
      },
    );
  }

  Widget _buildBrowseTree() {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_browseParent != null) ...[
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: _browseBack,
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Text(
                  _browseParent!.name,
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Divider(height: 1),
          const SizedBox(height: 6),
        ],
        Expanded(
          child: _browseLoading
              ? const Center(child: CircularProgressIndicator())
              : _browseChildren.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No tasks here'),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _browseShowAll
                          ? _browseChildren.length
                          : _browseChildren.length.clamp(0, 6),
                      itemBuilder: (context, index) {
                        final child = _browseChildren[index];
                        final isLeaf = _leafIds?.contains(child.id) ?? false;
                        return _buildTaskCard(
                          child,
                          onTap: () => isLeaf
                              ? Navigator.pop(context, child)
                              : _browseInto(child),
                          trailing: isLeaf
                              ? Icon(Icons.check_circle_outline,
                                  size: 20, color: colorScheme.primary)
                              : const Icon(Icons.chevron_right, size: 20),
                        );
                      },
                    ),
        ),
        if (!_browseShowAll && _browseChildren.length > 6)
          TextButton(
            onPressed: () => setState(() => _browseShowAll = true),
            child: Text('Show all ${_browseChildren.length} items'),
          ),
      ],
    );
  }
}
