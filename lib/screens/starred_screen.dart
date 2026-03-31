import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/database_helper.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../utils/display_utils.dart';
import '../widgets/profile_icon.dart';
import '../providers/theme_provider.dart';
import 'completed_tasks_screen.dart';

class StarredScreen extends StatefulWidget {
  final void Function(Task task)? onNavigateToTask;

  const StarredScreen({super.key, this.onNavigateToTask});

  @override
  State<StarredScreen> createState() => StarredScreenState();
}

class StarredScreenState extends State<StarredScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<Task> _starredTasks = [];
  /// taskId → tree preview data
  Map<int, ({List<({Task child, List<Task> grandchildren, int totalGrandchildren})> children, int totalChildren})> _treeData = {};
  /// childId → (blockerId, blockerName) for blocked children across all starred tasks
  Map<int, ({int blockerId, String blockerName})> _blockedInfo = {};
  bool _loading = true;
  TaskProvider? _provider;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _provider = context.read<TaskProvider>();
    _provider!.addListener(_onProviderChanged);
    _loadStarredTasks();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _provider?.removeListener(_onProviderChanged);
    super.dispose();
  }

  void _onProviderChanged() {
    if (!mounted || _loading) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 100), () {
      if (mounted && !_loading) _loadStarredTasks();
    });
  }

  Future<void> _loadStarredTasks() async {
    _loading = true;
    final provider = context.read<TaskProvider>();
    final starred = await provider.getStarredTasks();

    // Load tree preview data and blocked info for all starred tasks in parallel
    final allChildIds = <int>[];
    final db = DatabaseHelper();
    final treeEntries = await Future.wait(starred.map((task) async {
      final children = await provider.getChildren(task.id!);
      var allActive = children
          .where((c) => c.completedAt == null && c.skippedAt == null)
          .toList();
      // Reorder by dependency chains so blocked tasks appear after their blocker
      final siblingDeps = await db.getSiblingDependencyPairs(
          allActive.map((c) => c.id!).toList());
      allActive = reorderByDependencyChains(allActive, siblingDeps);
      final shownChildren = allActive.take(3).toList();
      allChildIds.addAll(allActive.map((c) => c.id!));

      final childEntries = await Future.wait(shownChildren.map((child) async {
        final grandchildren = await provider.getChildren(child.id!);
        final allActiveGc = grandchildren
            .where((g) => g.completedAt == null && g.skippedAt == null)
            .toList();
        return (
          child: child,
          grandchildren: allActiveGc.take(2).toList(),
          totalGrandchildren: allActiveGc.length,
        );
      }));

      return MapEntry(task.id!, (children: childEntries, totalChildren: allActive.length));
    }));
    final treeData = Map.fromEntries(treeEntries);

    // Fetch blocked info for all children across all starred tasks
    final blockedInfo = await DatabaseHelper().getBlockedTaskInfo(allChildIds);

    if (!mounted) return;
    setState(() {
      _starredTasks = starred;
      _treeData = treeData;
      _blockedInfo = blockedInfo;
      _loading = false;
    });
  }

  void _showExpandedView(Task task) {
    final accent = _accentColor(context, task.id ?? 0);
    showDialog(
      context: context,
      builder: (dialogContext) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
              child: _ExpandedStarredView(
                task: task,
                accent: accent,
                onUnstar: () {
                  Navigator.pop(dialogContext);
                  final provider = context.read<TaskProvider>();
                  final originalOrder = task.starOrder;
                  provider.updateTaskStarred(task.id!, false);
                  if (context.mounted) {
                    showInfoSnackBar(
                      context,
                      'Unstarred "${task.name}"',
                      onUndo: () => provider.updateTaskStarred(
                          task.id!, true, starOrder: originalOrder),
                    );
                  }
                },
                onNavigateToTask: (t) {
                  Navigator.pop(dialogContext);
                  widget.onNavigateToTask?.call(t);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // CR-fix M-35: await the async call so DB errors aren't silently swallowed.
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) newIndex--;
    setState(() {
      final task = _starredTasks.removeAt(oldIndex);
      _starredTasks.insert(newIndex, task);
    });
    final taskIds = _starredTasks.map((t) => t.id!).toList();
    await context.read<TaskProvider>().reorderStarredTasks(taskIds);
  }

  AppBar _buildAppBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AppBar(
      titleSpacing: 16,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Task Roulette',
            style: TextStyle(
              fontFamily: 'Outfit',
              fontSize: 30,
              fontWeight: FontWeight.w400,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                'Starred',
                style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 16,
                  fontWeight: FontWeight.w300,
                  color: colorScheme.onSurfaceVariant,
                  letterSpacing: 1.0,
                ),
              ),
              if (_starredTasks.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_starredTasks.length}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      toolbarHeight: 72,
      actions: [
        const ProfileIcon(),
        Consumer<ThemeProvider>(
          builder: (context, themeProvider, _) {
            return IconButton(
              icon: Icon(themeProvider.icon, size: 22),
              onPressed: themeProvider.toggle,
              tooltip: 'Toggle theme',
            );
          },
        ),
        IconButton(
          icon: const Icon(archiveIcon, size: 22),
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
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_starredTasks.isEmpty) {
      return Scaffold(
        appBar: _buildAppBar(context),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.star_border_rounded,
                size: 72,
                color: colorScheme.primary.withAlpha(60),
              ),
              const SizedBox(height: 16),
              Text(
                'No starred tasks yet',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Long-press any task and tap Star\nto bookmark it here',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant.withAlpha(140),
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: _buildAppBar(context),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _starredTasks.length,
        onReorder: _onReorder,
        buildDefaultDragHandles: false,
        proxyDecorator: (child, index, animation) {
          return AnimatedBuilder(
            animation: animation,
            builder: (context, child) => Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              shadowColor: colorScheme.primary.withAlpha(60),
              child: child,
            ),
            child: child,
          );
        },
        itemBuilder: (context, index) {
          final task = _starredTasks[index];
          final treeInfo = _treeData[task.id!];
          return _StarredTaskCard(
            key: ValueKey(task.id),
            index: index,
            task: task,
            tree: treeInfo?.children ?? [],
            totalChildren: treeInfo?.totalChildren ?? 0,
            blockedInfo: _blockedInfo,
            onTap: () {
              if ((treeInfo?.totalChildren ?? 0) == 0) {
                widget.onNavigateToTask?.call(task);
              } else {
                _showExpandedView(task);
              }
            },
            onLongPress: () => widget.onNavigateToTask?.call(task),
          );
        },
      ),
    );
  }
}

/// Accent color for the left border, derived from card color but more vivid.
Color _accentColor(BuildContext context, int taskId) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  const accentsLight = [
    Color(0xFF9C7CDB), // purple
    Color(0xFF5B9BD5), // blue
    Color(0xFF7CB342), // green
    Color(0xFFFF9800), // orange
    Color(0xFFE91E63), // pink
    Color(0xFF00ACC1), // cyan
    Color(0xFFFBC02D), // yellow
    Color(0xFF7E57C2), // lavender
  ];
  const accentsDark = [
    Color(0xFF9575CD), // purple
    Color(0xFF5C8CC7), // blue
    Color(0xFF6B9B37), // green
    Color(0xFFD4873B), // orange
    Color(0xFFC2185B), // pink
    Color(0xFF00897B), // teal
    Color(0xFFC9A825), // yellow
    Color(0xFF6A4FB0), // slate
  ];
  final accents = isDark ? accentsDark : accentsLight;
  return accents[taskId % accents.length];
}

/// Reorders tasks so that blocked tasks appear immediately after their blocker,
/// matching the All Tasks view. [siblingDeps] maps dependentId → blockerId.
@visibleForTesting
List<Task> reorderByDependencyChains(
    List<Task> tasks, Map<int, int> siblingDeps) {
  if (siblingDeps.isEmpty) return tasks;

  // Build blocker → [dependents] map
  final dependents = <int, List<int>>{};
  for (final e in siblingDeps.entries) {
    dependents.putIfAbsent(e.value, () => []).add(e.key);
  }

  final dependentIds = siblingDeps.keys.toSet();
  final taskById = <int, Task>{};
  for (final t in tasks) {
    taskById[t.id!] = t;
  }

  // CR-fix I-46: visited set prevents infinite recursion if data is corrupted.
  final visited = <int>{};
  void walkChain(int id, List<Task> out) {
    if (!visited.add(id)) return; // cycle — break
    final task = taskById[id];
    if (task == null) return;
    out.add(task);
    final deps = dependents[id];
    if (deps != null) {
      for (final depId in deps) {
        walkChain(depId, out);
      }
    }
  }

  final reordered = <Task>[];
  for (final task in tasks) {
    if (dependentIds.contains(task.id)) continue;
    walkChain(task.id!, reordered);
  }
  return reordered;
}

/// Returns a priority- and blocked-aware text style for task children in starred views.
/// Blocked tasks get dimmed; high-priority tasks get a subtle accent tint;
/// normal tasks use baseColor. Used by both tree preview and expanded dialog.
@visibleForTesting
TextStyle childTextStyle({
  required Task task,
  required Color baseColor,
  required Color accent,
  required double fontSize,
  bool isBlocked = false,
}) {
  if (isBlocked) {
    return TextStyle(
      fontSize: fontSize,
      color: baseColor.withAlpha(100),
      height: 1.3,
    );
  }
  return TextStyle(
    fontSize: fontSize,
    color: task.isHighPriority
        ? Color.lerp(baseColor, accent, 0.5)!
        : baseColor,
    // No bold — colour alone distinguishes high priority to keep visual weight light.
    height: 1.3,
  );
}

class _StarredTaskCard extends StatelessWidget {
  final Task task;
  final List<({Task child, List<Task> grandchildren, int totalGrandchildren})> tree;
  final int totalChildren;
  final Map<int, ({int blockerId, String blockerName})> blockedInfo;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final int index;

  const _StarredTaskCard({
    super.key,
    required this.task,
    required this.tree,
    required this.totalChildren,
    required this.blockedInfo,
    required this.onTap,
    required this.onLongPress,
    required this.index,
  });

  String? _subtitle() {
    final parts = <String>[];
    if (totalChildren > 0) {
      parts.add('$totalChildren sub-task${totalChildren == 1 ? '' : 's'}');
    }
    if (task.startedAt != null) {
      parts.add('In progress');
    }
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accent = _accentColor(context, task.id ?? 0);
    final subtitle = _subtitle();
    // White opacity text system — all derived from onSurface
    final onSurface = colorScheme.onSurface;

    return Card(
      key: ValueKey(task.id),
      color: colorScheme.surfaceContainerHigh,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: onSurface.withAlpha(20), // subtle border for separation
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: IntrinsicHeight(
          child: Row(
            children: [
              // Accent bar — the card's identity
              Container(
                width: 5,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    bottomLeft: Radius.circular(12),
                  ),
                ),
              ),
              // Content
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title — highest emphasis
                      Row(
                        children: [
                          Icon(Icons.star_rounded, size: 20, color: accent),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              task.name,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: onSurface.withAlpha(230), // 90%
                                height: 1.2,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      // Subtitle — low emphasis
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Padding(
                          padding: const EdgeInsets.only(left: 28),
                          child: Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: onSurface.withAlpha(153), // 60%
                            ),
                          ),
                        ),
                      ],
                      // Tree
                      if (tree.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.only(left: 28),
                          child: _buildTreePreview(context, onSurface, accent),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // Drag handle
              ReorderableDragStartListener(
                index: index,
                child: Container(
                  width: 40,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    size: 18,
                    color: onSurface.withAlpha(51), // 20%
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTreePreview(BuildContext context, Color onSurface, Color accent) {
    final childColor = onSurface.withAlpha(191); // 75%
    final grandchildColor = onSurface.withAlpha(166); // 65%
    final metaColor = onSurface.withAlpha(128); // 50%
    final lineColor = accent.withAlpha(180);
    final moreChildren = totalChildren - tree.length;

    final rows = <Widget>[];
    for (var i = 0; i < tree.length; i++) {
      final item = tree[i];
      final isLastChild = i == tree.length - 1 && moreChildren == 0;
      final isBlocked = blockedInfo.containsKey(item.child.id);
      rows.add(_TreeRow(
        indent: 0,
        lineColor: lineColor,
        isLast: isLastChild,
        highlight: item.child.isHighPriority,
        child: Text(
          item.child.name,
          style: childTextStyle(
            task: item.child,
            baseColor: childColor,
            accent: accent,
            fontSize: 14,
            isBlocked: isBlocked,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ));
      final moreGc = item.totalGrandchildren - item.grandchildren.length;
      for (var gi = 0; gi < item.grandchildren.length; gi++) {
        final gc = item.grandchildren[gi];
        final isLastGc = gi == item.grandchildren.length - 1 && moreGc == 0;
        rows.add(_TreeRow(
          indent: 1,
          lineColor: lineColor,
          isLast: isLastGc,
          parentIsLast: isLastChild,
          child: Text(
            gc.name,
            style: TextStyle(fontSize: 13, color: grandchildColor, height: 1.3),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ));
      }
      if (moreGc > 0) {
        rows.add(_TreeRow(
          indent: 1,
          lineColor: lineColor,
          isLast: true,
          parentIsLast: isLastChild,
          child: Text(
            '+$moreGc more',
            style: TextStyle(
              fontSize: 12,
              color: metaColor,
              fontStyle: FontStyle.italic,
              height: 1.3,
            ),
          ),
        ));
      }
    }
    if (moreChildren > 0) {
      rows.add(_TreeRow(
        indent: 0,
        lineColor: lineColor,
        isLast: true,
        child: Text(
          '+$moreChildren more',
          style: TextStyle(
            fontSize: 12,
            color: metaColor,
            fontStyle: FontStyle.italic,
            height: 1.3,
          ),
        ),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }
}

/// A single row in the tree preview with painted connector lines.
class _TreeRow extends StatelessWidget {
  final int indent; // 0 = child, 1 = grandchild
  final Color lineColor;
  final bool isLast;
  final bool parentIsLast;
  final bool highlight;
  final Widget child;

  static const double _indentWidth = 14.0;
  static const double _rowHeight = 22.0;

  const _TreeRow({
    required this.indent,
    required this.lineColor,
    required this.isLast,
    this.parentIsLast = false,
    this.highlight = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _rowHeight,
      child: Row(
        children: [
          if (indent > 0)
            CustomPaint(
              size: const Size(_indentWidth, _rowHeight),
              painter: _VerticalLinePainter(
                color: lineColor,
                drawLine: !parentIsLast,
              ),
            ),
          CustomPaint(
            size: const Size(_indentWidth, _rowHeight),
            painter: _ConnectorPainter(
              color: lineColor,
              isLast: isLast,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Paints an L-bend (└) or T-junction (├) connector.
class _ConnectorPainter extends CustomPainter {
  final Color color;
  final bool isLast;

  _ConnectorPainter({required this.color, required this.isLast});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final midX = 4.0;
    final midY = size.height / 2;

    canvas.drawLine(
      Offset(midX, 0),
      Offset(midX, isLast ? midY : size.height),
      paint,
    );
    canvas.drawLine(
      Offset(midX, midY),
      Offset(size.width, midY),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) =>
      color != old.color || isLast != old.isLast;
}

/// Paints a straight vertical pass-through line for parent indent levels.
class _VerticalLinePainter extends CustomPainter {
  final Color color;
  final bool drawLine;

  _VerticalLinePainter({required this.color, required this.drawLine});

  @override
  void paint(Canvas canvas, Size size) {
    if (!drawLine) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(4.0, 0),
      Offset(4.0, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(_VerticalLinePainter old) =>
      color != old.color || drawLine != old.drawLine;
}

/// Expanded view shown on tap of a starred card.
/// Displays the task tree in a centered dialog with lazy-expanding nodes.
class _ExpandedStarredView extends StatefulWidget {
  final Task task;
  final Color accent;
  final VoidCallback onUnstar;
  final void Function(Task task) onNavigateToTask;

  const _ExpandedStarredView({
    required this.task,
    required this.accent,
    required this.onUnstar,
    required this.onNavigateToTask,
  });

  @override
  State<_ExpandedStarredView> createState() => _ExpandedStarredViewState();
}

class _ExpandedStarredViewState extends State<_ExpandedStarredView> {
  /// Flat list of visible nodes (expands/collapses lazily).
  List<_TreeNode> _flatTree = [];
  /// Track which task IDs are expanded.
  final Set<int> _expanded = {};
  /// Cache loaded children per task ID.
  final Map<int, List<_TreeNode>> _childrenCache = {};
  /// IDs of tasks that are blocked by a dependency.
  final Set<int> _blockedIds = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDirectChildren();
  }

  Future<void> _loadDirectChildren() async {
    final provider = context.read<TaskProvider>();
    final nodes = await _fetchChildren(provider, widget.task.id!, 0);
    if (!mounted) return;
    setState(() {
      _childrenCache[widget.task.id!] = nodes;
      _flatTree = nodes;
      _loading = false;
    });
  }

  /// Fetches direct children with their own child counts (to know leaf vs not).
  Future<List<_TreeNode>> _fetchChildren(
      TaskProvider provider, int parentId, int depth) async {
    final children = await provider.getChildren(parentId);
    var active = children
        .where((c) => c.completedAt == null && c.skippedAt == null)
        .toList();

    // Fetch blocked info and reorder by dependency chains
    final db = DatabaseHelper();
    final childIds = active.map((c) => c.id!).toList();
    final results = await Future.wait([
      db.getBlockedTaskInfo(childIds),
      db.getSiblingDependencyPairs(childIds),
    ]);
    final blockedInfo = results[0] as Map<int, ({int blockerId, String blockerName})>;
    final siblingDeps = results[1] as Map<int, int>;
    _blockedIds.addAll(blockedInfo.keys);
    // Reorder so blocked tasks appear after their blocker, matching All Tasks view
    active = reorderByDependencyChains(active, siblingDeps);

    final nodes = <_TreeNode>[];
    for (var i = 0; i < active.length; i++) {
      final child = active[i];
      final isLast = i == active.length - 1;
      // Check if this child has its own children
      final grandchildren = await provider.getChildren(child.id!);
      final activeGcCount = grandchildren
          .where((g) => g.completedAt == null && g.skippedAt == null)
          .length;
      nodes.add(_TreeNode(
        task: child,
        depth: depth,
        isLast: isLast,
        childCount: activeGcCount,
      ));
    }
    return nodes;
  }

  /// Toggle expand/collapse for a node. Loads children on first expand.
  Future<void> _toggleExpand(_TreeNode node) async {
    final taskId = node.task.id!;

    if (_expanded.contains(taskId)) {
      // Collapse: remove this node's descendants from flat list
      _expanded.remove(taskId);
      _rebuildFlatTree();
      return;
    }

    // Expand: load children if not cached
    if (!_childrenCache.containsKey(taskId)) {
      final provider = context.read<TaskProvider>();
      final children =
          await _fetchChildren(provider, taskId, node.depth + 1);
      if (!mounted) return;
      _childrenCache[taskId] = children;
    }

    _expanded.add(taskId);
    _rebuildFlatTree();
  }

  /// Rebuilds the flat tree from root children, inserting expanded subtrees.
  void _rebuildFlatTree() {
    final nodes = <_TreeNode>[];
    _addVisibleNodes(nodes, widget.task.id!, 0);
    setState(() => _flatTree = nodes);
  }

  void _addVisibleNodes(List<_TreeNode> nodes, int parentId, int depth) {
    final children = _childrenCache[parentId];
    if (children == null) return;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      // Recompute isLast based on siblings at this level
      final isLast = i == children.length - 1;
      final node = _TreeNode(
          task: child.task, depth: depth, isLast: isLast,
          childCount: child.childCount);
      nodes.add(node);
      if (_expanded.contains(child.task.id!)) {
        _addVisibleNodes(nodes, child.task.id!, depth + 1);
      }
    }
  }


  Future<void> _confirmUnstar(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from starred?'),
        content: Text('Are you sure you want to unstar "${widget.task.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.onUnstar();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final onSurface = colorScheme.onSurface;
    final lineColor = widget.accent.withAlpha(180);

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 32,
                decoration: BoxDecoration(
                  color: widget.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: Icon(Icons.star_rounded, size: 22, color: widget.accent),
                onPressed: () => _confirmUnstar(context),
                tooltip: 'Remove from starred',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  widget.task.name,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: onSurface.withAlpha(230),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(Icons.open_in_new_rounded, size: 18,
                    color: onSurface.withAlpha(100)),
                onPressed: () => widget.onNavigateToTask(widget.task),
                tooltip: 'Go to task',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Tree content
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _flatTree.isEmpty
                  ? Center(
                      child: Text(
                        'No sub-tasks',
                        style: TextStyle(
                          color: onSurface.withAlpha(128),
                          fontSize: 14,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: _flatTree.length,
                      itemBuilder: (context, index) {
                        final node = _flatTree[index];
                        final taskId = node.task.id!;
                        final ancestorIsLast = <bool>[];
                        _collectAncestorFlags(
                            index, node.depth, ancestorIsLast);
                        final isExpanded = _expanded.contains(taskId);

                        final isBlocked = _blockedIds.contains(taskId);
                        return _ExpandedTreeRow(
                          node: node,
                          lineColor: lineColor,
                          accent: widget.accent,
                          isBlocked: isBlocked,
                          textColor: onSurface.withAlpha(
                              191 - (node.depth * 15).clamp(0, 60)),
                          ancestorIsLast: ancestorIsLast,
                          isExpanded: isExpanded,
                          onNavigate: () =>
                              widget.onNavigateToTask(node.task),
                          onToggleExpand: node.isLeaf
                              ? null
                              : () => _toggleExpand(node),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  /// Walk backwards through the flat tree to find whether each ancestor level
  /// is the last child at that depth (to decide whether to draw vertical lines).
  void _collectAncestorFlags(
      int currentIndex, int currentDepth, List<bool> flags) {
    for (var d = 0; d < currentDepth; d++) {
      // Find the node at depth d that is an ancestor of currentIndex
      bool isLast = true;
      for (var i = currentIndex - 1; i >= 0; i--) {
        if (_flatTree[i].depth == d) {
          isLast = _flatTree[i].isLast;
          break;
        }
        if (_flatTree[i].depth < d) break;
      }
      flags.add(isLast);
    }
  }
}

class _TreeNode {
  final Task task;
  final int depth;
  final bool isLast;
  final int childCount;

  const _TreeNode({
    required this.task,
    required this.depth,
    required this.isLast,
    this.childCount = 0,
  });

  bool get isLeaf => childCount == 0;
}

class _ExpandedTreeRow extends StatelessWidget {
  final _TreeNode node;
  final Color lineColor;
  final Color accent;
  final Color textColor;
  final List<bool> ancestorIsLast;
  final bool isExpanded;
  final bool isBlocked;
  final VoidCallback onNavigate;
  final VoidCallback? onToggleExpand;

  static const double _indentWidth = 16.0;
  static const double _rowHeight = 45.0;

  const _ExpandedTreeRow({
    required this.node,
    required this.lineColor,
    required this.accent,
    required this.textColor,
    required this.ancestorIsLast,
    required this.isExpanded,
    this.isBlocked = false,
    required this.onNavigate,
    this.onToggleExpand,
  });

  @override
  Widget build(BuildContext context) {
    final isLeaf = node.isLeaf;

    return SizedBox(
      height: _rowHeight,
      child: Row(
        children: [
          // Vertical pass-through lines for each ancestor level
          for (var d = 0; d < node.depth; d++)
            CustomPaint(
              size: const Size(_indentWidth, _rowHeight),
              painter: _VerticalLinePainter(
                color: lineColor,
                drawLine: !ancestorIsLast[d],
              ),
            ),
          // Connector for this node
          CustomPaint(
            size: const Size(_indentWidth, _rowHeight),
            painter: _ConnectorPainter(
              color: lineColor,
              isLast: node.isLast,
            ),
          ),
          const SizedBox(width: 4),
          // Tappable row: tap to expand/collapse, long-press to navigate
          Expanded(
            child: InkWell(
              onTap: onToggleExpand ?? onNavigate,
              onLongPress: isLeaf ? null : onNavigate,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(
                  children: [
                    // Chevron for non-leaf nodes; spacer for leaves to align names
                    if (!isLeaf) ...[
                      Icon(
                        isExpanded
                            ? Icons.expand_more_rounded
                            : Icons.chevron_right_rounded,
                        size: 18,
                        color: textColor.withAlpha(150),
                      ),
                      const SizedBox(width: 4),
                    ] else
                      const SizedBox(width: 22), // 18 (icon) + 4 (gap)
                    Expanded(
                      child: Text(
                        node.task.name,
                        style: childTextStyle(
                          task: node.task,
                          baseColor: textColor,
                          accent: accent,
                          fontSize: 17,
                          isBlocked: isBlocked,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Navigate arrow for leaf nodes
                    if (isLeaf)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.open_in_new_rounded,
                          size: 13,
                          color: textColor.withAlpha(100),
                        ),
                      ),
                    // Child count badge for non-leaf nodes
                    if (!isLeaf)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: textColor.withAlpha(20),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${node.childCount}',
                          style: TextStyle(
                            fontSize: 11,
                            color: textColor.withAlpha(140),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
