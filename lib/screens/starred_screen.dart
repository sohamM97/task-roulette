import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/database_helper.dart';
import '../data/todays_five_pin_helper.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../utils/display_utils.dart';
import '../widgets/add_task_flow.dart';
import '../widgets/done_actions.dart';
import '../widgets/profile_icon.dart';
import '../widgets/tab_app_bar_title.dart';
import '../widgets/task_search.dart';
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
  Map<
    int,
    ({
      List<({Task child, List<Task> grandchildren, int totalGrandchildren})>
      children,
      int totalChildren,
    })
  >
  _treeData = {};

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

  /// The screen-level "+" FAB shared by both the empty-state and populated
  /// Scaffolds. Distinct [heroTag] because the All Tasks tab's FAB uses
  /// 'addTask' and both tab Scaffolds are kept alive at once — a shared tag
  /// would throw a Hero collision.
  Widget _buildAddTaskFab() {
    return FloatingActionButton(
      heroTag: 'addTaskStarred',
      onPressed: _addTask,
      child: const Icon(Icons.add),
    );
  }

  /// Adds a root-level task (Inbox by default) via the shared [AddTaskFlow] —
  /// the same create dialog the All Tasks parent page shows. These are
  /// quick-capture tasks that land at root / Inbox (not subtasks of any starred
  /// task); use a card's expanded-dialog "+" to add subtasks to a starred task.
  Future<void> _addTask() async {
    final provider = context.read<TaskProvider>();
    // Mirror the All Tasks root dialog: offer "Pin for today" whenever a pin
    // slot is free. Manual model: Today's 5 starts empty each day, so do NOT
    // require it to be non-empty — otherwise you could never pin the first task
    // of the day from here. (Bug: the old `taskIds.isNotEmpty` gate hid the Pin
    // toggle on a fresh day, so pinning from Starred was impossible until a task
    // was pinned some other way first.)
    final todaysFive = await DatabaseHelper().getTodaysFiveTaskAndPinIds(
      todayDateKey(),
    );
    if (!mounted) return;
    final showPin = todaysFive.pinnedIds.length < maxPins;
    // For the "already exists" suggestion: tapping a match stars the existing
    // task (so it shows on this page) instead of creating a duplicate.
    final allTasks = await provider.getAllTasks();
    final parentNames = await provider.getParentNamesMap();
    if (!mounted) return;
    await AddTaskFlow(
      // Always root level on the Starred page, so the Inbox toggle is shown
      // (and defaults ON inside AddTaskDialog).
      showInboxOption: true,
      showPinOption: showPin,
      existingTasks: allTasks,
      existingActionIcon: Icons.star,
      existingActionLabel: 'Star instead',
      existingParentNames: parentNames,
      onUseExisting: (existing) async {
        if (existing.isStarred) {
          if (mounted) {
            showInfoSnackBar(context, '"${existing.name}" is already starred');
          }
          return;
        }
        await provider.updateTaskStarred(existing.id!, true);
        if (mounted) {
          showInfoSnackBar(
            context,
            'Starred "${existing.name}"',
            onUndo: () => provider.updateTaskStarred(existing.id!, false),
          );
        }
      },
      // isStarred: true so the new task(s) actually show up on the Starred
      // page (an unstarred root/Inbox task would only appear in All Tasks).
      // atRoot: true because TaskProvider._currentParent is SHARED across tabs
      // — without it, a task added from Starred while the All Tasks tab is
      // drilled into "some task" gets silently nested under that task instead
      // of being a root-level starred task.
      addSingle:
          ({required name, url, required isInbox, required deferNotify}) =>
              provider.addTask(
                name,
                url: url,
                isInbox: isInbox,
                isStarred: true,
                atRoot: true,
                deferNotify: deferNotify,
              ),
      addBatch: (names, {required isInbox}) => provider.addTasksBatch(
        names,
        isInbox: isInbox,
        isStarred: true,
        atRoot: true,
      ),
      onProviderRefresh: provider.refreshAfterMutation,
    ).run(context);
  }

  /// Global search (shared with the All Tasks and Today's 5 tabs). A picked
  /// task opens in the All Tasks tab via [StarredScreen.onNavigateToTask] —
  /// results can be any task, most of which have no place on this page.
  Future<void> _searchTask() => showTaskSearch(
        context,
        onSelected: (selected) async => widget.onNavigateToTask?.call(selected),
        onCreateTask: (name) => showRootAddFromSearch(
          context,
          initialName: name,
          onOpenExisting: (existing) => widget.onNavigateToTask?.call(existing),
        ),
      );

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
    final treeEntries = await Future.wait(
      starred.map((task) async {
        final children = await provider.getChildren(task.id!);
        var allActive = children
            .where((c) => c.completedAt == null && c.skippedAt == null)
            .toList();
        // Reorder by dependency chains so blocked tasks appear after their blocker
        final siblingDeps = await db.getSiblingDependencyPairs(
          allActive.map((c) => c.id!).toList(),
        );
        allActive = reorderByDependencyChains(allActive, siblingDeps);
        final shownChildren = allActive.take(3).toList();
        allChildIds.addAll(allActive.map((c) => c.id!));

        final childEntries = await Future.wait(
          shownChildren.map((child) async {
            final grandchildren = await provider.getChildren(child.id!);
            final allActiveGc = grandchildren
                .where((g) => g.completedAt == null && g.skippedAt == null)
                .toList();
            final shownGc = allActiveGc.take(2).toList();
            // CR-fix I-53: include shown grandchild ids so _blockedInfo covers them.
            // Was: only direct-child ids fetched, so the card couldn't dim blocked
            // grandchildren while the expanded dialog did — a DRY-rule violation.
            allChildIds.addAll(shownGc.map((g) => g.id!));
            return (
              child: child,
              grandchildren: shownGc,
              totalGrandchildren: allActiveGc.length,
            );
          }),
        );

        return MapEntry(task.id!, (
          children: childEntries,
          totalChildren: allActive.length,
        ));
      }),
    );
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
              // In-dialog ScaffoldMessenger so the subtask add/guard snackbars
              // render inside this dialog (foreground) rather than behind it on
              // the page. The transparent Scaffold anchors them; the dialog
              // already fills its 520 height, so this doesn't change its size.
              child: ScaffoldMessenger(
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  resizeToAvoidBottomInset: false,
                  body: _ExpandedStarredView(
                    task: task,
                    accent: accent,
                    onUnstar: () async {
                      Navigator.pop(dialogContext);
                      final provider = context.read<TaskProvider>();
                      final originalOrder = task.starOrder;
                      // CR-fix M-51: await + try-catch. Was fire-and-forget, so a DB
                      // write failure escaped to FlutterError.onError while the
                      // snackbar still claimed "Unstarred" (message could lie).
                      try {
                        await provider.updateTaskStarred(task.id!, false);
                      } catch (_) {
                        return; // don't show a success snackbar if the unstar failed
                      }
                      if (!mounted) return;
                      showInfoSnackBar(
                        context,
                        'Unstarred "${task.name}"',
                        onUndo: () async {
                          // list self-corrects on next provider reload if this throws
                          try {
                            await provider.updateTaskStarred(
                              task.id!,
                              true,
                              starOrder: originalOrder,
                            );
                          } catch (_) {}
                        },
                      );
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
      title: TabAppBarTitle(
        subtitle: 'Starred',
        trailing: _starredTasks.isEmpty
            ? null
            : Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 1,
                ),
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
      ),
      toolbarHeight: 72,
      actions: [
        const ProfileIcon(),
        IconButton(
          icon: const Icon(Icons.search, size: 22),
          onPressed: _searchTask,
          tooltip: 'Search',
        ),
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
              MaterialPageRoute(builder: (_) => const CompletedTasksScreen()),
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
        // Show the add FAB on the empty state too — adding a first starred task
        // is exactly what a user wants here, and long-press-to-star isn't the
        // only path.
        floatingActionButton: _buildAddTaskFab(),
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
      floatingActionButton: _buildAddTaskFab(),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _starredTasks.length,
        // onReorder is deprecated after Flutter 3.41 in favour of onReorderItem,
        // but the dev machine still pins Flutter 3.41 where the replacement
        // doesn't exist yet. Swap when local Flutter is bumped.
        onReorder: _onReorder, // ignore: deprecated_member_use
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
            // Unified tap: empty and non-empty starred cards both open the
            // expanded dialog. (Before: empty cards navigated straight to All
            // Tasks; now they open the dialog too, so a subtask can be added
            // via its "+" FAB without leaving Starred.) Long-press is the
            // escape hatch to All Tasks.
            onTap: () => _showExpandedView(task),
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
  List<Task> tasks,
  Map<int, int> siblingDeps,
) {
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
  final List<({Task child, List<Task> grandchildren, int totalGrandchildren})>
  tree;
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

  Widget _buildTreePreview(
    BuildContext context,
    Color onSurface,
    Color accent,
  ) {
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
      rows.add(
        _TreeRow(
          indent: 0,
          lineColor: lineColor,
          isLast: isLastChild,
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
        ),
      );
      final moreGc = item.totalGrandchildren - item.grandchildren.length;
      for (var gi = 0; gi < item.grandchildren.length; gi++) {
        final gc = item.grandchildren[gi];
        final isLastGc = gi == item.grandchildren.length - 1 && moreGc == 0;
        final gcBlocked = blockedInfo.containsKey(gc.id);
        rows.add(
          _TreeRow(
            indent: 1,
            lineColor: lineColor,
            isLast: isLastGc,
            parentIsLast: isLastChild,
            child: Text(
              gc.name,
              // CR-fix I-53: route grandchildren through the shared childTextStyle
              // (priority tint + blocked dimming) instead of a hardcoded TextStyle,
              // so card and expanded dialog treat every depth identically (DRY rule).
              style: childTextStyle(
                task: gc,
                baseColor: grandchildColor,
                accent: accent,
                fontSize: 13,
                isBlocked: gcBlocked,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
      if (moreGc > 0) {
        rows.add(
          _TreeRow(
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
          ),
        );
      }
    }
    if (moreChildren > 0) {
      rows.add(
        _TreeRow(
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
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }
}

/// A single row in the tree preview with painted connector lines.
class _TreeRow extends StatelessWidget {
  final int indent; // 0 = child, 1 = grandchild
  final Color lineColor;
  final bool isLast;
  final bool parentIsLast;
  // CR-fix M-50: removed dead `highlight` field — it was set for children but
  // never read by build(); the real highlight lives in childTextStyle's colour.
  final Widget child;

  static const double _indentWidth = 14.0;
  static const double _rowHeight = 22.0;

  const _TreeRow({
    required this.indent,
    required this.lineColor,
    required this.isLast,
    this.parentIsLast = false,
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
            painter: _ConnectorPainter(color: lineColor, isLast: isLast),
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
    canvas.drawLine(Offset(midX, midY), Offset(size.width, midY), paint);
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

    canvas.drawLine(Offset(4.0, 0), Offset(4.0, size.height), paint);
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

  /// IDs of tasks that are blocked by a dependency. Rebuilt by
  /// [_refreshBlockedIds] whenever a completion frees a dependent.
  Set<int> _blockedIds = {};

  /// Task IDs currently pinned in Today's 5. Drives the "this task is pinned"
  /// warning before adding a subtask under it (mirrors `task_list_screen.dart`'s
  /// `_warnIfPinned`) and the free-slot check for the "Pin for today" toggle.
  /// Held as a set rather than a flag + count because any row in the tree can
  /// now be added under, not just the starred task at the top.
  Set<int> _todays5PinnedIds = {};

  /// Tasks ticked off during this dialog session, keyed by task id. The rows
  /// stay in the tree, styled, until the dialog is reopened: [DoneChoice.forGood]
  /// renders struck through, [DoneChoice.today] renders dimmed with a check,
  /// matching how All Tasks styles a worked-on card (`task_card.dart:204,321`).
  /// The stored [DoneOutcome] also carries the undo closure, so tapping a
  /// ticked-off row can reverse it long after the undo snackbar has gone.
  final Map<int, DoneOutcome> _doneOutcomes = {};

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDirectChildren();
    _loadTodays5PinState();
  }

  Future<void> _loadTodays5PinState() async {
    final result = await DatabaseHelper().getTodaysFiveTaskAndPinIds(
      todayDateKey(),
    );
    if (!mounted) return;
    setState(() => _todays5PinnedIds = result.pinnedIds.toSet());
  }

  Future<void> _loadDirectChildren() async {
    final provider = context.read<TaskProvider>();
    final nodes = await _fetchChildren(provider, widget.task.id!, 0);
    if (!mounted) return;
    setState(() {
      _childrenCache[widget.task.id!] = nodes;
      _loading = false;
    });
    _rebuildFlatTree();
  }

  /// Fetches direct children with their own child counts (to know leaf vs not).
  Future<List<_TreeNode>> _fetchChildren(
    TaskProvider provider,
    int parentId,
    int depth,
  ) async {
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
    final blockedInfo =
        results[0] as Map<int, ({int blockerId, String blockerName})>;
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
      nodes.add(
        _TreeNode(
          task: child,
          depth: depth,
          isLast: isLast,
          childCount: activeGcCount,
        ),
      );
    }

    // Bug fix (Codex P2): put back the rows ticked off in this session. The
    // query behind getChildren drops completed tasks, and this runs on every
    // reload — including the one an add under an unrelated sibling triggers.
    // Before: a row the user had just completed vanished mid-session while its
    // DoneOutcome stayed in _doneOutcomes, so the undo it promised had no
    // circle left to invoke.
    // After: it holds its own position, struck through, until the dialog is
    // reopened — at which point _doneOutcomes is empty and it drops out.
    final previous = _childrenCache[parentId];
    if (previous != null) {
      for (var i = 0; i < previous.length; i++) {
        final old = previous[i];
        if (!_doneOutcomes.containsKey(old.task.id)) continue;
        if (nodes.any((n) => n.task.id == old.task.id)) continue;
        nodes.insert(
          i.clamp(0, nodes.length),
          _TreeNode(
            task: old.task,
            depth: depth,
            isLast: false, // recomputed by _addVisibleNodes
            childCount: old.childCount,
          ),
        );
      }
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
      final children = await _fetchChildren(provider, taskId, node.depth + 1);
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
        task: child.task,
        depth: depth,
        isLast: isLast,
        childCount: child.childCount,
      );
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

  /// Adds subtask(s) under [parent] via the shared [AddTaskFlow]. [parent] is
  /// any row in the tree, or the starred task itself — so a subtask can be
  /// created at any level without leaving this dialog.
  ///
  /// The new tasks are parented explicitly to [parent] (atRoot ignores the All
  /// Tasks tab's drilled-in parent). Shows a "Pin for today" toggle (no Inbox
  /// toggle — subtasks aren't root-level) so a new subtask can go straight into
  /// Today's 5, mirroring the All Tasks drill-in flow.
  Future<void> _addSubtask(Task parent) async {
    final provider = context.read<TaskProvider>();
    final parentIsPinned = _todays5PinnedIds.contains(parent.id);
    // Hide "Pin for today" when the parent is itself pinned (adding a subtask
    // makes it a non-leaf, so it drops out of Today's 5 — the pinned warning
    // covers that) or when Today's 5 is already full. Mirrors
    // task_list_screen._runAddFlow.
    final showPin = !parentIsPinned && _todays5PinnedIds.length < maxPins;
    // For the "already exists" suggestion: tapping a match links the existing
    // task as a subtask of [parent] (multi-parent DAG) instead of creating a
    // duplicate.
    final allTasks = await provider.getAllTasks();
    final parentNames = await provider.getParentNamesMap();
    if (!mounted) return;
    await AddTaskFlow(
      parentId: parent.id,
      parentName: parent.name,
      parentIsPinned: parentIsPinned,
      showPinOption: showPin,
      existingTasks: allTasks,
      existingActionIcon: Icons.add_link,
      existingActionLabel: 'Add here',
      existingParentNames: parentNames,
      onUseExisting: (existing) async {
        if (existing.id == parent.id) {
          if (mounted) showInfoSnackBar(context, "That's this task");
          return;
        }
        // Codex P2: if the match is ALREADY a subtask of [parent], linking is a
        // no-op that addParentToTask still reports as ok — but the resulting
        // Undo (removeParentFromTask) would delete the pre-existing edge and
        // make the subtask vanish. Guard it: no link, no destructive undo.
        final existingChildIds = await provider.getChildIds(parent.id!);
        if (!mounted) return;
        if (existingChildIds.contains(existing.id)) {
          showInfoSnackBar(context, '"${existing.name}" is already a subtask');
          return;
        }
        final ok = await provider.addParentToTask(existing.id!, parent.id!);
        if (!mounted) return;
        if (ok) {
          await _reloadAfterAdd(parent.id!);
          if (mounted) {
            showInfoSnackBar(
              context,
              'Added "${existing.name}" here',
              onUndo: () async {
                await provider.removeParentFromTask(existing.id!, parent.id!);
                if (mounted) await _reloadAfterAdd(parent.id!);
              },
            );
          }
        } else {
          showInfoSnackBar(context, "Couldn't add — it would create a loop");
        }
      },
      addSingle:
          ({required name, url, required isInbox, required deferNotify}) =>
              provider.addTask(
                name,
                url: url,
                atRoot: true,
                additionalParentIds: [parent.id!],
                deferNotify: deferNotify,
              ),
      addBatch: (names, {required isInbox}) =>
          provider.addTasksBatch(names, parentId: parent.id!),
      onProviderRefresh: provider.refreshAfterMutation,
      // No onTodaysFiveChanged mirror-write here (unlike task_list_screen's
      // flow, which has no post-add reload): _reloadAfterAdd runs on every add
      // and calls _loadTodays5PinState, which re-reads the authoritative pin
      // state from the DB. A direct write would just be overwritten by that
      // re-fetch — and would be stale anyway, since the PinResult reflects only
      // the newly-pinned task, not the parent dropping out of Today's 5 as it
      // becomes a non-leaf.
      onCompleted: (_) => _reloadAfterAdd(parent.id!),
      // The expanded dialog covers the page's snackbar, and its tree refreshes
      // in place — so the "Added N tasks" snackbar would just flash behind it.
      announceBatchAdd: false,
    ).run(context);
  }

  /// Reloads every loaded level after an add, and expands [addedUnderId] so the
  /// new subtask is visible straight away.
  ///
  /// Every level, not just [addedUnderId]: adding a child changes that task's
  /// own child count, and the count is stored in its PARENT's cache entry.
  /// Refresh only the one entry and a task that was a leaf keeps its leaf row —
  /// no chevron, nothing to expand — so the subtask just added is unreachable.
  ///
  /// Bug fix (Codex P2): every entry in [_childrenCache], not only the expanded
  /// ones. A task can sit under two parents in this DAG. If the second parent
  /// was expanded once and then collapsed, its entry survives in the cache and
  /// is re-shown from it without re-querying — so it kept the shared task's old
  /// `childCount` of 0 and drew it as a leaf, with no way to reach the child
  /// just added, until the dialog was closed and reopened.
  Future<void> _reloadAfterAdd(int addedUnderId) async {
    final provider = context.read<TaskProvider>();
    _expanded.add(addedUnderId);
    for (final id in {widget.task.id!, ..._childrenCache.keys, ..._expanded}) {
      // The depth passed here is discarded: _addVisibleNodes recomputes every
      // node's depth from its position in the tree when it rebuilds.
      final nodes = await _fetchChildren(provider, id, 0);
      if (!mounted) return;
      _childrenCache[id] = nodes;
    }
    _rebuildFlatTree();
    // Refresh Today's 5 pin state: adding a subtask can drop the (now non-leaf)
    // parent out of Today's 5 and/or pin a new subtask, both of which change
    // what the pin toggle should do on the next add within this dialog.
    await _loadTodays5PinState();
  }

  /// Handles a tap on a leaf row's done circle.
  ///
  /// Untouched rows open the "Done today" / "Done for good!" chooser — the same
  /// pair of actions Today's 5 offers in its bottom sheet and the All Tasks leaf
  /// detail offers as two buttons. A row already ticked off in this session taps
  /// straight back to undone, so a mis-tap is reversible after the undo snackbar
  /// has gone.
  ///
  /// Only leaf rows get a circle at all: "Done for good!" lives in
  /// [LeafTaskDetail], which All Tasks shows only for leaves, so a task with
  /// children has no completion path anywhere in the app and this tree keeps
  /// that rule.
  Future<void> _onDoneTapped(Task task, DoneChoice? choice) async {
    final done = _doneOutcomes[task.id];
    if (done != null) {
      await done.undo();
      if (!mounted) return;
      await _refreshBlockedIds();
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      showInfoSnackBar(context, 'Restored "${task.name}"');
      return;
    }
    if (choice == null) return; // chooser dismissed
    if (!mounted) return;
    final DoneOutcome? outcome;
    if (choice == DoneChoice.today) {
      outcome = await markTaskDoneToday(
        context,
        task,
        onChanged: _onDoneChanged(task),
      );
    } else {
      outcome = await completeTaskForGood(
        context,
        task,
        onChanged: _onDoneChanged(task),
      );
    }
    if (outcome == null || !mounted) return;
    final marked = outcome;
    setState(() => _doneOutcomes[task.id!] = marked);
    await _refreshBlockedIds();
  }

  /// Rebuilds [_blockedIds] from the database for every level loaded into
  /// [_childrenCache].
  ///
  /// Bug fix: completing a task drops the dependency links it was blocking, so
  /// anything waiting on it becomes actionable — but the set was only ever
  /// added to, never rebuilt.
  /// Before: completing a blocker left its dependent dimmed as though still
  /// blocked, and only closing and reopening the dialog cleared it.
  /// After: the dependent un-dims as soon as the blocker is completed, and
  /// dims again if that completion is undone.
  ///
  /// Every cached level, not just the visible ones: a collapsed level keeps its
  /// cache entry and is re-shown from it without re-querying, so dropping its
  /// ids here would lose the blocked styling when it is expanded again.
  Future<void> _refreshBlockedIds() async {
    final ids = _childrenCache.values
        .expand((nodes) => nodes)
        .map((node) => node.task.id!)
        .toList();
    if (ids.isEmpty) return;
    final blockedInfo = await DatabaseHelper().getBlockedTaskInfo(ids);
    if (!mounted) return;
    setState(() => _blockedIds = blockedInfo.keys.toSet());
  }

  /// Keeps the struck-through / dimmed row in step when the action is reversed
  /// from the undo snackbar rather than by tapping the circle again.
  ///
  /// Bug fix (Codex P2): this path also rebuilds the blocked ids. Undoing a
  /// completion restores the dependency links it removed, so a dependent is
  /// blocked again — but only the row-circle undo refreshed them.
  /// Before: restoring a blocker from the snackbar left its dependent styled as
  /// actionable until the dialog was reopened.
  /// After: it re-dims immediately, matching the circle path.
  Future<void> Function(bool) _onDoneChanged(Task task) => (isDone) async {
    if (isDone || !mounted) return;
    setState(() => _doneOutcomes.remove(task.id));
    await _refreshBlockedIds();
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final onSurface = colorScheme.onSurface;
    final lineColor = widget.accent.withAlpha(180);
    // Dull the accent for the FAB by knocking its saturation down to 45% —
    // keeps the hue/theme tie-in but reads softer than the full accent.
    final accentHsl = HSLColor.fromColor(widget.accent);
    final fabColor = accentHsl
        .withSaturation((accentHsl.saturation * 0.45).clamp(0.0, 1.0))
        .toColor();
    // Pick a legible foreground — the lighter accents (yellow, etc.) need
    // dark text, the rest need light.
    final fabForeground = fabColor.computeLuminance() > 0.5
        ? Colors.black87
        : Colors.white;

    return Stack(
      children: [
        Column(
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
                    icon: Icon(
                      Icons.star_rounded,
                      size: 22,
                      color: widget.accent,
                    ),
                    onPressed: () => _confirmUnstar(context),
                    tooltip: 'Remove from starred',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
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
                    icon: Icon(
                      Icons.open_in_new_rounded,
                      size: 18,
                      color: onSurface.withAlpha(100),
                    ),
                    onPressed: () => widget.onNavigateToTask(widget.task),
                    tooltip: 'Go to task',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
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
                      // Extra bottom padding so the floating "Add subtask"
                      // button never covers the last row when scrolled.
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                      itemCount: _flatTree.length,
                      itemBuilder: (context, index) {
                        final node = _flatTree[index];
                        final taskId = node.task.id!;
                        final ancestorIsLast = <bool>[];
                        _collectAncestorFlags(
                          index,
                          node.depth,
                          ancestorIsLast,
                        );
                        final isExpanded = _expanded.contains(taskId);

                        final isBlocked = _blockedIds.contains(taskId);
                        return _ExpandedTreeRow(
                          node: node,
                          lineColor: lineColor,
                          accent: widget.accent,
                          isBlocked: isBlocked,
                          textColor: onSurface.withAlpha(
                            191 - (node.depth * 15).clamp(0, 60),
                          ),
                          ancestorIsLast: ancestorIsLast,
                          isExpanded: isExpanded,
                          doneChoice: _doneOutcomes[taskId]?.choice,
                          onNavigate: () => widget.onNavigateToTask(node.task),
                          onToggleExpand: node.isLeaf
                              ? null
                              : () => _toggleExpand(node),
                          onDone: (choice) => _onDoneTapped(node.task, choice),
                          onAddSubtask: () => _addSubtask(node.task),
                        );
                      },
                    ),
            ),
          ],
        ),
        // The starred task's own add control: it adds a direct child of the
        // task named in the header, the same thing each row's "+" does for that
        // row.
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            heroTag: null,
            onPressed: () => _addSubtask(widget.task),
            backgroundColor: fabColor,
            foregroundColor: fabForeground,
            tooltip: 'Add subtask',
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  /// Walk backwards through the flat tree to find whether each ancestor level
  /// is the last child at that depth (to decide whether to draw vertical lines).
  void _collectAncestorFlags(
    int currentIndex,
    int currentDepth,
    List<bool> flags,
  ) {
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

  /// How this row was ticked off in the current dialog session, or null if it
  /// hasn't been. Drives the circle's icon and the row's styling.
  final DoneChoice? doneChoice;

  final VoidCallback onNavigate;
  final VoidCallback? onToggleExpand;

  /// Called with the user's pick from the done chooser, or with null when the
  /// row is already ticked off and the tap means "undo".
  final void Function(DoneChoice? choice) onDone;

  final VoidCallback onAddSubtask;

  static const double _indentWidth = 16.0;
  static const double _rowHeight = 45.0;

  /// Width of the column holding either the expand chevron (branch rows) or the
  /// done circle (leaf rows). Fixed so names line up down the whole tree.
  static const double _markerWidth = 22.0;

  /// Width of the trailing "+" (and of the blank left in its place on a row
  /// that has been ticked off).
  static const double _trailingWidth = 30.0;

  const _ExpandedTreeRow({
    required this.node,
    required this.lineColor,
    required this.accent,
    required this.textColor,
    required this.ancestorIsLast,
    required this.isExpanded,
    this.isBlocked = false,
    this.doneChoice,
    required this.onNavigate,
    this.onToggleExpand,
    required this.onDone,
    required this.onAddSubtask,
  });

  /// The leaf row's done control: a chooser when the task is still open, a
  /// straight undo tap once it has been ticked off.
  ///
  /// It sits in the same column a branch row uses for its chevron, so adding it
  /// costs no width and leaves every name aligned.
  Widget _buildDoneControl(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = switch (doneChoice) {
      null => Icon(
        Icons.radio_button_unchecked,
        size: 18,
        color: textColor.withAlpha(120),
      ),
      DoneChoice.today => const Icon(Icons.today, size: 18, color: Colors.orange),
      DoneChoice.forGood => Icon(
        Icons.check_circle,
        size: 18,
        color: colorScheme.primary,
      ),
    };

    if (doneChoice != null) {
      return Tooltip(
        message: 'Undo done',
        child: SizedBox(
          width: _markerWidth,
          height: _rowHeight,
          child: InkWell(
            onTap: () => onDone(null),
            customBorder: const CircleBorder(),
            child: icon,
          ),
        ),
      );
    }

    return PopupMenuButton<DoneChoice>(
      tooltip: 'Mark done',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: onDone,
      // Plain Rows rather than ListTiles: a ListTile brings its own vertical
      // padding and minimum height, which fights a PopupMenuItem's own 48px.
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: DoneChoice.today,
          child: Row(
            children: [
              Icon(Icons.today, color: Colors.orange),
              SizedBox(width: 12),
              Text('Done today'),
            ],
          ),
        ),
        PopupMenuItem(
          value: DoneChoice.forGood,
          child: Row(
            children: [
              Icon(Icons.check_circle, color: colorScheme.primary),
              const SizedBox(width: 12),
              const Text('Done for good!'),
            ],
          ),
        ),
      ],
      child: SizedBox(width: _markerWidth, height: _rowHeight, child: icon),
    );
  }

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
            painter: _ConnectorPainter(color: lineColor, isLast: node.isLast),
          ),
          const SizedBox(width: 4),
          // The marker column: a chevron on branch rows, the done circle on
          // leaf rows. Only leaves get a done control — "Done for good!" lives
          // in LeafTaskDetail, which All Tasks shows only for leaves, so a task
          // with children has no completion path anywhere in the app.
          if (!isLeaf)
            // The chevron carries its own tap target. It sits outside the row's
            // InkWell, so without one it would look tappable and do nothing —
            // tapping it now expands and collapses just as tapping the row name
            // does. It stays a small target, so the row name remains the easier
            // way in; this only removes the dead spot.
            SizedBox(
              width: _markerWidth,
              height: _rowHeight,
              child: InkWell(
                onTap: onToggleExpand,
                customBorder: const CircleBorder(),
                child: Icon(
                  isExpanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 18,
                  color: textColor.withAlpha(150),
                ),
              ),
            )
          else
            _buildDoneControl(context),
          // Tappable row: tap to expand/collapse (branch) or navigate (leaf),
          // long-press to navigate. A leaf has no navigate arrow of its own —
          // the whole row body is the target, which frees the width the trailing
          // "+" needs.
          Expanded(
            child: InkWell(
              onTap: onToggleExpand ?? onNavigate,
              onLongPress: isLeaf ? null : onNavigate,
              borderRadius: BorderRadius.circular(8),
              child: Opacity(
                // Dimmed once ticked off either way, matching how All Tasks
                // renders a worked-on card (task_card.dart:204) — a handled row
                // should recede whether it was done for today or for good. The
                // strikethrough on the name is what still tells the two apart.
                opacity: doneChoice == null ? 1.0 : 0.5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          node.task.name,
                          style: childTextStyle(
                            task: node.task,
                            baseColor: textColor,
                            accent: accent,
                            fontSize: 17,
                            isBlocked: isBlocked,
                          ).copyWith(
                            // Struck through once ticked off either way, so a
                            // handled row reads as handled at a glance and
                            // can't be mistaken for a blocked row, which is
                            // dimmed but never struck through. The circle is
                            // what tells "done today" from "done for good".
                            decoration: doneChoice == null
                                ? null
                                : TextDecoration.lineThrough,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Child count badge for non-leaf nodes
                      if (!isLeaf)
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
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
          ),
          // Every row can gain a child, at any depth — that is what makes the
          // starred tree editable without leaving the dialog. The tooltip names
          // the row so a desktop hover says which task the subtask lands under;
          // the "+" itself is the affordance on mobile, where tooltips don't
          // show.
          //
          // A row ticked off either way withdraws its "+" until it is undone,
          // and the blank keeps the row's width so names stay aligned with the
          // rows around it. The control is withdrawn rather than disabled,
          // since a present-but-dead "+" is the same trap.
          //
          // Bug fix (Codex P1), "Done for good!": a task created under an
          // archived parent is unreachable — getRootTasks excludes anything
          // that appears as a child_id at all, and the completed parent is
          // itself filtered out of the active tree, so the new task showed up
          // nowhere in All Tasks.
          //
          // Bug fix (Codex P2), "Done today": adding a child made the row a
          // branch, and the marker column swapped its undo circle for a
          // chevron, stranding the outcome in _doneOutcomes with nothing able
          // to invoke it. A non-leaf task has no LeafTaskDetail either, so the
          // last_worked_at stamp, the auto-start and any deadline the mark
          // removed could not be reversed from the app.
          if (doneChoice != null)
            const SizedBox(width: _trailingWidth, height: _rowHeight)
          else
            Tooltip(
              message: 'Add subtask under "${node.task.name}"',
              child: SizedBox(
                width: _trailingWidth,
                height: _rowHeight,
                child: InkWell(
                  onTap: onAddSubtask,
                  customBorder: const CircleBorder(),
                  child: Icon(
                    Icons.add,
                    size: 18,
                    color: textColor.withAlpha(130),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
