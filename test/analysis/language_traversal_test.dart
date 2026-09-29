import 'dart:collection';
import 'dart:math';

import 'package:dartograph/src/analysis/language_traversal.dart';
import 'package:dartograph/src/core/graph_edge.dart';
import 'package:dartograph/src/core/graph_node.dart';
import 'package:dartograph/src/core/graph_snapshot.dart';
import 'package:test/test.dart';

/// 다중 root 한 번 순회를 root별 무차별 BFS와 대조한다(오라클). 계약 예시
/// (LANGUAGE-TRAVERSAL "필드 의미")도 손으로 적은 기대값으로 확인한다.
void main() {
  GraphSnapshot graph(
    List<String> ids,
    List<(String, String, EdgeKind)> edges,
  ) => GraphSnapshot(
    nodes: [for (final id in ids) GraphNode(id: id)],
    edges: [
      for (final (source, target, kind) in edges)
        GraphEdge(sourceId: source, targetId: target, kind: kind),
    ],
  );

  test('contract example: roots reached by other roots keep other roots', () {
    // B는 A의 의존자, C는 B의 의존자다(C → B → A 호출).
    final snapshot = graph(
      ['A', 'B', 'C'],
      [('B', 'A', EdgeKind.call), ('C', 'B', EdgeKind.call)],
    );
    final result = LanguageTraversal.traverse(snapshot, [
      'A',
      'B',
    ], TraversalDirection.dependents);
    final rows = {for (final row in result.reached) row.node.id: row};
    expect(rows.keys, ['B', 'C']);
    expect(
      [rows['B']!.via, rows['B']!.depth, rows['B']!.roots],
      [
        'A',
        1,
        [0],
      ],
    );
    expect(
      [rows['C']!.via, rows['C']!.depth, rows['C']!.roots],
      [
        'B',
        1,
        [0, 1],
      ],
    );
  });

  test('contract example: a root row depth is a baseline, via a witness', () {
    // A → W → V → R와 R → V (의존 방향). root A(0)·R(1).
    final snapshot = graph(
      ['A', 'R', 'V', 'W'],
      [
        ('W', 'A', EdgeKind.call),
        ('V', 'W', EdgeKind.call),
        ('R', 'V', EdgeKind.call),
        ('V', 'R', EdgeKind.call),
      ],
    );
    final result = LanguageTraversal.traverse(snapshot, [
      'A',
      'R',
    ], TraversalDirection.dependents);
    final rows = {for (final row in result.reached) row.node.id: row};
    expect(
      [rows['V']!.via, rows['V']!.depth, rows['V']!.roots],
      [
        'R',
        1,
        [0, 1],
      ],
    );
    expect(
      [rows['R']!.via, rows['R']!.depth, rows['R']!.roots],
      [
        'V',
        3,
        [0],
      ],
    );
  });

  test(
    'override dispatch is candidate evidence, the relation itself direct',
    () {
      // Impl.load가 Repo.load를 재정의하고 UI가 Repo.load를 부른다.
      final snapshot = graph(
        ['Impl.load', 'Repo.load', 'UI.build'],
        [
          ('Impl.load', 'Repo.load', EdgeKind.override),
          ('UI.build', 'Repo.load', EdgeKind.call),
        ],
      );
      final fromImpl = LanguageTraversal.traverse(snapshot, [
        'Impl.load',
      ], TraversalDirection.dependents);
      expect(
        {
          for (final row in fromImpl.reached)
            row.node.id: [row.evidence, row.relationships],
        },
        {
          'Repo.load': [
            TraversalEvidence.candidate,
            ['dispatch'],
          ],
          'UI.build': [
            TraversalEvidence.candidate,
            ['call'],
          ],
        },
      );
      final fromBase = LanguageTraversal.traverse(snapshot, [
        'Repo.load',
      ], TraversalDirection.dependents);
      expect(
        {for (final row in fromBase.reached) row.node.id: row.evidence},
        {
          'Impl.load': TraversalEvidence.direct,
          'UI.build': TraversalEvidence.direct,
        },
      );
    },
  );

  test('unknown roots stay listed without a node', () {
    final snapshot = graph(['A'], const []);
    final result = LanguageTraversal.traverse(snapshot, [
      'A',
      'missing',
      'A',
    ], TraversalDirection.dependents);
    expect([for (final root in result.roots) root.id], ['A', 'missing']);
    expect(result.rootNotFound, isTrue);
  });

  test('depth limit truncates listing but not reachability', () {
    final ids = [for (var i = 0; i < 6; i++) 'n$i'];
    final snapshot = graph(ids, [
      for (var i = 1; i < 6; i++) (ids[i], ids[i - 1], EdgeKind.call),
    ]);
    final result = LanguageTraversal.traverse(
      snapshot,
      ['n0'],
      TraversalDirection.dependents,
      depthLimit: 3,
    );
    expect([for (final row in result.reached) row.node.id], ['n1', 'n2', 'n3']);
    expect(result.depthTruncated, isTrue);
  });

  test('single pass equals brute-force per-root BFS on random graphs', () {
    final random = Random(20260929);
    for (var round = 0; round < 60; round++) {
      final size = 3 + random.nextInt(25);
      final ids = [
        for (var i = 0; i < size; i++) 'v${i.toString().padLeft(2, '0')}',
      ];
      final edges = <(String, String, EdgeKind)>{};
      final count = random.nextInt(size * 3);
      for (var i = 0; i < count; i++) {
        final kind = EdgeKind.values[random.nextInt(EdgeKind.values.length)];
        edges.add((ids[random.nextInt(size)], ids[random.nextInt(size)], kind));
      }
      final snapshot = graph(ids, edges.toList());
      final roots = {
        for (var i = 0; i < 1 + random.nextInt(4); i++)
          ids[random.nextInt(size)],
      }.toList();
      for (final direction in TraversalDirection.values) {
        _checkAgainstBruteForce(snapshot, roots, direction);
      }
    }
  });
}

/// root별 BFS로 계약의 정의를 직접 계산해 한 번 순회 결과와 비교한다.
void _checkAgainstBruteForce(
  GraphSnapshot snapshot,
  List<String> roots,
  TraversalDirection direction,
) {
  final full = <String, Set<String>>{};
  final direct = <String, Set<String>>{};
  for (final edge in snapshot.edges) {
    if (!edge.kind.impliesUsage || edge.sourceId == edge.targetId) continue;
    final forward = direction == TraversalDirection.dependencies;
    final from = forward ? edge.sourceId : edge.targetId;
    final to = forward ? edge.targetId : edge.sourceId;
    (full[from] ??= {}).add(to);
    (direct[from] ??= {}).add(to);
    if (edge.kind == EdgeKind.override) (full[to] ??= {}).add(from);
  }
  final distances = [for (final root in roots) _bfs(full, root)];
  final directReach = [for (final root in roots) _bfs(direct, root)];
  final result = LanguageTraversal.traverse(snapshot, roots, direction);
  final rows = {for (final row in result.reached) row.node.id: row};
  final expectedIds = <String>{};
  for (final node in snapshot.nodes) {
    final reaching = [
      for (var i = 0; i < roots.length; i++)
        if (roots[i] != node.id && distances[i].containsKey(node.id)) i,
    ];
    if (reaching.isEmpty) continue;
    expectedIds.add(node.id);
    final row = rows[node.id];
    expect(row, isNotNull, reason: '${node.id} reached');
    expect(row!.roots, reaching, reason: '${node.id} roots');
    final depth = reaching.map((i) => distances[i][node.id]!).reduce(min);
    expect(row.depth, depth, reason: '${node.id} depth');
    final directEverywhere = reaching.every(
      (i) => directReach[i].containsKey(node.id),
    );
    expect(
      row.evidence,
      directEverywhere ? TraversalEvidence.direct : TraversalEvidence.candidate,
      reason: '${node.id} evidence',
    );
    _checkVia(row, rows, roots, full);
  }
  expect(rows.keys.toSet(), expectedIds);
  final order = [for (final row in result.reached) (row.depth, row.node.id)];
  final sorted = [...order]
    ..sort((a, b) {
      final byDepth = a.$1.compareTo(b.$1);
      return byDepth != 0 ? byDepth : a.$2.compareTo(b.$2);
    });
  expect(order, sorted);
}

/// via 간선이 실제로 있고, root가 아닌 정점은 부모 depth + 1이다.
void _checkVia(
  TraversalReached row,
  Map<String, TraversalReached> rows,
  List<String> roots,
  Map<String, Set<String>> full,
) {
  expect(full[row.via]?.contains(row.node.id), isTrue, reason: 'via edge');
  if (row.depth == 1) {
    expect(roots, contains(row.via));
    expect(row.roots, contains(roots.indexOf(row.via)));
  } else if (!roots.contains(row.node.id)) {
    expect(rows[row.via]!.depth, row.depth - 1);
  }
}

Map<String, int> _bfs(Map<String, Set<String>> adjacency, String root) {
  final distances = <String, int>{root: 0};
  final queue = Queue<String>()..add(root);
  while (queue.isNotEmpty) {
    final current = queue.removeFirst();
    for (final next in adjacency[current] ?? const <String>{}) {
      if (distances.containsKey(next)) continue;
      distances[next] = distances[current]! + 1;
      queue.add(next);
    }
  }
  return distances;
}
