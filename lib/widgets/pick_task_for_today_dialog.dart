import 'package:flutter/material.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import 'task_picker_parts.dart';

/// Dialog for picking an existing task to pin into Today's 5.
///
/// Always-visible search bar at top with a browse tree below; search overrides
/// the browse view when the filter is non-empty. Shares its row card, search
/// field, and name/parent search filter with the triage dialog via
/// `task_picker_parts.dart`.
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

  // Search state
  final _searchController = TextEditingController();
  String _searchFilter = '';
  // Leaves (minus excluded) are the search candidates. Loaded once up front and
  // reused — this also derives _leafIds, so getAllLeafTasks runs ONCE for the
  // whole dialog rather than separately for browse-icons and search.
  List<Task>? _searchLeaves;
  Map<int, List<String>>? _parentNamesMap; // lazy on first keystroke
  List<Task> _searchResults = [];

  // All leaf ids — used in browse to decide tap = pin vs. drill in.
  Set<int>? _leafIds;

  @override
  void initState() {
    super.initState();
    _loadBrowseChildren();
    _loadLeaves();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLeaves() async {
    final leaves = await widget.provider.getAllLeafTasks();
    if (!mounted) return;
    setState(() {
      _leafIds = leaves.map((t) => t.id!).toSet();
      _searchLeaves =
          leaves.where((t) => !widget.excludeIds.contains(t.id)).toList();
    });
    // If the user typed before leaves finished loading, fill in results now.
    if (_isSearching) _recomputeSearchResults();
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

  /// Loads parent names (for the "under X" subtitle and parent-name search)
  /// lazily on the first keystroke, then recomputes the filtered results.
  Future<void> _loadSearchData() async {
    if (_parentNamesMap != null) return;
    try {
      final parentNamesMap = await widget.provider.getParentNamesMap();
      if (!mounted) return;
      setState(() => _parentNamesMap = parentNamesMap);
    } catch (_) {
      if (!mounted) return;
      setState(() => _parentNamesMap = {});
    }
    _recomputeSearchResults();
  }

  void _onSearchChanged(String value) {
    _searchFilter = value;
    if (value.isNotEmpty && _parentNamesMap == null) {
      _loadSearchData();
    }
    _recomputeSearchResults();
  }

  // Perf: filter once per keystroke into _searchResults instead of re-scanning
  // every leaf (and its parent names) inside build() on every rebuild.
  void _recomputeSearchResults() {
    setState(() {
      _searchResults = filterTasksBySearch(
        _searchLeaves ?? const [],
        _searchFilter,
        _parentNamesMap,
      );
    });
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
              PickerSearchField(
                controller: _searchController,
                isSearching: _isSearching,
                onChanged: _onSearchChanged,
                onClear: () {
                  _searchController.clear();
                  _onSearchChanged('');
                },
              ),
              const SizedBox(height: 8),
              Flexible(
                child:
                    _isSearching ? _buildSearchResults() : _buildBrowseTree(),
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

  Widget _buildSearchResults() {
    if (_searchLeaves == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchResults.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No matching tasks'),
        ),
      );
    }
    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final task = _searchResults[index];
        final parents = _parentNamesMap?[task.id!];
        final subtitle = parents != null && parents.isNotEmpty
            ? 'under ${parents.join(', ')}'
            : null;
        return PickerTaskCard(
          task: task,
          leadingIcon: Icons.push_pin_outlined,
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
                        return PickerTaskCard(
                          task: child,
                          // Folder for non-leaves, push-pin for leaves — hints
                          // at what the tap does (drill in vs. pin).
                          leadingIcon: isLeaf
                              ? Icons.push_pin_outlined
                              : Icons.folder_outlined,
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
