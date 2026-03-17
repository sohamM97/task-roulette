import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/task.dart';
import '../providers/task_provider.dart';
import '../theme/app_colors.dart';

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

  @override
  void initState() {
    super.initState();
    _provider = context.read<TaskProvider>();
    _provider!.addListener(_onProviderChanged);
    _loadStarredTasks();
  }

  @override
  void dispose() {
    _provider?.removeListener(_onProviderChanged);
    super.dispose();
  }

  void _onProviderChanged() {
    if (!mounted || _loading) return;
    _loadStarredTasks();
  }

  Future<void> _loadStarredTasks() async {
    final provider = context.read<TaskProvider>();
    final starred = await provider.getStarredTasks();

    // Load tree preview data for each starred task
    final treeData = <int, ({List<({Task child, List<Task> grandchildren, int totalGrandchildren})> children, int totalChildren})>{};
    for (final task in starred) {
      final children = await provider.getChildren(task.id!);
      final allActive = children
          .where((c) => c.completedAt == null && c.skippedAt == null)
          .toList();
      final shownChildren = allActive.take(3).toList();

      final childEntries = <({Task child, List<Task> grandchildren, int totalGrandchildren})>[];
      for (final child in shownChildren) {
        final grandchildren = await provider.getChildren(child.id!);
        final allActiveGc = grandchildren
            .where((g) => g.completedAt == null && g.skippedAt == null)
            .toList();
        childEntries.add((
          child: child,
          grandchildren: allActiveGc.take(2).toList(),
          totalGrandchildren: allActiveGc.length,
        ));
      }

      treeData[task.id!] = (children: childEntries, totalChildren: allActive.length);
    }

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

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_starredTasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.star_outline,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(100),
            ),
            const SizedBox(height: 16),
            Text(
              'Star tasks for quick access',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(160),
              ),
            ),
          ],
        ),
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _starredTasks.length,
      onReorder: _onReorder,
      buildDefaultDragHandles: false,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) => Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(16),
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
    );
  }
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

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return ReorderableDragStartListener(
      index: index,
      child: Card(
        color: AppColors.cardColor(context, task.id ?? 0),
        margin: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.star,
                            size: 18,
                            color: Color(0xFFFFD700),
                          ),
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
                      if (tree.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ...tree.asMap().entries.map((entry) {
                          final i = entry.key;
                          final item = entry.value;
                          final moreChildren = totalChildren - tree.length;
                          final isLast = i == tree.length - 1 && moreChildren == 0;
                          return _buildTreeNode(
                            context,
                            child: item.child,
                            grandchildren: item.grandchildren,
                            totalGrandchildren: item.totalGrandchildren,
                            isLast: isLast,
                          );
                        }),
                        if (totalChildren > tree.length)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Text(
                              '└─ +${totalChildren - tree.length} more',
                              style: textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(100),
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.drag_indicator,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(60),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTreeNode(
    BuildContext context, {
    required Task child,
    required List<Task> grandchildren,
    required int totalGrandchildren,
    required bool isLast,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final mutedColor = Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(140);
    final faintColor = Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(100);
    final prefix = isLast ? '└─' : '├─';
    final vertBar = isLast ? '   ' : '│  ';
    final moreGc = totalGrandchildren - grandchildren.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '$prefix ${child.name}',
            style: textTheme.bodySmall?.copyWith(color: mutedColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ...grandchildren.asMap().entries.map((gcEntry) {
          final gi = gcEntry.key;
          final gc = gcEntry.value;
          final gcIsLast = gi == grandchildren.length - 1 && moreGc == 0;
          final gcPrefix = gcIsLast ? '└─' : '├─';
          return Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '$vertBar$gcPrefix ${gc.name}',
              style: textTheme.bodySmall?.copyWith(
                color: mutedColor,
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        }),
        if (moreGc > 0)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '$vertBar└─ +$moreGc more',
              style: textTheme.bodySmall?.copyWith(
                color: faintColor,
                fontSize: 11,
              ),
            ),
          ),
      ],
    );
  }
}
