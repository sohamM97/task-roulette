import 'package:flutter/material.dart';
import 'package:graphview/GraphView.dart';
import 'package:provider/provider.dart';
import '../models/task.dart';
import '../models/task_relationship.dart';
import '../providers/task_provider.dart';

class DagViewScreen extends StatefulWidget {
  const DagViewScreen({super.key});

  @override
  State<DagViewScreen> createState() => _DagViewScreenState();
}

class _DagViewScreenState extends State<DagViewScreen> {
  // Graph containing only connected tasks (those with at least one relationship).
  // Unrelated tasks are rendered separately because graphview's
  // getVisibleGraphOnly() builds the visible graph from edges only —
  // isolated nodes with zero edges are silently dropped.
  Graph? _graph;
  Map<int, Task> _connectedTaskMap = {};
  List<Task> _unrelatedTasks = [];
  bool _loading = true;
  bool _showUnrelated = false;

  // Raw data cached from DB so we can partition without re-fetching.
  List<Task> _allTasks = [];
  List<TaskRelationship> _allRelationships = [];
  // Task IDs that appear in at least one relationship (as parent or child).
  Set<int> _connectedIds = {};

  static const _nodeColors = [
    Color(0xFFE8DEF8), // purple
    Color(0xFFD0E8FF), // blue
    Color(0xFFDCEDC8), // green
    Color(0xFFFFE0B2), // orange
    Color(0xFFF8BBD0), // pink
    Color(0xFFB2EBF2), // cyan
    Color(0xFFFFF9C4), // yellow
    Color(0xFFD1C4E9), // lavender
  ];

  static const _nodeColorsDark = [
    Color(0xFF352E4D), // purple
    Color(0xFF2E354D), // blue
    Color(0xFF2E3E35), // sage
    Color(0xFF3E3530), // warm grey
    Color(0xFF3E2E38), // mauve
    Color(0xFF2E3E3E), // teal
    Color(0xFF38362E), // taupe
    Color(0xFF302E45), // slate
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final provider = context.read<TaskProvider>();
    _allTasks = await provider.getAllTasks();
    _allRelationships = await provider.getAllRelationships();

    if (!mounted) return;

    _connectedIds = {};
    for (final rel in _allRelationships) {
      _connectedIds.add(rel.parentId);
      _connectedIds.add(rel.childId);
    }

    _rebuildGraph();
    setState(() => _loading = false);
  }

  /// Partitions tasks into connected (for GraphView) and unrelated (rendered
  /// separately as a Wrap below the graph).
  void _rebuildGraph() {
    _connectedTaskMap = {};
    _unrelatedTasks = [];

    if (_allTasks.isEmpty) {
      _graph = null;
      return;
    }

    final graph = Graph();
    final nodeMap = <int, Node>{};

    // Split: tasks with relationships go into the graph, the rest are
    // shown in a separate "unrelated" section when toggled on.
    for (final task in _allTasks) {
      if (_connectedIds.contains(task.id!)) {
        _connectedTaskMap[task.id!] = task;
        final node = Node.Id(task.id!);
        nodeMap[task.id!] = node;
        graph.addNode(node);
      } else {
        _unrelatedTasks.add(task);
      }
    }

    for (final rel in _allRelationships) {
      final source = nodeMap[rel.parentId];
      final dest = nodeMap[rel.childId];
      if (source != null && dest != null) {
        graph.addEdge(source, dest);
      }
    }

    _graph = graph;
  }

  void _toggleShowUnrelated() {
    setState(() {
      _showUnrelated = !_showUnrelated;
    });
  }

  Color _nodeColor(int taskId) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark ? _nodeColorsDark : _nodeColors;
    return colors[taskId % colors.length];
  }

  void _navigateToTask(Task task) {
    context.read<TaskProvider>().navigateToTask(task);
    Navigator.pop(context);
  }

  /// Builds a single node chip. Connected nodes get a colored fill;
  /// unrelated nodes are dimmed (50% opacity, outline only).
  Widget _buildNodeWidget(Task task, {bool connected = true}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => _navigateToTask(task),
      child: Opacity(
        opacity: connected ? 1.0 : 0.5,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: connected ? _nodeColor(task.id!) : null,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: connected
                  ? (isDark ? Colors.white24 : Colors.black12)
                  : (isDark ? Colors.white38 : Colors.black26),
              width: connected ? 1.0 : 1.5,
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              task.name,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasConnected = _connectedTaskMap.isNotEmpty;
    final hasUnrelated = _unrelatedTasks.isNotEmpty;
    final hasAnyTasks = hasConnected || hasUnrelated;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Task Graph'),
        actions: [
          if (!_loading && hasUnrelated)
            IconButton(
              icon: Icon(
                _showUnrelated
                    ? Icons.visibility
                    : Icons.visibility_off_outlined,
              ),
              onPressed: _toggleShowUnrelated,
              tooltip: _showUnrelated
                  ? 'Hide unrelated tasks'
                  : 'Show unrelated tasks',
            ),
        ],
      ),
      // Body priority: loading → no tasks at all → only unrelated (no graph
      // to show) → graph + optional unrelated section below it.
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !hasAnyTasks
              ? _buildEmptyState()
              : !hasConnected && _showUnrelated
                  ? _buildUnrelatedOnly()
                  : !hasConnected
                      ? _buildEmptyState()
                      : InteractiveViewer(
                          constrained: false,
                          boundaryMargin: const EdgeInsets.all(200),
                          minScale: 0.2,
                          maxScale: 3.0,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              GraphView(
                                graph: _graph!,
                                algorithm: SugiyamaAlgorithm(
                                  SugiyamaConfiguration()
                                    ..nodeSeparation = 40
                                    ..levelSeparation = 60
                                    ..orientation = SugiyamaConfiguration
                                        .ORIENTATION_TOP_BOTTOM,
                                ),
                                paint: Paint()
                                  ..color =
                                      isDark ? Colors.white54 : Colors.black45
                                  ..strokeWidth = 2.0
                                  ..style = PaintingStyle.stroke,
                                builder: (Node node) {
                                  final taskId = node.key!.value as int;
                                  final task = _connectedTaskMap[taskId];
                                  if (task == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return _buildNodeWidget(task);
                                },
                              ),
                              if (_showUnrelated && _unrelatedTasks.isNotEmpty)
                                _buildUnrelatedSection(),
                            ],
                          ),
                        ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.onSurface.withAlpha(100),
          ),
          const SizedBox(height: 16),
          Text(
            'No tasks to visualize',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(150),
                ),
          ),
          if (_unrelatedTasks.isNotEmpty && !_showUnrelated) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _toggleShowUnrelated,
              icon: const Icon(Icons.visibility_outlined, size: 18),
              label: Text(
                '${_unrelatedTasks.length} unlinked task${_unrelatedTasks.length == 1 ? '' : 's'}',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUnrelatedOnly() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: _buildUnrelatedSection(),
    );
  }

  Widget _buildUnrelatedSection() {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 24, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Not linked to anything',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withAlpha(130),
                ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _unrelatedTasks
                .map((task) => _buildNodeWidget(task, connected: false))
                .toList(),
          ),
        ],
      ),
    );
  }
}
