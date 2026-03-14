import 'package:flutter/material.dart';
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
  final int remainingCount;

  const TriageDialog({
    super.key,
    required this.task,
    required this.provider,
    this.remainingCount = 0,
  });

  @override
  State<TriageDialog> createState() => _TriageDialogState();
}

enum _TriagePhase { suggestions, browse }

class _TriageDialogState extends State<TriageDialog> {
  _TriagePhase _phase = _TriagePhase.suggestions;

  // Suggestions state
  List<({Task task, double score})>? _suggestions;
  Map<int, List<String>>? _suggestionParentNames;
  bool _suggestionsLoading = false;

  // Browse + search state (unified)
  final List<Task?> _browseStack = [];
  Task? _browseParent;
  List<Task> _browseChildren = [];
  bool _browseLoading = true;
  bool _browseShowAll = false;
  final _searchController = TextEditingController();
  String _searchFilter = '';
  List<Task>? _allTasks;
  Map<int, List<String>>? _parentNamesMap;

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
    _loadBrowseChildren(); // pre-load for quick switch
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
      _parentNamesMap ??= await widget.provider.getParentNamesMap();
      if (!mounted) return;
      final paths = <int, List<String>>{};
      for (final s in suggestions) {
        final parents = _parentNamesMap?[s.task.id!];
        if (parents != null && parents.isNotEmpty) {
          paths[s.task.id!] = parents;
        }
      }
      if (suggestions.isEmpty) {
        // No useful suggestions — fall back to browse
        setState(() {
          _suggestions = suggestions;
          _suggestionParentNames = paths;
          _suggestionsLoading = false;
          _phase = _TriagePhase.browse;
        });
      } else {
        setState(() {
          _suggestions = suggestions;
          _suggestionParentNames = paths;
          _suggestionsLoading = false;
        });
      }
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
        children = await widget.provider.getRootTasks();
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
      children = children.where((t) {
        if (t.id == widget.task.id) return false;
        // At root level, hide other inbox tasks — they're not valid filing targets
        if (_browseParent == null && t.isInbox) return false;
        return true;
      }).toList();
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

  // --- Search data (loaded lazily when user starts typing) ---

  Future<void> _loadSearchData() async {
    if (_allTasks != null) return;
    try {
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

  bool get _isSearching => _searchFilter.isNotEmpty;

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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'File "${widget.task.name}"',
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.remainingCount > 0)
                    Text(
                      '+${widget.remainingCount} more',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // Search bar — always visible regardless of phase
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
                  if (value.isNotEmpty && _allTasks == null) _loadSearchData();
                  setState(() => _searchFilter = value);
                },
              ),
              const SizedBox(height: 8),
              Flexible(
                child: _isSearching
                    ? _buildSearchResults()
                    : switch (_phase) {
                        _TriagePhase.suggestions => _buildSuggestions(),
                        _TriagePhase.browse => _buildBrowseTree(),
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
                Icon(Icons.folder_outlined, size: 18,
                    color: colorScheme.primary.withAlpha(180)),
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

  Widget _buildKeepAtTopLevel() {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () =>
            Navigator.pop(context, const TriageResult(keepAtTopLevel: true)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.vertical_align_top, size: 16,
                  color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Keep at top level',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
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
    final colorScheme = Theme.of(context).colorScheme;
    // +2 for "Keep at top level" and "Suggested" label
    return ListView.builder(
      shrinkWrap: true,
      itemCount: suggestions.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) return _buildKeepAtTopLevel();
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Suggested',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
          );
        }
        final s = suggestions[index - 2];
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

  Widget _buildSearchResults() {
    if (_allTasks == null) {
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
              TextButton.icon(
                onPressed: () =>
                    Navigator.pop(context, TriageResult(parent: _browseParent)),
                icon: Icon(Icons.check, size: 16, color: colorScheme.primary),
                label: Text('Here',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                  ),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const Divider(height: 1),
          const SizedBox(height: 6),
        ],
        if (_browseParent == null) _buildKeepAtTopLevel(),
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

  Widget _buildBottomActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (_phase == _TriagePhase.browse)
          TextButton.icon(
            icon: const Icon(Icons.lightbulb_outline, size: 18),
            label: const Text('Suggestions'),
            onPressed: () {
              setState(() => _phase = _TriagePhase.suggestions);
              if (_suggestions == null) _loadSuggestions();
            },
          ),
        if (_phase == _TriagePhase.suggestions)
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Browse'),
            onPressed: () {
              setState(() {
                _phase = _TriagePhase.browse;
                _searchFilter = '';
                _searchController.clear();
                _browseStack.clear();
                _browseParent = null;
                _browseShowAll = false;
              });
              _loadBrowseChildren();
            },
          ),
      ],
    );
  }
}
