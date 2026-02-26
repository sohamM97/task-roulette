import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/task.dart';
import '../models/task_relationship.dart';
import '../providers/task_provider.dart';
import '../theme/app_colors.dart';
import '../utils/force_directed_layout.dart';

class DagViewScreen extends StatefulWidget {
  const DagViewScreen({super.key});

  @override
  State<DagViewScreen> createState() => _DagViewScreenState();
}

class _DagViewScreenState extends State<DagViewScreen> {
  // Cached layout data from force-directed computation.
  Map<int, LayoutNode> _layoutNodes = {};
  List<LayoutEdge> _layoutEdges = [];
  Size _graphSize = Size.zero;

  // Root task IDs (connected tasks that are never children).
  Set<int> _rootIds = {};
  // Leaf task IDs (connected tasks that are never parents).
  Set<int> _leafIds = {};
  // Node colors by task ID, pre-computed for edge painter.
  Map<int, Color> _nodeColors = {};

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
  double _rootNodeWidth = 160.0;
  double _rootNodeHeight = 56.0;
  double _regularNodeWidth = 120.0;
  double _regularNodeHeight = 42.0;
  double _nodeHPadding = 12.0;

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
    // The graph widget adds 40px padding on each side (80 total).
    const graphPadding = 80.0;
    const margin = 20.0;
    final graphW = _graphSize.width + graphPadding + margin;
    final graphH = _graphSize.height + graphPadding + margin;

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

  /// Partitions tasks into connected (for graph layout) and unrelated.
  void _rebuildGraph() {
    _connectedTaskMap = {};
    _unrelatedTasks = [];
    _layoutNodes = {};
    _layoutEdges = [];
    _graphSize = Size.zero;
    _rootIds = {};
    _leafIds = {};
    _nodeColors = {};

    if (_allTasks.isEmpty) return;

    // Scale node dimensions to screen width (reference: 800px desktop).
    final screenWidth = MediaQuery.sizeOf(context).width;
    final scale = (screenWidth / 800).clamp(0.7, 1.0);
    _rootNodeWidth = 160.0 * scale;
    _rootNodeHeight = 56.0 * scale;
    _regularNodeWidth = 120.0 * scale;
    _regularNodeHeight = 42.0 * scale;
    _nodeHPadding = 12.0 * scale;

    // Identify child/parent IDs to determine roots and leaves.
    final childIds = <int>{};
    final parentIds = <int>{};
    for (final rel in _allRelationships) {
      childIds.add(rel.childId);
      parentIds.add(rel.parentId);
    }

    // Build parent→children adjacency for BFS depth computation.
    final childrenOf = <int, List<int>>{};
    for (final rel in _allRelationships) {
      childrenOf.putIfAbsent(rel.parentId, () => []).add(rel.childId);
    }

    // Partition into connected vs unrelated, identify roots and leaves.
    final connectedTaskIds = <int>[];
    for (final task in _allTasks) {
      if (_connectedIds.contains(task.id!)) {
        _connectedTaskMap[task.id!] = task;
        final isRoot = !childIds.contains(task.id!);
        final isLeaf = !parentIds.contains(task.id!);
        if (isRoot) _rootIds.add(task.id!);
        if (isLeaf) _leafIds.add(task.id!);
        _nodeColors[task.id!] = AppColors.cardColor(context, task.id!);
        connectedTaskIds.add(task.id!);
      } else {
        _unrelatedTasks.add(task);
      }
    }

    // BFS from roots to compute depth and cluster (root ancestor) of each node.
    final depths = <int, int>{};
    final clusters = <int, int>{}; // node ID → root ID it belongs to
    final queue = <int>[];
    for (final rootId in _rootIds) {
      depths[rootId] = 0;
      clusters[rootId] = rootId;
      queue.add(rootId);
    }
    var head = 0;
    while (head < queue.length) {
      final current = queue[head++];
      final currentDepth = depths[current]!;
      final currentCluster = clusters[current]!;
      for (final childId in childrenOf[current] ?? <int>[]) {
        if (!depths.containsKey(childId)) {
          depths[childId] = currentDepth + 1;
          clusters[childId] = currentCluster;
          queue.add(childId);
        }
      }
    }
    // Nodes not reachable from roots (e.g. cycles) get max depth.
    final maxDepth = depths.values.fold(0, math.max);
    for (final id in connectedTaskIds) {
      depths.putIfAbsent(id, () => maxDepth);
    }

    // Create layout nodes with depth-scaled sizes.
    for (final id in connectedTaskIds) {
      final isRoot = _rootIds.contains(id);
      final depth = depths[id] ?? 0;
      final depthScale = _depthScale(depth);

      final nodeWidth = isRoot
          ? _rootNodeWidth
          : _regularNodeWidth * depthScale;
      final nodeHeight = isRoot
          ? _rootNodeHeight
          : _regularNodeHeight * depthScale;

      _layoutNodes[id] = LayoutNode(
        id: id,
        isRoot: isRoot,
        depth: depth,
        cluster: clusters[id] ?? -1,
        x: 0,
        y: 0,
        width: nodeWidth + _nodeHPadding * 2,
        height: nodeHeight,
      );
    }

    for (final rel in _allRelationships) {
      if (_layoutNodes.containsKey(rel.parentId) &&
          _layoutNodes.containsKey(rel.childId)) {
        _layoutEdges.add(LayoutEdge(
          sourceId: rel.parentId,
          destId: rel.childId,
        ));
      }
    }

    if (_connectedTaskMap.isNotEmpty) {
      final screenSize = MediaQuery.sizeOf(context);
      final result = ForceDirectedLayout.run(
        nodes: _layoutNodes,
        edges: _layoutEdges,
        aspectRatio: (screenSize.width / screenSize.height).clamp(0.8, 2.0),
      );
      _graphSize = Size(result.width, result.height);
    }
  }

  /// Returns a scale factor (1.0 → 0.7) for non-root nodes based on depth.
  /// Depth 1 = 1.0, depth 2 = 0.93, depth 3 = 0.86, ... clamped at 0.7.
  double _depthScale(int depth) {
    if (depth <= 1) return 1.0;
    return (1.0 - (depth - 1) * 0.07).clamp(0.7, 1.0);
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

  /// Builds a single node widget. Root nodes are larger with glow effects.
  /// Deeper nodes are progressively smaller and dimmer.
  Widget _buildNodeWidget(Task task, {bool connected = true}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isRoot = _rootIds.contains(task.id!);
    final isLeaf = _leafIds.contains(task.id!) && connected;
    final depth = _layoutNodes[task.id!]?.depth ?? 0;
    final depthScale = connected ? _depthScale(depth) : 1.0;
    final nodeWidth = connected
        ? (isRoot ? _rootNodeWidth : _regularNodeWidth * depthScale)
        : _regularNodeWidth;
    final nodeHeight = connected
        ? (isRoot ? _rootNodeHeight : _regularNodeHeight * depthScale)
        : _regularNodeHeight;

    // Leaf nodes: smaller radius (square-ish), root: large radius, else: pill.
    final borderRadius = isRoot && connected
        ? 16.0
        : isLeaf
            ? 6.0
            : 12.0;

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
        // Root=1.0, depth 1=0.95, depth 2=0.88, ... min 0.55. Unrelated=0.5.
        opacity: connected
            ? (isRoot ? 1.0 : (1.0 - depth * 0.07).clamp(0.55, 0.95))
            : 0.5,
        child: SizedBox(
          width: nodeWidth + _nodeHPadding * 2,
          height: nodeHeight,
          child: Container(
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(horizontal: _nodeHPadding),
            decoration: BoxDecoration(
              color: connected ? _nodeColor(task.id!) : null,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: isRoot && connected
                    ? (isDark
                        ? Colors.white.withAlpha(100)
                        : Colors.black.withAlpha(60))
                    : connected
                        ? (isDark ? Colors.white24 : Colors.black12)
                        : (isDark ? Colors.white38 : Colors.black26),
                width: isRoot && connected ? 2.5 : 1.0,
              ),
              boxShadow: isRoot && connected
                  ? [
                      BoxShadow(
                        color: _nodeColor(task.id!).withAlpha(140),
                        blurRadius: 20,
                        spreadRadius: 4,
                      ),
                      BoxShadow(
                        color: (isDark ? Colors.white : Colors.black)
                            .withAlpha(30),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Text(
              task.name,
              style: isRoot && connected
                  ? Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      )
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
    const padding = 40.0;
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
            painter: _BezierEdgePainter(
              layoutNodes: _layoutNodes,
              layoutEdges: _layoutEdges,
              nodeColors: _nodeColors,
              isDark: isDark,
              offset: const Offset(padding, padding),
            ),
          ),
          // Nodes positioned from cached layout.
          for (final entry in _layoutNodes.entries)
            if (_connectedTaskMap.containsKey(entry.key))
              Positioned(
                left: entry.value.x + padding,
                top: entry.value.y + padding,
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
                              boundaryMargin:
                                  const EdgeInsets.all(double.infinity),
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
                                    borderRadius:
                                        const BorderRadius.vertical(
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
                                    borderRadius:
                                        const BorderRadius.vertical(
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
      padding:
          const EdgeInsets.only(left: 16, right: 16, top: 24, bottom: 16),
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

/// Paints edges as color-tinted quadratic bezier curves with arrowheads.
/// Edge color is tinted by the source node color. Stroke width tapers
/// by source depth (thicker from roots, thinner from deeper nodes).
class _BezierEdgePainter extends CustomPainter {
  final Map<int, LayoutNode> layoutNodes;
  final List<LayoutEdge> layoutEdges;
  final Map<int, Color> nodeColors;
  final bool isDark;
  final Offset offset;

  _BezierEdgePainter({
    required this.layoutNodes,
    required this.layoutEdges,
    required this.nodeColors,
    required this.isDark,
    required this.offset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final baseFallback = isDark ? Colors.white : Colors.black;

    for (final edge in layoutEdges) {
      final src = layoutNodes[edge.sourceId];
      final dst = layoutNodes[edge.destId];
      if (src == null || dst == null) continue;

      // Color-tinted by source node. In dark mode the card colors are
      // very muted, so lighten them significantly before using as edge color.
      final srcColor = nodeColors[edge.sourceId];
      Color edgeColor;
      if (srcColor != null) {
        // Lighten the node color to make it visible as an edge tint.
        final hsl = HSLColor.fromColor(srcColor);
        final lightened = hsl
            .withLightness((hsl.lightness + (isDark ? 0.35 : 0.1)).clamp(0.0, 0.85))
            .withSaturation((hsl.saturation + (isDark ? 0.3 : 0.0)).clamp(0.0, 1.0))
            .toColor();
        edgeColor = lightened;
      } else {
        edgeColor = baseFallback;
      }

      // Stroke tapers by source depth: root edges=2.2, depth 1=1.8, etc.
      final strokeWidth =
          (2.2 - src.depth * 0.3).clamp(0.8, 2.2);

      final srcCenter = Offset(
        src.x + src.width / 2 + offset.dx,
        src.y + src.height / 2 + offset.dy,
      );
      final dstCenter = Offset(
        dst.x + dst.width / 2 + offset.dx,
        dst.y + dst.height / 2 + offset.dy,
      );

      final dx = dstCenter.dx - srcCenter.dx;
      final dy = dstCenter.dy - srcCenter.dy;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < 1.0) continue;

      // Compute source edge point (where line exits source node).
      final srcEdge = _nodeEdgePoint(srcCenter, src, dx, dy, dist);

      // Compute bezier control point — perpendicular offset at midpoint.
      final mid = Offset(
        (srcEdge.dx + dstCenter.dx) / 2,
        (srcEdge.dy + dstCenter.dy) / 2,
      );
      final edgeHash = edge.sourceId * 31 + edge.destId;
      final offsetFraction = 0.10 + (edgeHash % 16) / 100.0;
      final direction = edgeHash.isEven ? 1.0 : -1.0;
      final perpX = (-dy / dist) * dist * offsetFraction * direction;
      final perpY = (dx / dist) * dist * offsetFraction * direction;

      final controlPoint = Offset(mid.dx + perpX, mid.dy + perpY);

      // Compute destination edge point (where arrow meets dest node).
      final tangentDx = dstCenter.dx - controlPoint.dx;
      final tangentDy = dstCenter.dy - controlPoint.dy;
      final tangentLen =
          math.sqrt(tangentDx * tangentDx + tangentDy * tangentDy);
      final angle = math.atan2(tangentDy, tangentDx);

      final dstEdge =
          _nodeEdgePoint(dstCenter, dst, -tangentDx, -tangentDy, tangentLen);

      // Gradient: bright at source, fading toward destination.
      final srcAlpha = isDark ? 200 : 160;
      final dstAlpha = isDark ? 50 : 40;
      final linePaint = Paint()
        ..shader = ui.Gradient.linear(
          srcEdge,
          dstEdge,
          [
            edgeColor.withAlpha(srcAlpha),
            edgeColor.withAlpha(dstAlpha),
          ],
        )
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke;

      final arrowPaint = Paint()
        ..color = edgeColor.withAlpha(isDark ? 220 : 180)
        ..style = PaintingStyle.fill;

      // Draw quadratic bezier from source edge to destination edge.
      final path = Path();
      path.moveTo(srcEdge.dx, srcEdge.dy);
      path.quadraticBezierTo(
        controlPoint.dx,
        controlPoint.dy,
        dstEdge.dx,
        dstEdge.dy,
      );
      canvas.drawPath(path, linePaint);

      // Arrowhead at destination end, sized proportionally to stroke.
      _drawArrowhead(canvas, arrowPaint, dstEdge, angle,
          arrowSize: 7.0 + strokeWidth * 1.5);
    }
  }

  void _drawArrowhead(
    Canvas canvas, Paint paint, Offset tip, double angle, {
    double arrowSize = 10.0,
  }) {
    const arrowAngle = 0.45; // ~25.8 degrees

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

  /// Finds the point on a node's rectangular border along a direction
  /// from its center.
  Offset _nodeEdgePoint(
    Offset center, LayoutNode node, double dx, double dy, double dist,
  ) {
    if (dist < 1.0) return center;
    final ndx = dx / dist;
    final ndy = dy / dist;
    final hw = node.width / 2;
    final hh = node.height / 2;
    final tx = ndx != 0 ? (hw / ndx.abs()) : double.infinity;
    final ty = ndy != 0 ? (hh / ndy.abs()) : double.infinity;
    final t = math.min(tx, ty);
    return Offset(center.dx + ndx * t, center.dy + ndy * t);
  }

  @override
  bool shouldRepaint(_BezierEdgePainter oldDelegate) {
    return oldDelegate.isDark != isDark ||
        !identical(oldDelegate.layoutNodes, layoutNodes) ||
        !listEquals(oldDelegate.layoutEdges, layoutEdges);
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
