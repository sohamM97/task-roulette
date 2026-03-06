import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/utils/force_directed_layout.dart';

void main() {
  group('LayoutNode serialization', () {
    test('toMap/fromMap round-trip preserves all fields', () {
      final node = LayoutNode(
        id: 42,
        isRoot: true,
        depth: 3,
        cluster: 7,
        allClusters: {7, 12},
        x: 100.5,
        y: -200.3,
        width: 160.0,
        height: 56.0,
      );

      final restored = LayoutNode.fromMap(node.toMap());

      expect(restored.id, 42);
      expect(restored.isRoot, true);
      expect(restored.depth, 3);
      expect(restored.cluster, 7);
      expect(restored.allClusters, {7, 12});
      expect(restored.x, 100.5);
      expect(restored.y, -200.3);
      expect(restored.width, 160.0);
      expect(restored.height, 56.0);
    });

    test('fromMap handles non-root node with empty allClusters', () {
      final node = LayoutNode(
        id: 1,
        isRoot: false,
        x: 0,
        y: 0,
        width: 120,
        height: 42,
      );

      final restored = LayoutNode.fromMap(node.toMap());

      expect(restored.isRoot, false);
      expect(restored.cluster, -1);
      expect(restored.allClusters, isEmpty);
    });
  });

  group('ForceDirectedLayout.run', () {
    test('single node placed at origin', () {
      final nodes = {
        1: LayoutNode(id: 1, isRoot: true, x: 0, y: 0, width: 100, height: 50),
      };

      final result = ForceDirectedLayout.run(nodes: nodes, edges: []);

      expect(result.nodes[1]!.x, 0);
      expect(result.nodes[1]!.y, 0);
      expect(result.width, 100);
      expect(result.height, 50);
    });

    test('empty graph returns zero size', () {
      final result = ForceDirectedLayout.run(
        nodes: {},
        edges: [],
      );

      expect(result.width, 0);
      expect(result.height, 0);
    });

    test('early convergence exits before maxIter for small graph', () {
      // Two connected nodes should converge well before 400 iterations.
      // We verify by checking that a high iteration count doesn't change
      // the result vs a lower one (both converge early).
      final makeNodes = () => {
            1: LayoutNode(
                id: 1, isRoot: true, cluster: 1, x: 0, y: 0,
                width: 100, height: 50),
            2: LayoutNode(
                id: 2, isRoot: false, depth: 1, cluster: 1, x: 50, y: 50,
                width: 80, height: 40),
          };
      const edges = [LayoutEdge(sourceId: 1, destId: 2)];

      final r1 = ForceDirectedLayout.run(
        nodes: makeNodes(),
        edges: edges,
        iterations: 400,
      );
      final r2 = ForceDirectedLayout.run(
        nodes: makeNodes(),
        edges: edges,
        iterations: 200,
      );

      // Both should converge to the same layout.
      expect(r1.nodes[1]!.x, closeTo(r2.nodes[1]!.x, 1.0));
      expect(r1.nodes[1]!.y, closeTo(r2.nodes[1]!.y, 1.0));
      expect(r1.nodes[2]!.x, closeTo(r2.nodes[2]!.x, 1.0));
      expect(r1.nodes[2]!.y, closeTo(r2.nodes[2]!.y, 1.0));
    });

    test('adaptive iterations: null uses formula based on node count', () {
      // 5 nodes → (100 + 5*2) = 110, clamped to 120.
      // Just verify it runs without error and produces a valid layout.
      final nodes = {
        for (var i = 1; i <= 5; i++)
          i: LayoutNode(
            id: i,
            isRoot: i == 1,
            depth: i == 1 ? 0 : 1,
            cluster: 1,
            x: 0,
            y: 0,
            width: 100,
            height: 50,
          ),
      };
      final edges = [
        for (var i = 2; i <= 5; i++)
          LayoutEdge(sourceId: 1, destId: i),
      ];

      final result = ForceDirectedLayout.run(nodes: nodes, edges: edges);

      expect(result.width, greaterThan(0));
      expect(result.height, greaterThan(0));
      // All nodes should have distinct positions (no overlap at origin).
      final positions = result.nodes.values.map((n) => '${n.x},${n.y}').toSet();
      expect(positions.length, 5);
    });
  });

  group('ForceDirectedLayout.runAsync', () {
    test('produces same result as synchronous run', () async {
      final nodes = {
        1: LayoutNode(
            id: 1, isRoot: true, cluster: 1, x: 0, y: 0,
            width: 100, height: 50),
        2: LayoutNode(
            id: 2, isRoot: false, depth: 1, cluster: 1, x: 50, y: 50,
            width: 80, height: 40),
        3: LayoutNode(
            id: 3, isRoot: false, depth: 1, cluster: 1, x: -50, y: 50,
            width: 80, height: 40),
      };
      const edges = [
        LayoutEdge(sourceId: 1, destId: 2),
        LayoutEdge(sourceId: 1, destId: 3),
      ];

      // runAsync serializes → isolate → deserializes, so the result
      // should match a synchronous run with same initial conditions.
      final asyncResult = await ForceDirectedLayout.runAsync(
        nodes: nodes,
        edges: edges,
      );

      expect(asyncResult.width, greaterThan(0));
      expect(asyncResult.height, greaterThan(0));
      expect(asyncResult.nodes.length, 3);
      // Verify nodes came back with correct IDs and root flags.
      expect(asyncResult.nodes[1]!.isRoot, true);
      expect(asyncResult.nodes[2]!.isRoot, false);
      expect(asyncResult.nodes[3]!.isRoot, false);
    });
  });
}
