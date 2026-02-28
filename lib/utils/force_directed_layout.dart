import 'dart:math' as math;

/// A node in the force-directed layout with position and velocity.
class LayoutNode {
  final int id;
  final bool isRoot;
  /// Depth from nearest root (0 = root). Set externally before layout.
  int depth;
  /// Cluster ID (typically the root task ID this node belongs to).
  /// Set externally before layout. Nodes in different clusters repel more.
  int cluster;
  /// All clusters this node has affinity with (via parents in different
  /// clusters). Set externally. Multi-parent nodes won't get extra
  /// inter-cluster repulsion against any of these clusters.
  Set<int> allClusters;
  double x;
  double y;
  double vx = 0;
  double vy = 0;
  final double width;
  final double height;

  LayoutNode({
    required this.id,
    required this.isRoot,
    this.depth = 0,
    this.cluster = -1,
    Set<int>? allClusters,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  }) : allClusters = allClusters ?? (cluster != -1 ? {cluster} : {});
}

/// An edge between two nodes.
class LayoutEdge {
  final int sourceId;
  final int destId;

  const LayoutEdge({required this.sourceId, required this.destId});
}

/// Result of the force-directed layout computation.
class LayoutResult {
  final Map<int, LayoutNode> nodes;
  final double width;
  final double height;

  const LayoutResult({
    required this.nodes,
    required this.width,
    required this.height,
  });
}

/// Self-contained force-directed graph layout algorithm.
///
/// Uses simulated annealing with repulsion (all pairs), spring attraction
/// (connected pairs), and center gravity. O(n²) per iteration — fine for
/// personal task managers with <500 nodes.
class ForceDirectedLayout {
  /// Runs the layout algorithm and returns positioned nodes.
  ///
  /// [nodes] — map of task ID to LayoutNode (positions will be mutated).
  /// [edges] — list of edges between nodes.
  /// [iterations] — number of simulation steps (default 300).
  static LayoutResult run({
    required Map<int, LayoutNode> nodes,
    required List<LayoutEdge> edges,
    int iterations = 300,
    double aspectRatio = 1.4, // target width/height ratio
  }) {
    if (nodes.isEmpty) {
      return const LayoutResult(nodes: {}, width: 0, height: 0);
    }

    // Single node — just place it at origin.
    if (nodes.length == 1) {
      final node = nodes.values.first;
      node.x = 0;
      node.y = 0;
      return LayoutResult(
        nodes: nodes,
        width: node.width,
        height: node.height,
      );
    }

    // Build adjacency and parent lookup.
    final adjacency = <int, Set<int>>{};
    final parentsOf = <int, List<int>>{};
    for (final id in nodes.keys) {
      adjacency[id] = {};
    }
    for (final edge in edges) {
      adjacency[edge.sourceId]?.add(edge.destId);
      adjacency[edge.destId]?.add(edge.sourceId);
      parentsOf.putIfAbsent(edge.destId, () => []).add(edge.sourceId);
    }

    // Build child set for root identification verification.
    final childIds = <int>{};
    for (final edge in edges) {
      childIds.add(edge.destId);
    }

    // Initialize positions with wider horizontal spread.
    _initializePositions(nodes, edges, childIds, aspectRatio);

    // Simulation parameters.
    const repulsionStrength = 8000.0;
    const attractionStrength = 0.02;
    const idealEdgeLength = 220.0;
    const rootGravity = 0.06;
    const nonRootGravity = 0.002;
    final startTemperature = 200.0;

    final nodeList = nodes.values.toList();
    final n = nodeList.length;

    for (int iter = 0; iter < iterations; iter++) {
      final temperature =
          startTemperature * (1.0 - iter / iterations);

      // Reset velocities.
      for (final node in nodeList) {
        node.vx = 0;
        node.vy = 0;
      }

      // Repulsion — all pairs, node-size-aware.
      // Uses the gap between node bounding boxes rather than center
      // distance so large nodes don't overlap.
      for (int i = 0; i < n; i++) {
        for (int j = i + 1; j < n; j++) {
          final a = nodeList[i];
          final b = nodeList[j];
          var dx = (a.x + a.width / 2) - (b.x + b.width / 2);
          var dy = (a.y + a.height / 2) - (b.y + b.height / 2);
          var centerDist = math.sqrt(dx * dx + dy * dy);
          if (centerDist < 1.0) {
            // Jitter to avoid zero-distance.
            dx = (a.id.hashCode % 10 - 5).toDouble();
            dy = (b.id.hashCode % 10 - 5).toDouble();
            centerDist = math.sqrt(dx * dx + dy * dy);
            if (centerDist < 1.0) centerDist = 1.0;
          }

          // Minimum distance for no overlap (with padding).
          final minSepX = (a.width + b.width) / 2 + 20;
          final minSepY = (a.height + b.height) / 2 + 15;
          final minSep = math.sqrt(minSepX * minSepX + minSepY * minSepY);

          // Use effective distance: how far apart they are beyond
          // their combined radii. If overlapping, clamp to a small
          // value to create a very strong push-apart force.
          final effectiveDist = math.max(centerDist - minSep + 60, 5.0);

          // Inter-cluster repulsion: nodes in different clusters push
          // apart harder. But if either node has affinity with the other's
          // cluster (multi-parent), skip the penalty so they can sit
          // between their parent clusters.
          final bool diffCluster;
          if (a.cluster == -1 || b.cluster == -1 || a.cluster == b.cluster) {
            diffCluster = false;
          } else if (a.allClusters.contains(b.cluster) ||
              b.allClusters.contains(a.cluster)) {
            diffCluster = false; // multi-parent affinity
          } else {
            diffCluster = true;
          }
          final clusterMultiplier = diffCluster ? 5.0 : 1.0;

          final force = (repulsionStrength * clusterMultiplier) /
              (effectiveDist * effectiveDist);
          final fx = (dx / centerDist) * force;
          final fy = (dy / centerDist) * force;

          a.vx += fx;
          a.vy += fy;
          b.vx -= fx;
          b.vy -= fy;
        }
      }

      // Attraction — connected pairs (spring force).
      for (final edge in edges) {
        final a = nodes[edge.sourceId];
        final b = nodes[edge.destId];
        if (a == null || b == null) continue;

        final dx = b.x - a.x;
        final dy = b.y - a.y;
        var dist = math.sqrt(dx * dx + dy * dy);
        if (dist < 1.0) dist = 1.0;

        final force = attractionStrength * (dist - idealEdgeLength);
        final fx = (dx / dist) * force;
        final fy = (dy / dist) * force;

        a.vx += fx;
        a.vy += fy;
        b.vx -= fx;
        b.vy -= fy;
      }

      // Cluster forces:
      // - Roots pull toward their cluster centroid (stays central).
      // - Non-root nodes pull toward centroid of ALL their parents
      //   (not just one cluster root), so multi-parent nodes settle
      //   between their parents.

      // Compute cluster centroids for root centering.
      final clusterSumX = <int, double>{};
      final clusterSumY = <int, double>{};
      final clusterCount = <int, int>{};
      for (final node in nodeList) {
        if (node.cluster != -1) {
          clusterSumX[node.cluster] =
              (clusterSumX[node.cluster] ?? 0) + node.x;
          clusterSumY[node.cluster] =
              (clusterSumY[node.cluster] ?? 0) + node.y;
          clusterCount[node.cluster] =
              (clusterCount[node.cluster] ?? 0) + 1;
        }
      }

      for (final node in nodeList) {
        if (node.isRoot && node.cluster != -1) {
          // Pull root toward its cluster centroid so it stays central.
          final count = clusterCount[node.cluster] ?? 1;
          if (count > 1) {
            final cx = clusterSumX[node.cluster]! / count;
            final cy = clusterSumY[node.cluster]! / count;
            node.vx += (cx - node.x) * 0.02;
            node.vy += (cy - node.y) * 0.02;
          }
        } else if (!node.isRoot) {
          // Non-root: pull toward centroid of all parents.
          final parents = parentsOf[node.id];
          if (parents != null && parents.isNotEmpty) {
            var px = 0.0, py = 0.0;
            var count = 0;
            for (final pid in parents) {
              final parent = nodes[pid];
              if (parent != null) {
                px += parent.x;
                py += parent.y;
                count++;
              }
            }
            if (count > 0) {
              px /= count;
              py /= count;
              node.vx += (px - node.x) * 0.015;
              node.vy += (py - node.y) * 0.015;
            }
          }
        }
      }

      // Center gravity.
      for (final node in nodeList) {
        final gravity = node.isRoot ? rootGravity : nonRootGravity;
        node.vx -= node.x * gravity;
        node.vy -= node.y * gravity;
      }

      // Apply velocities, clamped to temperature.
      for (final node in nodeList) {
        final speed = math.sqrt(node.vx * node.vx + node.vy * node.vy);
        if (speed > temperature && speed > 0) {
          node.vx = (node.vx / speed) * temperature;
          node.vy = (node.vy / speed) * temperature;
        }
        node.x += node.vx;
        node.y += node.vy;
      }
    }

    // Normalize — shift so min x/y = 0.
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (final node in nodeList) {
      minX = math.min(minX, node.x);
      minY = math.min(minY, node.y);
      maxX = math.max(maxX, node.x + node.width);
      maxY = math.max(maxY, node.y + node.height);
    }

    for (final node in nodeList) {
      node.x -= minX;
      node.y -= minY;
    }

    return LayoutResult(
      nodes: nodes,
      width: maxX - minX,
      height: maxY - minY,
    );
  }

  /// Places root nodes in a small circle near center, non-root nodes near
  /// a parent with deterministic jitter.
  static void _initializePositions(
    Map<int, LayoutNode> nodes,
    List<LayoutEdge> edges,
    Set<int> childIds,
    double aspectRatio,
  ) {
    // Build parent lookup: child → list of parent IDs.
    final parentOf = <int, List<int>>{};
    for (final edge in edges) {
      parentOf.putIfAbsent(edge.destId, () => []).add(edge.sourceId);
    }

    final roots = nodes.values.where((n) => n.isRoot).toList();
    final nonRoots = nodes.values.where((n) => !n.isRoot).toList();

    // Place roots in an ellipse (wider than tall) so clusters spread
    // horizontally, matching typical screen proportions.
    if (roots.length == 1) {
      roots.first.x = 0;
      roots.first.y = 0;
    } else {
      final radius = 150.0 + roots.length * 40.0;
      for (int i = 0; i < roots.length; i++) {
        final angle = (2 * math.pi * i) / roots.length;
        roots[i].x = radius * aspectRatio * math.cos(angle);
        roots[i].y = radius * math.sin(angle);
      }
    }

    // Place non-roots near the centroid of all their parents (not just
    // one cluster root), so multi-parent nodes start between parents.
    for (final node in nonRoots) {
      final rng = math.Random(node.id);
      final parents = parentOf[node.id];
      if (parents != null && parents.isNotEmpty) {
        var px = 0.0, py = 0.0;
        var count = 0;
        for (final pid in parents) {
          final parent = nodes[pid];
          if (parent != null) {
            px += parent.x;
            py += parent.y;
            count++;
          }
        }
        if (count > 0) {
          node.x = px / count + (rng.nextDouble() - 0.5) * 150;
          node.y = py / count + (rng.nextDouble() - 0.5) * 150;
          continue;
        }
      }
      // Fallback: near cluster root or random.
      final clusterRoot = node.cluster != -1 ? nodes[node.cluster] : null;
      if (clusterRoot != null) {
        node.x = clusterRoot.x + (rng.nextDouble() - 0.5) * 200;
        node.y = clusterRoot.y + (rng.nextDouble() - 0.5) * 200;
      } else {
        node.x = (rng.nextDouble() - 0.5) * 300;
        node.y = (rng.nextDouble() - 0.5) * 300;
      }
    }
  }
}
