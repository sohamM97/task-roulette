import 'package:flutter/material.dart';
import '../data/database_helper.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';

/// Result of the triage dialog.
/// - [parent] non-null: file under that parent
/// - [keepAtTopLevel] true: clear inbox flag, keep at root (intentionally organized)
/// - null return from dialog: cancelled, do nothing
class TriageResult {
  final Task? parent;
  final bool keepAtTopLevel;

  const TriageResult({this.parent, this.keepAtTopLevel = false});
}

class TriageDialog extends StatefulWidget {
  final Task task;
  final TaskProvider provider;

  const TriageDialog({
    super.key,
    required this.task,
    required this.provider,
  });

  @override
  State<TriageDialog> createState() => _TriageDialogState();
}

enum _TriagePhase { suggestions, browse, search }

class _TriageDialogState extends State<TriageDialog> {
  _TriagePhase _phase = _TriagePhase.browse;

  // Suggestions state
  List<({Task task, double score})>? _suggestions;
  Map<int, List<String>>? _suggestionParentNames;
  bool _suggestionsLoading = false;

  // Browse state
  final List<Task?> _browseStack = [];
  Task? _browseParent;
  List<Task> _browseChildren = [];
  bool _browseLoading = true;
  bool _browseShowAll = false;

  // Search state
  List<Task>? _allTasks;
  Map<int, List<String>>? _parentNamesMap;
  String _searchFilter = '';

  @override
  void initState() {
    super.initState();
    _loadBrowseChildren();
  }

  // --- Suggestions ---

  Future<void> _loadSuggestions() async {
    if (_suggestionsLoading) return;
    setState(() => _suggestionsLoading = true);
    try {
      final suggestions = await widget.provider.computeParentSuggestions(
        widget.task.name,
        excludeTaskId: widget.task.id,
      );
      // Reuse the cached parent names map (single query) instead of
      // N sequential getAncestorPath calls that cause DB lock warnings.
      _parentNamesMap ??= await widget.provider.getParentNamesMap();
      if (!mounted) return;
      final paths = <int, List<String>>{};
      for (final s in suggestions) {
        final parents = _parentNamesMap?[s.task.id!];
        if (parents != null && parents.isNotEmpty) {
          paths[s.task.id!] = parents;
        }
      }
      setState(() {
        _suggestions = suggestions;
        _suggestionParentNames = paths;
        _suggestionsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _suggestions = [];
        _suggestionsLoading = false;
      });
    }
  }

  // --- Browse ---

  Future<void> _loadBrowseChildren() async {
    setState(() => _browseLoading = true);
    try {
      List<Task> children;
      if (_browseParent == null) {
        children = await DatabaseHelper().getRootTasks();
      } else {
        children = await widget.provider.getChildren(_browseParent!.id!);
      }
      // Sort: keyword matches first, then alphabetical
      final taskNameLower = widget.task.name.toLowerCase();
      children.sort((a, b) {
        final aMatch = a.name.toLowerCase().contains(taskNameLower) ? 0 : 1;
        final bMatch = b.name.toLowerCase().contains(taskNameLower) ? 0 : 1;
        if (aMatch != bMatch) return aMatch.compareTo(bMatch);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      children = children.where((t) => t.id != widget.task.id).toList();
      if (!mounted) return;
      setState(() {
        _browseChildren = children;
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
    _browseParent = task;
    await _loadBrowseChildren();
  }

  Future<void> _browseBack() async {
    if (_browseStack.isEmpty) return;
    _browseParent = _browseStack.removeLast();
    await _loadBrowseChildren();
  }

  // --- Search ---

  Future<void> _loadSearchData() async {
    if (_allTasks != null) return; // already loaded
    try {
      // Sequential queries to avoid sqflite deadlock
      final allTasks = await widget.provider.getAllTasks();
      _parentNamesMap ??= await widget.provider.getParentNamesMap();
      if (!mounted) return;
      setState(() {
        _allTasks = allTasks.where((t) => t.id != widget.task.id).toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _allTasks = [];
        _parentNamesMap ??= {};
      });
    }
  }

  List<Task> get _filteredSearch {
    if (_allTasks == null) return [];
    if (_searchFilter.isEmpty) return _allTasks!;
    final lower = _searchFilter.toLowerCase();
    return _allTasks!.where((t) {
      if (t.name.toLowerCase().contains(lower)) return true;
      final parents = _parentNamesMap?[t.id!];
      if (parents != null) {
        return parents.any((p) => p.toLowerCase().contains(lower));
      }
      return false;
    }).toList();
  }

  // --- Build ---

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
                'File "${widget.task.name}"',
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: switch (_phase) {
                  _TriagePhase.suggestions => _buildSuggestions(),
                  _TriagePhase.browse => _buildBrowse(),
                  _TriagePhase.search => _buildSearch(),
                },
              ),
              const SizedBox(height: 8),
              _buildBottomActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTaskCard(
    Task task, {
    String? subtitle,
    VoidCallback? onTap,
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
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
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

  Widget _buildSuggestions() {
    if (_suggestionsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final suggestions = _suggestions ?? [];
    if (suggestions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No suggestions — try browsing or searching'),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: suggestions.length,
      itemBuilder: (context, index) {
        final s = suggestions[index];
        final parents = _suggestionParentNames?[s.task.id!];
        final subtitle =
            parents != null && parents.isNotEmpty ? 'under ${parents.join(', ')}' : null;
        return _buildTaskCard(
          s.task,
          subtitle: subtitle,
          onTap: () => Navigator.pop(context, TriageResult(parent: s.task)),
          trailing: const Icon(Icons.arrow_forward_rounded, size: 18),
        );
      },
    );
  }

  Widget _buildBrowse() {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (_browseStack.isNotEmpty || _browseParent != null)
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: _browseBack,
                visualDensity: VisualDensity.compact,
              ),
            Expanded(
              child: Text(
                _browseParent?.name ?? 'Top level',
                style: Theme.of(context).textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (_browseParent != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FilledButton.tonal(
              onPressed: () =>
                  Navigator.pop(context, TriageResult(parent: _browseParent)),
              child: Text('Place under "${_browseParent!.name}"'),
            ),
          ),
        const Divider(height: 1),
        const SizedBox(height: 6),
        if (_browseParent == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: colorScheme.primaryContainer.withAlpha(80),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.pop(
                    context, const TriageResult(keepAtTopLevel: true)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.vertical_align_top, size: 18,
                          color: colorScheme.primary),
                      const SizedBox(width: 10),
                      Text(
                        'Keep at top level',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Expanded(
          child: _browseLoading
              ? const Center(child: CircularProgressIndicator())
              : _browseChildren.isEmpty
                  ? const Center(
                      child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('No sub-tasks here')))
                  : ListView.builder(
                      itemCount: _browseShowAll
                          ? _browseChildren.length
                          : _browseChildren.length.clamp(0, 6),
                      itemBuilder: (context, index) {
                        final child = _browseChildren[index];
                        return _buildTaskCard(
                          child,
                          onTap: () => _browseInto(child),
                          trailing: IconButton(
                            icon: Icon(Icons.check_circle_outline,
                                size: 20, color: colorScheme.primary),
                            tooltip: 'Place here',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => Navigator.pop(
                                context, TriageResult(parent: child)),
                          ),
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

  Widget _buildSearch() {
    final filtered = _filteredSearch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          autofocus: true,
          maxLength: 500,
          decoration: const InputDecoration(
            hintText: 'Search tasks...',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
            counterText: '',
          ),
          onChanged: (value) => setState(() => _searchFilter = value),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _allTasks == null
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
                  ? const Center(
                      child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No matching tasks')))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final task = filtered[index];
                        final parents = _parentNamesMap?[task.id!];
                        final subtitle =
                            parents != null && parents.isNotEmpty
                                ? 'under ${parents.join(', ')}'
                                : null;
                        return _buildTaskCard(
                          task,
                          subtitle: subtitle,
                          onTap: () => Navigator.pop(
                              context, TriageResult(parent: task)),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildBottomActions() {
    return Wrap(
      spacing: 8,
      alignment: WrapAlignment.end,
      children: [
        if (_phase != _TriagePhase.browse)
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Browse'),
            onPressed: () {
              setState(() {
                _phase = _TriagePhase.browse;
                _browseStack.clear();
                _browseParent = null;
                _browseShowAll = false;
              });
              _loadBrowseChildren();
            },
          ),
        if (_phase != _TriagePhase.search)
          TextButton.icon(
            icon: const Icon(Icons.search, size: 18),
            label: const Text('Search'),
            onPressed: () {
              setState(() {
                _phase = _TriagePhase.search;
                _searchFilter = '';
              });
              _loadSearchData();
            },
          ),
        if (_phase == _TriagePhase.browse || _phase == _TriagePhase.search)
          TextButton.icon(
            icon: const Icon(Icons.lightbulb_outline, size: 18),
            label: const Text('Suggestions'),
            onPressed: () {
              setState(() => _phase = _TriagePhase.suggestions);
              if (_suggestions == null) _loadSuggestions();
            },
          ),
      ],
    );
  }
}
