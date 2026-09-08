import 'dart:math';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/cycle_detector.dart';
import 'package:test/test.dart';

void main() {
  test('iterative SCC reports a deterministic cycle and edge to break', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'c', sourceUri: 'project:lib/c.dart', line: 3))
      ..addNode(GraphNode(id: 'a', sourceUri: 'project:lib/a.dart', line: 1))
      ..addNode(GraphNode(id: 'b', sourceUri: 'project:lib/b.dart', line: 2))
      ..addEdge(
        const GraphEdge(sourceId: 'b', targetId: 'c', kind: EdgeKind.reference),
      )
      ..addEdge(
        const GraphEdge(sourceId: 'c', targetId: 'a', kind: EdgeKind.call),
      )
      ..addEdge(
        const GraphEdge(sourceId: 'a', targetId: 'b', kind: EdgeKind.import),
      );

    final cycles = CycleDetector().detect(graph.snapshot());

    expect(cycles, hasLength(1));
    expect(cycles.single.component, ['a', 'b', 'c']);
    expect(cycles.single.path, ['a', 'b', 'c', 'a']);
    expect(cycles.single.breakCandidate.toJson(), {
      'from': 'a',
      'kind': 'import',
      'to': 'b',
    });
    expect(cycles.single.evidence.map((edge) => edge.toJson()).toList(), [
      {'from': 'a', 'kind': 'import', 'to': 'b'},
      {'from': 'b', 'kind': 'reference', 'to': 'c'},
      {'from': 'c', 'kind': 'call', 'to': 'a'},
    ]);
  });

  test('self loops count while member-only loops do not', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'member'))
      ..addNode(GraphNode(id: 'self'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'member',
          targetId: 'member',
          kind: EdgeKind.member,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'self',
          targetId: 'self',
          kind: EdgeKind.call,
        ),
      );

    final cycles = CycleDetector().detect(graph.snapshot());

    expect(cycles.map((cycle) => cycle.component), [
      ['self'],
    ]);
    expect(cycles.single.path, ['self', 'self']);
  });

  test('a long acyclic graph is processed without recursive stack growth', () {
    final graph = CodeGraph();
    for (var index = 0; index < 20000; index++) {
      graph.addNode(GraphNode(id: index.toString().padLeft(5, '0')));
      if (index > 0) {
        graph.addEdge(
          GraphEdge(
            sourceId: (index - 1).toString().padLeft(5, '0'),
            targetId: index.toString().padLeft(5, '0'),
            kind: EdgeKind.reference,
          ),
        );
      }
    }

    expect(CycleDetector().detect(graph.snapshot()), isEmpty);
  });

  test('iterative SCC components match a reachability oracle', () {
    final random = Random(20260904);
    for (var sample = 0; sample < 150; sample++) {
      const nodeCount = 7;
      final graph = CodeGraph();
      for (var index = 0; index < nodeCount; index++) {
        graph.addNode(GraphNode(id: '$index'));
      }
      for (var source = 0; source < nodeCount; source++) {
        for (var target = 0; target < nodeCount; target++) {
          if (random.nextDouble() < 0.18) {
            graph.addEdge(
              GraphEdge(
                sourceId: '$source',
                targetId: '$target',
                kind: EdgeKind.reference,
              ),
            );
          }
        }
      }
      final snapshot = graph.snapshot();
      final actual = CycleDetector()
          .detect(snapshot)
          .map((cycle) => cycle.component.join(','))
          .toList();
      final expected = _cyclicComponents(snapshot);

      expect(actual, expected, reason: 'sample $sample');
      for (final cycle in CycleDetector().detect(snapshot)) {
        expect(cycle.evidence, hasLength(cycle.path.length - 1));
        expect(cycle.evidence, contains(cycle.breakCandidate));
      }
    }
  });

  test(
    'explain returns the cycle a member takes part in with its break edge',
    () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'a'))
        ..addNode(GraphNode(id: 'b'))
        ..addNode(GraphNode(id: 'c'))
        ..addNode(GraphNode(id: 'leaf'))
        ..addEdge(
          const GraphEdge(sourceId: 'a', targetId: 'b', kind: EdgeKind.call),
        )
        ..addEdge(
          const GraphEdge(sourceId: 'b', targetId: 'c', kind: EdgeKind.call),
        )
        ..addEdge(
          const GraphEdge(sourceId: 'c', targetId: 'a', kind: EdgeKind.call),
        )
        ..addEdge(
          const GraphEdge(sourceId: 'a', targetId: 'leaf', kind: EdgeKind.call),
        );

      final explained = CycleDetector().explain(graph.snapshot(), 'b');
      expect(explained.known, isTrue);
      expect(explained.cycles, hasLength(1));
      expect(explained.cycles.single.component, ['a', 'b', 'c']);
      // leaf는 a가 호출하지만 어떤 순환에도 속하지 않는다.
      expect(explained.cycles.single.breakCandidate.toJson(), {
        'from': 'a',
        'kind': 'call',
        'to': 'b',
      });
    },
  );

  test(
    'explain reports an acyclic but present node as known with no cycle',
    () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'a'))
        ..addNode(GraphNode(id: 'leaf'))
        ..addEdge(
          const GraphEdge(sourceId: 'a', targetId: 'leaf', kind: EdgeKind.call),
        );

      final explained = CycleDetector().explain(graph.snapshot(), 'leaf');
      expect(explained.known, isTrue);
      expect(explained.cycles, isEmpty);
    },
  );

  test('explain marks an id absent from the graph as unknown', () {
    final graph = CodeGraph()..addNode(GraphNode(id: 'a'));
    final explained = CycleDetector().explain(graph.snapshot(), 'missing');
    expect(explained.known, isFalse);
    expect(explained.cycles, isEmpty);
    expect(explained.id, 'missing');
  });

  test('explain returns a self-loop cycle for the node itself', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'self'))
      ..addNode(GraphNode(id: 'other'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'self',
          targetId: 'self',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'self',
          targetId: 'other',
          kind: EdgeKind.reference,
        ),
      );

    final explained = CycleDetector().explain(graph.snapshot(), 'self');
    expect(explained.known, isTrue);
    expect(explained.cycles, hasLength(1));
    expect(explained.cycles.single.component, ['self']);
    expect(explained.cycles.single.path, ['self', 'self']);
    // other는 self가 참조하지만 순환에 속하지 않는다.
    expect(CycleDetector().explain(graph.snapshot(), 'other').cycles, isEmpty);
  });
}

List<String> _cyclicComponents(GraphSnapshot graph) {
  final outgoing = <String, Set<String>>{
    for (final node in graph.nodes) node.id: <String>{},
  };
  for (final edge in graph.edges.where((edge) => edge.kind.impliesUsage)) {
    outgoing[edge.sourceId]!.add(edge.targetId);
  }
  final reachability = <String, Set<String>>{
    for (final node in graph.nodes) node.id: _reachable(node.id, outgoing),
  };
  final remaining = graph.nodes.map((node) => node.id).toSet();
  final components = <String>[];
  while (remaining.isNotEmpty) {
    final first = remaining.reduce((a, b) => a.compareTo(b) < 0 ? a : b);
    final component =
        remaining
            .where(
              (candidate) =>
                  reachability[first]!.contains(candidate) &&
                  reachability[candidate]!.contains(first),
            )
            .toList()
          ..sort();
    remaining.removeAll(component);
    if (component.length > 1 || outgoing[first]!.contains(first)) {
      components.add(component.join(','));
    }
  }
  return components..sort();
}

Set<String> _reachable(String start, Map<String, Set<String>> outgoing) {
  final seen = <String>{start};
  final queue = <String>[start];
  for (var index = 0; index < queue.length; index++) {
    for (final target in outgoing[queue[index]]!) {
      if (seen.add(target)) queue.add(target);
    }
  }
  return seen;
}
