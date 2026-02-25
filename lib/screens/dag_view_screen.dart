import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:graphview/GraphView.dart';
import 'package:provider/provider.dart';
import '../models/task.dart';
import '../models/task_relationship.dart';
import '../providers/task_provider.dart';
import '../theme/app_colors.dart';

/// Cached edge path data extracted from SugiyamaAlgorithm.
class _EdgePath {
  final int sourceId;
  final int destId;
  final List<Offset> points;

  const _EdgePath({
    required this.sourceId,
    required this.destId,
    required this.points,
  });
}

class DagViewScreen extends StatefulWidget {
  const DagViewScreen({super.key});

  @override
  State<DagViewScreen> createState() => _DagViewScreenState();
}

class _DagViewScreenState extends State<DagViewScreen> {
  // Cached layout data from one-time SugiyamaAlgorithm computation.
  Map<int, Offset> _nodePositions = {};
  List<_EdgePath> _edgePaths = [];
  Size _graphSize = Size.zero;

  Map<int, Task> _connectedTaskMap = {};
  List<Task> _unrelatedTasks = [];
  bool _loading = true;
  bool _showUnrelated = false;

  // Raw data cached from DB so we can partition without re-fetching.
  List<Task> _allTasks = [];
  List<TaskRelationship> _allRelationships = [];
  // Task IDs that appear in at least one relationship (as parent or child).
  Set<int> _connectedIds = {};

  final TransformationController _transformController =
      TransformationController();
  // Key for the viewport to measure size for fit-to-screen.
  final GlobalKey _viewportKey = GlobalKey();

  // Track pointer down position for tap detection (Listener-based).
  Offset? _pointerDownPos;

  // Node dimensions — scaled to screen width in _rebuildGraph().
  double _nodeMaxWidth = 100.0;
  double _nodeHPadding = 12.0;
  Size _estimatedNodeSize = const Size(124, 40);
  int _nodeSeparation = 20;
  int _levelSeparation = 65;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  void _zoom(double factor) {
    final currentScale =
        _transformController.value.getMaxScaleOnAxis();
    final newScale = (currentScale * factor).clamp(0.2, 3.0);
    final scaleFactor = newScale / currentScale;

    // Scale around the center of the viewport.
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final center = renderBox.size.center(Offset.zero);

    // Build: translate to center, scale, translate back.
    final toCenter = Matrix4.identity()
      ..setTranslationRaw(center.dx, center.dy, 0);
    final scale = Matrix4.identity()
      ..setEntry(0, 0, scaleFactor)
      ..setEntry(1, 1, scaleFactor);
    final fromCenter = Matrix4.identity()
      ..setTranslationRaw(-center.dx, -center.dy, 0);

    _transformController.value =
        toCenter * scale * fromCenter * _transformController.value;
  }

  void _fitToScreen() {
    final renderBox =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || _graphSize == Size.zero) return;

    final viewportSize = renderBox.size;
    const padding = 40.0;
    final graphW = _graphSize.width + padding;
    final graphH = _graphSize.height + padding;

    final scale = math.min(
      viewportSize.width / graphW,
      viewportSize.height / graphH,
    ).clamp(0.1, 1.0);

    // Center the graph in the viewport.
    final scaledW = graphW * scale;
    final scaledH = graphH * scale;
    final tx = (viewportSize.width - scaledW) / 2;
    final ty = (viewportSize.height - scaledH) / 2;

    _transformController.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
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

    // Auto-fit after the first frame so viewport size is available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _graphSize != Size.zero) {
        _fitToScreen();
      }
    });
  }

  /// Partitions tasks into connected (for graph layout) and unrelated (rendered
  /// separately as a Wrap below the graph).
  void _rebuildGraph() {
    _connectedTaskMap = {};
    _unrelatedTasks = [];
    _nodePositions = {};
    _edgePaths = [];
    _graphSize = Size.zero;

    if (_allTasks.isEmpty) return;

    // Scale node dimensions to screen width (reference: 800px desktop).
    final screenWidth = MediaQuery.sizeOf(context).width;
    final scale = (screenWidth / 800).clamp(0.6, 1.0);
    _nodeMaxWidth = 100.0 * scale;
    _nodeHPadding = 12.0 * scale;
    _estimatedNodeSize = Size(
      _nodeMaxWidth + _nodeHPadding * 2,
      math.max(34.0, 40.0 * scale),
    );
    _nodeSeparation = math.max(12, (20 * scale).round());
    _levelSeparation = math.max(40, (65 * scale).round());

    final graph = Graph();
    final nodeMap = <int, Node>{};

    for (final task in _allTasks) {
      if (_connectedIds.contains(task.id!)) {
        _connectedTaskMap[task.id!] = task;
        final node = Node.Id(task.id!);
        node.size = _estimatedNodeSize;
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

    if (_connectedTaskMap.isNotEmpty) {
      _computeLayout(graph, nodeMap);
    }
  }

  /// Runs SugiyamaAlgorithm once and caches node positions + edge paths.
  void _computeLayout(Graph graph, Map<int, Node> nodeMap) {
    // Portrait screens: LEFT_RIGHT so siblings spread vertically (tall graph).
    // Landscape/desktop: TOP_BOTTOM so siblings spread horizontally (wide graph).
    final screenSize = MediaQuery.sizeOf(context);
    final isPortrait = screenSize.height > screenSize.width;
    final config = SugiyamaConfiguration()
      ..nodeSeparation = _nodeSeparation
      ..levelSeparation = _levelSeparation
      ..orientation = isPortrait
          ? SugiyamaConfiguration.ORIENTATION_LEFT_RIGHT
          : SugiyamaConfiguration.ORIENTATION_TOP_BOTTOM;

    final algorithm = SugiyamaAlgorithm(config);
    _graphSize = algorithm.run(graph, 10, 10);

    // Extract node positions — copyGraph() shares Node instances so
    // positions are set on the originals after run().
    for (final entry in nodeMap.entries) {
      final node = entry.value;
      _nodePositions[entry.key] = Offset(node.x, node.y);
    }

    // Extract edge paths. copyGraph() shares Edge instances, so
    // algorithm.edgeData keys match the original graph's edges.
    for (final edge in graph.edges) {
      final sourceId = edge.source.key!.value as int;
      final destId = edge.destination.key!.value as int;
      final srcNode = nodeMap[sourceId]!;
      final dstNode = nodeMap[destId]!;

      final edgeData = algorithm.edgeData[edge];
      final points = <Offset>[];

      if (edgeData != null && edgeData.bendPoints.isNotEmpty) {
        // bendPoints is alternating [x, y, x, y, ...] including
        // source/dest centers — use as the full path.
        final bp = edgeData.bendPoints;
        for (int i = 0; i < bp.length - 1; i += 2) {
          points.add(Offset(bp[i], bp[i + 1]));
        }
      } else if (isPortrait) {
        // Left-to-right: source right-center → dest left-center.
        points.add(Offset(
          srcNode.x + srcNode.width,
          srcNode.y + srcNode.height / 2,
        ));
        points.add(Offset(
          dstNode.x,
          dstNode.y + dstNode.height / 2,
        ));
      } else {
        // Top-to-bottom: source bottom-center → dest top-center.
        points.add(Offset(
          srcNode.x + srcNode.width / 2,
          srcNode.y + srcNode.height,
        ));
        points.add(Offset(
          dstNode.x + dstNode.width / 2,
          dstNode.y,
        ));
      }

      _edgePaths.add(_EdgePath(
        sourceId: sourceId,
        destId: destId,
        points: points,
      ));
    }
  }

  void _toggleShowUnrelated() {
    setState(() {
      _showUnrelated = !_showUnrelated;
    });
  }

  Color _nodeColor(int taskId) {
    return AppColors.cardColor(context, taskId);
  }

  Future<void> _navigateToTask(Task task) async {
    await context.read<TaskProvider>().navigateToTask(task);
    if (mounted) Navigator.pop(context);
  }

  /// Builds a single node chip. Connected nodes get a colored fill;
  /// unrelated nodes are dimmed (50% opacity, outline only).
  Widget _buildNodeWidget(Task task, {bool connected = true}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Listener(
      onPointerDown: (e) => _pointerDownPos = e.position,
      onPointerUp: (e) {
        if (_pointerDownPos != null &&
            (e.position - _pointerDownPos!).distance < 20) {
          _navigateToTask(task);
        }
        _pointerDownPos = null;
      },
      child: Opacity(
        opacity: connected ? 1.0 : 0.5,
        child: SizedBox(
          width: _estimatedNodeSize.width,
          height: _estimatedNodeSize.height,
          child: Container(
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(horizontal: _nodeHPadding),
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
            child: Text(
              task.name,
              style: _estimatedNodeSize.width < 100
                  ? Theme.of(context).textTheme.bodySmall
                  : Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  /// Builds the graph using Stack + Positioned (nodes) + CustomPaint (edges).
  Widget _buildGraphWidget(bool isDark) {
    const padding = 20.0;
    return SizedBox(
      width: _graphSize.width + padding * 2,
      height: _graphSize.height + padding * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Edges painted behind nodes.
          CustomPaint(
            size: Size(
              _graphSize.width + padding * 2,
              _graphSize.height + padding * 2,
            ),
            painter: _EdgePainter(
              edgePaths: _edgePaths,
              isDark: isDark,
            ),
          ),
          // Nodes positioned from cached layout.
          for (final entry in _nodePositions.entries)
            if (_connectedTaskMap.containsKey(entry.key))
              Positioned(
                left: entry.value.dx,
                top: entry.value.dy,
                child: _buildNodeWidget(_connectedTaskMap[entry.key]!),
              ),
        ],
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !hasAnyTasks
              ? _buildEmptyState()
              : !hasConnected && _showUnrelated
                  ? _buildUnrelatedOnly()
                  : !hasConnected
                      ? _buildEmptyState()
                      : Stack(
                          children: [
                            InteractiveViewer(
                              key: _viewportKey,
                              transformationController: _transformController,
                              constrained: false,
                              panEnabled: true,
                              boundaryMargin: const EdgeInsets.all(double.infinity),
                              minScale: 0.2,
                              maxScale: 3.0,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildGraphWidget(isDark),
                                  if (_showUnrelated &&
                                      _unrelatedTasks.isNotEmpty)
                                    _buildUnrelatedSection(),
                                ],
                              ),
                            ),
                            Positioned(
                              left: 12,
                              bottom: 12,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _ZoomButton(
                                    icon: Icons.add,
                                    tooltip: 'Zoom in',
                                    onPressed: () => _zoom(1.3),
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(8),
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  _ZoomButton(
                                    icon: Icons.fit_screen_outlined,
                                    tooltip: 'Fit to screen',
                                    onPressed: _fitToScreen,
                                    borderRadius: BorderRadius.zero,
                                  ),
                                  const SizedBox(height: 1),
                                  _ZoomButton(
                                    icon: Icons.remove,
                                    tooltip: 'Zoom out',
                                    onPressed: () => _zoom(0.7),
                                    borderRadius: const BorderRadius.vertical(
                                      bottom: Radius.circular(8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
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

/// Paints edges as polylines with arrowheads at the destination end.
class _EdgePainter extends CustomPainter {
  final List<_EdgePath> edgePaths;
  final bool isDark;

  _EdgePainter({required this.edgePaths, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = isDark ? Colors.white54 : Colors.black45
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final arrowPaint = Paint()
      ..color = isDark ? Colors.white54 : Colors.black45
      ..style = PaintingStyle.fill;

    for (final edge in edgePaths) {
      if (edge.points.length < 2) continue;

      // Draw polyline through all points.
      final path = Path();
      path.moveTo(edge.points.first.dx, edge.points.first.dy);
      for (int i = 1; i < edge.points.length; i++) {
        path.lineTo(edge.points[i].dx, edge.points[i].dy);
      }
      canvas.drawPath(path, linePaint);

      // Draw arrowhead at the last point.
      _drawArrowhead(canvas, arrowPaint, edge.points);
    }
  }

  void _drawArrowhead(Canvas canvas, Paint paint, List<Offset> points) {
    final tip = points.last;
    final prev = points[points.length - 2];
    final angle = math.atan2(tip.dy - prev.dy, tip.dx - prev.dx);

    const arrowSize = 8.0;
    const arrowAngle = 0.5; // ~28.6 degrees

    final path = Path();
    path.moveTo(tip.dx, tip.dy);
    path.lineTo(
      tip.dx - arrowSize * math.cos(angle - arrowAngle),
      tip.dy - arrowSize * math.sin(angle - arrowAngle),
    );
    path.lineTo(
      tip.dx - arrowSize * math.cos(angle + arrowAngle),
      tip.dy - arrowSize * math.sin(angle + arrowAngle),
    );
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_EdgePainter oldDelegate) {
    return oldDelegate.isDark != isDark || !listEquals(oldDelegate.edgePaths, edgePaths);
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final BorderRadius borderRadius;

  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: borderRadius,
        child: InkWell(
          onTap: onPressed,
          borderRadius: borderRadius,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}
