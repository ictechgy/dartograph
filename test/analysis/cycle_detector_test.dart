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
