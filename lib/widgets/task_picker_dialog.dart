import 'dart:async';

import 'package:flutter/material.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import 'task_picker_parts.dart';

/// Opt-in configuration that switches [TaskPickerDialog] into *browse mode*.
///
/// In browse mode the default (non-search) view is a live browse tree loaded
/// from [provider] (drill into non-leaf tasks, tap a leaf to select it), and
/// the search pool is all leaf tasks minus [excludeIds]. When this is null the
/// dialog runs in *flat mode*: a static, caller-supplied `candidates` list with
/// priority-tier ranking.
class TaskBrowseConfig {
  final TaskProvider provider;

  /// Task IDs to hide from both browse and search (e.g. tasks already pinned).
  final Set<int> excludeIds;

  const TaskBrowseConfig({
    required this.provider,
    this.excludeIds = const {},
  });
}

/// A single dialog for picking a task, with two modes selected by [browse]:
///
/// * **Flat mode** (default, `browse == null`) — searches/ranks a static
///   [candidates] list. Used by the All Tasks search, link/move/add-parent, and
///   dependency pickers. Supports priority tiers, a [headerAction], and the
///   [onCreateTask] empty-state affordance. Returns the tapped [Task] via
///   `Navigator.pop`.
/// * **Browse mode** (`browse != null`) — a search bar over a live browse tree
///   (drill into non-leaves, select leaves). Used by the Today's 5 "pin a task"
///   flow. The search pool is all leaves minus `excludeIds`.
///
/// Both modes share the same visual chrome (card rows, search field, empty
/// state) via `task_picker_parts.dart`, so they look and behave consistently.
class TaskPickerDialog extends StatefulWidget {
  /// Flat-mode search pool. Ignored in browse mode (which self-loads leaves).
  final List<Task> candidates;
  final String title;

  /// Map of task ID → list of parent names, for the "under X" subtitle and
  /// (flat mode) parent-name matching.
  final Map<int, List<String>> parentNamesMap;

  /// Task IDs to show first (e.g. current siblings). Flat mode only.
  final Set<int> priorityIds;

  /// Task IDs to show after primary priority (e.g. parent's siblings). Flat
  /// mode only.
  final Set<int> secondaryPriorityIds;

  /// Optional action widget shown before the list (e.g. "Remove dependency").
  /// Flat mode only.
  final Widget? headerAction;

  /// Optional opt-in: when set, an empty result set with a non-blank query
  /// shows a "Create ..." button that invokes this with the trimmed query
  /// (e.g. search → create a new task with the searched name). Left null by the
  /// link/move/dependency pickers, which must not offer task creation.
  final void Function(String query)? onCreateTask;

  /// When non-null, runs in browse mode (see [TaskBrowseConfig]).
  final TaskBrowseConfig? browse;

  const TaskPickerDialog({
    super.key,
    this.candidates = const [],
    this.title = 'Select a task',
    this.parentNamesMap = const {},
    this.priorityIds = const {},
    this.secondaryPriorityIds = const {},
    this.headerAction,
    this.onCreateTask,
    this.browse,
  });

  @override
  State<TaskPickerDialog> createState() => _TaskPickerDialogState();
}

class _TaskPickerDialogState extends State<TaskPickerDialog> {
  // ---- Flat-mode state ----
  String _filter = '';
  Timer? _debounce;
  // CR-fix M-48: controller on the flat field so "Create" reads the LIVE text,
  // not the debounced _filter. Without it, a correction typed within the 200ms
  // debounce window was created under the previous (stale) query.
  final _flatController = TextEditingController();

  // ---- Browse-mode state ----
  final List<Task?> _browseStack = [];
  Task? _browseParent;
  List<Task> _browseChildren = [];
  bool _browseLoading = true;
  bool _browseShowAll = false;
  final _searchController = TextEditingController();
  String _searchFilter = '';
  // Leaves (minus excluded) are the search candidates. Loaded once up front and
  // reused — this also derives _leafIds, so getAllLeafTasks runs ONCE for the
  // whole dialog rather than separately for browse-icons and search.
  List<Task>? _searchLeaves;
  Map<int, List<String>>? _parentNamesMap; // lazy on first keystroke
  List<Task> _searchResults = [];
  // All leaf ids — used in browse to decide tap = select vs. drill in.
  Set<int>? _leafIds;
  // Trimmed/lowercased names of leaves that ARE excluded (e.g. already in
  // Today's 5). Used to catch a search for an already-in task's exact name so
  // the empty state doesn't offer "Create" and let the user make a duplicate.
  Set<String> _excludedLeafNames = {};

  bool get _browsing => widget.browse != null;
  TaskProvider get _provider => widget.browse!.provider;
  Set<int> get _excludeIds => widget.browse!.excludeIds;

  bool get _isSearching =>
      _browsing ? _searchFilter.isNotEmpty : _filter.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_browsing) {
      _loadBrowseChildren();
      _loadLeaves();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _flatController.dispose();
    super.dispose();
  }

  // ========================= Browse mode =========================

  Future<void> _loadLeaves() async {
    final leaves = await _provider.getAllLeafTasks();
    if (!mounted) return;
    setState(() {
      _leafIds = leaves.map((t) => t.id!).toSet();
      _searchLeaves =
          leaves.where((t) => !_excludeIds.contains(t.id)).toList();
      _excludedLeafNames = leaves
          .where((t) => _excludeIds.contains(t.id))
          .map((t) => t.name.trim().toLowerCase())
          .toSet();
    });
    // If the user typed before leaves finished loading, fill in results now.
    if (_isSearching) _recomputeSearchResults();
  }

  Future<void> _loadBrowseChildren() async {
    setState(() => _browseLoading = true);
    try {
      final children = _browseParent == null
          ? await _provider.getRootTasks()
          : await _provider.getChildren(_browseParent!.id!);
      // At root, hide inbox tasks — they're not natural pin targets.
      // Always hide excluded tasks (e.g. already in Today's 5).
      final filtered = children.where((t) {
        if (_excludeIds.contains(t.id)) return false;
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
      final parentNamesMap = await _provider.getParentNamesMap();
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

  Widget _buildSearchResults() {
    if (_searchLeaves == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchResults.isEmpty) {
      // Bug fix: excluded leaves (e.g. tasks already in Today's 5) are kept out
      // of the search pool, so searching an already-in task's exact name yields
      // no results and the "Create" button would let the user make a duplicate
      // and pin it twice. If the query exactly matches an excluded leaf, say so
      // and suppress the create affordance instead.
      final trimmedQuery = _searchFilter.trim().toLowerCase();
      final matchesExcluded = trimmedQuery.isNotEmpty &&
          _excludedLeafNames.contains(trimmedQuery);
      return PickerSearchEmptyState(
        query: _searchFilter,
        onCreateTask: matchesExcluded ? null : widget.onCreateTask,
        message: matchesExcluded
            ? '"${_searchFilter.trim()}" is already in Today’s 5'
            : null,
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
                          // at what the tap does (drill in vs. select).
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

  // ========================= Flat mode =========================

  List<Task> get _filtered {
    final base = _filter.isEmpty
        ? widget.candidates
        : widget.candidates
            .where((t) =>
                t.name.toLowerCase().contains(_filter.toLowerCase()) ||
                (_contextFor(t.id!)?.toLowerCase().contains(_filter.toLowerCase()) ?? false))
            .toList();
    // Name matches always rank above context-only matches, regardless of tier.
    // Within each group, priority tiers still apply.
    if (_filter.isNotEmpty) {
      final lowerFilter = _filter.toLowerCase();
      final nameMatches = <Task>[];
      final contextOnly = <Task>[];
      for (final t in base) {
        if (t.name.toLowerCase().contains(lowerFilter)) {
          nameMatches.add(t);
        } else {
          contextOnly.add(t);
        }
      }
      if (widget.priorityIds.isEmpty && widget.secondaryPriorityIds.isEmpty) {
        return [...nameMatches, ...contextOnly];
      }
      List<Task> sortByTier(List<Task> tasks) {
        final priority = <Task>[];
        final secondary = <Task>[];
        final rest = <Task>[];
        for (final t in tasks) {
          if (widget.priorityIds.contains(t.id)) {
            priority.add(t);
          } else if (widget.secondaryPriorityIds.contains(t.id)) {
            secondary.add(t);
          } else {
            rest.add(t);
          }
        }
        return [...priority, ...secondary, ...rest];
      }
      return [...sortByTier(nameMatches), ...sortByTier(contextOnly)];
    }
    if (widget.priorityIds.isEmpty && widget.secondaryPriorityIds.isEmpty) return base;
    final priority = <Task>[];
    final secondary = <Task>[];
    final rest = <Task>[];
    for (final t in base) {
      if (widget.priorityIds.contains(t.id)) {
        priority.add(t);
      } else if (widget.secondaryPriorityIds.contains(t.id)) {
        secondary.add(t);
      } else {
        rest.add(t);
      }
    }
    return [...priority, ...secondary, ...rest];
  }

  String? _contextFor(int taskId) {
    final parents = widget.parentNamesMap[taskId];
    if (parents == null || parents.isEmpty) return null;
    return parents.join(', ');
  }

  Widget _buildFlatBody() {
    final filtered = _filtered; // compute once, not per-access
    if (filtered.isEmpty) {
      return PickerSearchEmptyState(
        query: _filter,
        // CR-fix M-48: source the created name from the live field text (and
        // flush the pending debounce) so a name typed within the 200ms window
        // isn't created under the stale _filter query.
        onCreateTask: widget.onCreateTask == null
            ? null
            : (_) {
                _debounce?.cancel();
                final live = _flatController.text.trim();
                if (live.isNotEmpty) widget.onCreateTask!(live);
              },
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final task = filtered[index];
        final context_ = _contextFor(task.id!);
        // No leading icon: unlike the browse tree (folder/pin convey the tap
        // action), every flat-picker row is just a selectable task.
        return PickerTaskCard(
          task: task,
          subtitle: context_ != null ? 'under $context_' : null,
          onTap: () => Navigator.pop(context, task),
        );
      },
    );
  }

  // ========================= Shared chrome =========================

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
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
                style: _browsing ? textTheme.titleMedium : textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (_browsing)
                PickerSearchField(
                  controller: _searchController,
                  isSearching: _isSearching,
                  onChanged: _onSearchChanged,
                  onClear: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                )
              else
                TextField(
                  controller: _flatController,
                  autofocus: true,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    hintText: 'Search tasks...',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                    counterText: '',
                  ),
                  onChanged: (value) {
                    _debounce?.cancel();
                    // Bug fix: apply an emptied field immediately instead of
                    // debouncing. Otherwise, for ~200ms after clearing a
                    // no-match query, the stale "Create <old query>" button
                    // stays rendered over an empty field and a fast tap would
                    // create a task named after the deleted text.
                    if (value.isEmpty) {
                      setState(() => _filter = '');
                      return;
                    }
                    _debounce = Timer(const Duration(milliseconds: 200), () {
                      if (mounted) setState(() => _filter = value);
                    });
                  },
                ),
              const SizedBox(height: 8),
              // headerAction is a flat-mode affordance (e.g. "Remove
              // dependency"); browse mode never supplies one.
              if (!_browsing &&
                  widget.headerAction != null &&
                  _filter.isEmpty)
                widget.headerAction!,
              Flexible(
                child: _browsing
                    ? (_isSearching
                        ? _buildSearchResults()
                        : _buildBrowseTree())
                    : _buildFlatBody(),
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
