import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../theme/app_colors.dart';
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

    // Load tree preview data for all starred tasks in parallel
    final treeEntries = await Future.wait(starred.map((task) async {
      final children = await provider.getChildren(task.id!);
      final allActive = children
          .where((c) => c.completedAt == null && c.skippedAt == null)
          .toList();
      final shownChildren = allActive.take(3).toList();

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

    if (!mounted) return;
    setState(() {
      _starredTasks = starred;
      _treeData = treeData;
      _loading = false;
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex--;
    setState(() {
      final task = _starredTasks.removeAt(oldIndex);
      _starredTasks.insert(newIndex, task);
    });
    final taskIds = _starredTasks.map((t) => t.id!).toList();
    context.read<TaskProvider>().reorderStarredTasks(taskIds);
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
          visualDensity: VisualDensity.compact,
        ),
        Consumer<ThemeProvider>(
          builder: (context, themeProvider, _) {
            return IconButton(
              icon: Icon(themeProvider.icon, size: 22),
              onPressed: themeProvider.toggle,
              tooltip: 'Toggle theme',
              visualDensity: VisualDensity.compact,
            );
          },
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
            onTap: () => widget.onNavigateToTask?.call(task),
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

class _StarredTaskCard extends StatelessWidget {
  final Task task;
  final List<({Task child, List<Task> grandchildren, int totalGrandchildren})> tree;
  final int totalChildren;
  final VoidCallback onTap;
  final int index;

  const _StarredTaskCard({
    super.key,
    required this.task,
    required this.tree,
    required this.totalChildren,
    required this.onTap,
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
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final accent = _accentColor(context, task.id ?? 0);
    final subtitle = _subtitle();

    return Card(
      key: ValueKey(task.id),
        color: AppColors.cardColor(context, task.id ?? 0),
        elevation: 1,
        margin: const EdgeInsets.only(bottom: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              children: [
                // Colored left accent bar
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      bottomLeft: Radius.circular(14),
                    ),
                  ),
                ),
                // Card content
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 4, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Title row
                        Row(
                          children: [
                            Icon(Icons.star_rounded, size: 18, color: accent),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                task.name,
                                style: textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        // Subtitle
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.only(left: 26),
                            child: Text(
                              subtitle,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant.withAlpha(160),
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                        // Tree preview
                        if (tree.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Padding(
                            padding: const EdgeInsets.only(left: 26),
                            child: _buildTreePreview(context),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                // Drag handle — only this initiates reorder
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 18,
                      color: colorScheme.onSurfaceVariant.withAlpha(50),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
  }


  Widget _buildTreePreview(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final accent = _accentColor(context, task.id ?? 0);
    final mutedColor = colorScheme.onSurfaceVariant.withAlpha(160);
    final faintColor = colorScheme.onSurfaceVariant.withAlpha(100);
    final lineColor = accent.withAlpha(100);
    final moreChildren = totalChildren - tree.length;

    final rows = <Widget>[];
    for (var i = 0; i < tree.length; i++) {
      final item = tree[i];
      final isLastChild = i == tree.length - 1 && moreChildren == 0;
      // Child row
      rows.add(_TreeRow(
        indent: 0,
        lineColor: lineColor,
        isLast: isLastChild,
        child: Text(
          item.child.name,
          style: textTheme.bodySmall?.copyWith(color: mutedColor),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ));
      // Grandchildren
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
            style: textTheme.bodySmall?.copyWith(
              color: mutedColor,
              fontSize: 11,
            ),
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
            style: textTheme.bodySmall?.copyWith(
              color: faintColor,
              fontSize: 11,
              fontStyle: FontStyle.italic,
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
          style: textTheme.bodySmall?.copyWith(
            color: faintColor,
            fontSize: 11,
            fontStyle: FontStyle.italic,
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
  final Widget child;

  static const double _indentWidth = 16.0;
  static const double _rowHeight = 20.0;

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
          // Paint connector lines for each indent level
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
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final midX = 4.0;
    final midY = size.height / 2;

    // Vertical line: top to middle (or top to bottom if not last)
    canvas.drawLine(
      Offset(midX, 0),
      Offset(midX, isLast ? midY : size.height),
      paint,
    );
    // Horizontal line: middle to right
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
      ..strokeWidth = 1.2
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
