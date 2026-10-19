import 'dart:math';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/impact_analyzer.dart';
import 'package:test/test.dart';

/// 라이브러리·선언·사용 간선을 갖춘 작은 합성 그래프를 만든다.
CodeGraph _graph({bool reversed = false, bool withCycle = false}) {
  final nodes = <GraphNode>[
    GraphNode(id: 'project:lib/a.dart', isLibrary: true),
    GraphNode(id: 'project:lib/a.dart::Foo', sourceUri: 'project:lib/a.dart'),
    GraphNode(id: 'project:lib/b.dart', isLibrary: true),
    GraphNode(id: 'project:lib/b.dart::Bar', sourceUri: 'project:lib/b.dart'),
    GraphNode(id: 'project:test/a_test.dart', isLibrary: true),
    GraphNode(
      id: 'project:test/a_test.dart::main',
      sourceUri: 'project:test/a_test.dart',
    ),
  ];
  final edges = <GraphEdge>[
    const GraphEdge(
      sourceId: 'project:lib/b.dart',
      targetId: 'project:lib/a.dart',
      kind: EdgeKind.import,
    ),
    const GraphEdge(
      sourceId: 'project:lib/b.dart::Bar',
      targetId: 'project:lib/a.dart::Foo',
      kind: EdgeKind.call,
    ),
    const GraphEdge(
      sourceId: 'project:test/a_test.dart',
      targetId: 'project:lib/b.dart',
      kind: EdgeKind.import,
    ),
    const GraphEdge(
      sourceId: 'project:test/a_test.dart::main',
      targetId: 'project:lib/b.dart::Bar',
      kind: EdgeKind.call,
    ),
    if (withCycle)
      const GraphEdge(
        sourceId: 'project:lib/a.dart',
        targetId: 'project:lib/b.dart',
        kind: EdgeKind.import,
      ),
  ];
  final graph = CodeGraph();
  final orderedNodes = reversed ? nodes.reversed : nodes;
  final orderedEdges = reversed ? edges.reversed : edges;
  for (final node in orderedNodes) {
    graph.addNode(node);
  }
  for (final edge in orderedEdges) {
    graph.addEdge(edge);
  }
  return graph;
}

void main() {
  test('usage closure reports depth, shortest path, and call sites', () {
    final report = ImpactAnalysis.analyze(
      _graph().snapshot(),
      changedSources: {'project:lib/a.dart'},
    );

    expect(report.changedSymbols, ['project:lib/a.dart::Foo']);
    expect(report.changedLibraries, ['project:lib/a.dart']);
    expect(report.impacted.map((item) => '${item.id}@${item.depth}').toList(), [
      'project:lib/b.dart@1',
      'project:lib/b.dart::Bar@1',
      'project:test/a_test.dart@2',
      'project:test/a_test.dart::main@2',
    ]);
    final bar = report.impacted.firstWhere(
      (item) => item.id == 'project:lib/b.dart::Bar',
    );
    expect(bar.path, ['project:lib/b.dart::Bar', 'project:lib/a.dart::Foo']);
    expect(report.callSites.single.toId, 'project:lib/a.dart::Foo');
    expect(report.callSites.single.fromId, 'project:lib/b.dart::Bar');
    expect(report.callSites.single.kind, 'call');
    expect(report.callSites.single.fromSource, 'lib/b.dart');
  });

  test(
    'related tests are deduplicated by file and keep the shallowest depth',
    () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
        ..addNode(
          GraphNode(
            id: 'project:lib/a.dart::Foo',
            sourceUri: 'project:lib/a.dart',
          ),
        )
        ..addNode(GraphNode(id: 'project:lib/b.dart', isLibrary: true))
        ..addNode(
          GraphNode(
            id: 'project:lib/b.dart::Bar',
            sourceUri: 'project:lib/b.dart',
          ),
        )
        ..addNode(GraphNode(id: 'project:test/x_test.dart', isLibrary: true))
        ..addNode(
          GraphNode(
            id: 'project:test/x_test.dart::main',
            sourceUri: 'project:test/x_test.dart',
          ),
        )
        ..addNode(
          GraphNode(
            id: 'project:test/x_test.dart::helper',
            sourceUri: 'project:test/x_test.dart',
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'project:lib/a.dart',
            targetId: 'project:lib/a.dart::Foo',
            kind: EdgeKind.member,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'project:test/x_test.dart::main',
            targetId: 'project:lib/a.dart::Foo',
            kind: EdgeKind.call,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'project:test/x_test.dart::helper',
            targetId: 'project:lib/b.dart::Bar',
            kind: EdgeKind.call,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'project:lib/b.dart::Bar',
            targetId: 'project:lib/a.dart::Foo',
            kind: EdgeKind.call,
          ),
        );

      final report = ImpactAnalysis.analyze(
        graph.snapshot(),
        changedSources: {'project:lib/a.dart'},
      );

      expect(report.tests.length, 1);
      expect(report.tests.single.source, 'test/x_test.dart');
      expect(report.tests.single.depth, 1);
      expect(report.tests.single.id, 'project:test/x_test.dart::main');
    },
  );

  test('maxDepth bounds traversal but not the seed set', () {
    final report = ImpactAnalysis.analyze(
      _graph().snapshot(),
      changedSources: {'project:lib/a.dart'},
      maxDepth: 1,
    );

    expect(report.impacted.map((item) => item.id).toList(), [
      'project:lib/b.dart',
      'project:lib/b.dart::Bar',
    ]);
  });

  test('limit truncates the report but not counts or risk', () {
    final full = ImpactAnalysis.analyze(
      _graph().snapshot(),
      changedSources: {'project:lib/a.dart'},
    );
    final limited = ImpactAnalysis.analyze(
      _graph().snapshot(),
      changedSources: {'project:lib/a.dart'},
      limit: 1,
    );

    expect(limited.impacted.length, 1);
    expect(limited.truncatedImpacted, full.impacted.length - 1);
    expect(limited.truncated, isTrue);
    expect(limited.risk.toJson(), full.risk.toJson());
    expect(
      limited.coverage.transitivelyImpacted,
      full.coverage.transitivelyImpacted,
    );
    expect(limited.coverage.missedWithoutPrecheck.length, 4);
  });

  test('a missing symbol is reported and seeds nothing', () {
    final report = ImpactAnalysis.analyze(
      _graph().snapshot(),
      changedSymbols: ['project:lib/a.dart::Ghost'],
    );

    expect(report.missingSymbols, ['project:lib/a.dart::Ghost']);
    expect(report.impacted, isEmpty);
  });

  test('symbol seeds propagate to their dependents', () {
    final report = ImpactAnalysis.analyze(
      _graph().snapshot(),
      changedSymbols: ['project:lib/a.dart::Foo'],
    );

    expect(report.changedSymbols, ['project:lib/a.dart::Foo']);
    // 심별 쓨앗은 그 선언이 속한 라이브러리도 함께 세운다 — 심별을 바꾸면 파일이
    // 바뀌고 그 파일을 import하는 라이브러리도 영향을 받는다.
    expect(report.impacted.map((item) => '${item.id}@${item.depth}').toList(), [
      'project:lib/b.dart@1',
      'project:lib/b.dart::Bar@1',
      'project:test/a_test.dart@2',
      'project:test/a_test.dart::main@2',
    ]);
  });

  test('output is invariant under node and edge input order', () {
    final forward = ImpactAnalysis.analyze(
      _graph().snapshot(),
      changedSources: {'project:lib/a.dart'},
    );
    final reversed = ImpactAnalysis.analyze(
      _graph(reversed: true).snapshot(),
      changedSources: {'project:lib/a.dart'},
    );

    expect(
      reversed.impacted.map((item) => item.toJson()).toList(),
      forward.impacted.map((item) => item.toJson()).toList(),
    );
    expect(
      reversed.callSites.map((item) => item.toJson()).toList(),
      forward.callSites.map((item) => item.toJson()).toList(),
    );
    expect(reversed.risk.toJson(), forward.risk.toJson());
  });

  test('risk factors expose cycle participation and missing tests', () {
    final report = ImpactAnalysis.analyze(
      _graph(withCycle: true).snapshot(),
      changedSources: {'project:lib/a.dart'},
    );

    final factors = {for (final f in report.risk.factors) f.name: f.weight};
    expect(factors['cycle-participation'], 15);
    expect(factors['test-coverage'], 0);
    // 순환 참여(15)가 더해져 점수가 순환 없는 그래프보다 15 높다.
    final withoutCycle = ImpactAnalysis.analyze(
      _graph().snapshot(),
      changedSources: {'project:lib/a.dart'},
    );
    expect(report.risk.score, withoutCycle.risk.score + 15);
    // 팩터는 가중치 내림차순, 동률은 이름 오름차순으로 결정적이다.
    final sorted = [...report.risk.factors];
    sorted.sort((a, b) {
      final byWeight = b.weight.compareTo(a.weight);
      return byWeight != 0 ? byWeight : a.name.compareTo(b.name);
    });
    expect(
      report.risk.factors.map((f) => f.name).toList(),
      sorted.map((f) => f.name).toList(),
    );
  });

  test('cycle participation needs a usage cycle through a changed seed', () {
    // 사용 간선만 순환을 만든다. 씨앗을 지나지 않는 순환, member 간선으로만 닫히는
    // 고리는 순환 참여가 아니다.
    final cases = <String, (List<(String, String, EdgeKind)>, int)>{
      'acyclic chain': (
        [('s', 'a', EdgeKind.call), ('a', 'b', EdgeKind.call)],
        0,
      ),
      'seed self loop': ([('s', 's', EdgeKind.call)], 15),
      'self loop past the seed': (
        [('s', 'a', EdgeKind.call), ('a', 'a', EdgeKind.reference)],
        0,
      ),
      'cycle past the seed': (
        [
          ('s', 'a', EdgeKind.call),
          ('a', 'b', EdgeKind.call),
          ('b', 'a', EdgeKind.call),
        ],
        0,
      ),
      'cycle closed by a member edge': (
        [('s', 'a', EdgeKind.member), ('a', 's', EdgeKind.call)],
        0,
      ),
      'two-node cycle': (
        [('s', 'a', EdgeKind.call), ('a', 's', EdgeKind.inheritance)],
        15,
      ),
      'long cycle': (
        [
          ('s', 'a', EdgeKind.call),
          ('a', 'b', EdgeKind.reference),
          ('b', 'c', EdgeKind.implements),
          ('c', 's', EdgeKind.call),
        ],
        15,
      ),
    };
    for (final MapEntry(key: name, value: (edges, weight)) in cases.entries) {
      expect(
        _cycleWeight(_usageGraph(edges), const ['s']),
        weight,
        reason: name,
      );
    }
  });

  test(
    'cycle participation sees a seed cycle reached from an earlier seed',
    () {
      // 앞 씨앗 `a`는 `s`의 순환에 닿지만 그 위에 있지 않다. `a`만 바뀌면 순환
      // 참여가 아니고, `s`도 바뀌면 순환 참여다.
      final graph = _usageGraph([
        ('a', 'u', EdgeKind.call),
        ('u', 's', EdgeKind.call),
        ('s', 'u', EdgeKind.call),
      ]);
      expect(_cycleWeight(graph, const ['a', 's']), 15);
      expect(_cycleWeight(graph, const ['a']), 0);

      // 순환이 씨앗 아닌 `r`에서 열리고 `s` 너머의 q·w를 다 지나야 r로 닫힌다.
      // 앞 씨앗 `a`에서 순환에 들어가므로 q·w를 먼저 마쳐도 `s`를 r의 순환에
      // 묶어야 한다. 탐색 방향과 상관없이 이 모양이 나오게 두 방향을 모두 둔다.
      final late = [
        ('a', 'r', EdgeKind.call),
        ('r', 's', EdgeKind.call),
        ('s', 'q', EdgeKind.call),
        ('q', 'w', EdgeKind.call),
        ('w', 'r', EdgeKind.call),
      ];
      final lateReversed = [
        for (final (from, to, kind) in late) (to, from, kind),
      ];
      for (final edges in [late, lateReversed]) {
        expect(_cycleWeight(_usageGraph(edges), const ['a', 's']), 15);
        expect(_cycleWeight(_usageGraph(edges), const ['a']), 0);
      }
    },
  );

  test('cycle participation checks only the first 50 sorted seeds', () {
    // 씨앗 51개가 모두 공통 정점 hub에 닿고, hub는 마지막 씨앗과만 순환을 이룬다.
    List<(String, String, EdgeKind)> edgesWithCycleAt(int cyclic) => [
      for (var i = 0; i <= 50; i++) (_seed(i), 'hub', EdgeKind.call),
      ('hub', _seed(cyclic), EdgeKind.call),
    ];
    final seeds = [for (var i = 0; i <= 50; i++) _seed(i)];

    expect(_cycleWeight(_usageGraph(edgesWithCycleAt(50)), seeds), 0);
    expect(_cycleWeight(_usageGraph(edgesWithCycleAt(49)), seeds), 15);
  });

  test('cycle participation matches the per-seed search on random graphs', () {
    final random = Random(20261018);
    for (var round = 0; round < 400; round++) {
      final size = 2 + random.nextInt(round.isEven ? 8 : 90);
      final nodes = [for (var i = 0; i < size; i++) 'n${'$i'.padLeft(2, '0')}'];
      final edges = [
        for (
          var i = random.nextInt(size * (1 + random.nextInt(3)));
          i >= 0;
          i--
        )
          (
            nodes[random.nextInt(size)],
            nodes[random.nextInt(size)],
            random.nextInt(5) == 0 ? EdgeKind.member : EdgeKind.call,
          ),
      ];
      // 씨앗 비율을 회차마다 바꾼다. 씨앗이 드물어야 씨앗 아닌 정점에서 열린
      // 순환을 끝까지 묶어야 답이 나오는 경우가 자주 생긴다.
      final seedPercent = const [67, 50, 25, 12][(round ~/ 2) % 4];
      final seeds = [
        for (final node in nodes)
          if (random.nextInt(100) < seedPercent) node,
      ];
      // 순환 판정은 maxDepth와 상관없이 그래프 전체를 본다.
      final maxDepth = const [null, 1, 2][(round ~/ 8) % 3];
      expect(
        _cycleWeight(
          _usageGraph(edges, nodes: nodes),
          seeds,
          maxDepth: maxDepth,
        ),
        _legacyHasCyclicSeed(seeds, edges) ? 15 : 0,
        reason: 'round $round maxDepth $maxDepth seeds $seeds edges $edges',
      );
    }
  });

  test('cycle participation follows a long usage chain past maxDepth', () {
    // 의존자 사슬 c050000 → … → c000001 → s다. 순환 판정은 maxDepth와 상관없이
    // 그래프 전체를 본다. 재귀 탐색은 깊이 약 1만에서 스택이 넘치므로 5만 깊이로
    // 명시적 스택 탐색인지도 함께 확인한다.
    const length = 50000;
    String link(int index) => 'c${'$index'.padLeft(6, '0')}';
    final chain = [
      for (var i = 1; i <= length; i++)
        (link(i), i == 1 ? 's' : link(i - 1), EdgeKind.call),
    ];

    expect(_cycleWeight(_usageGraph(chain), const ['s'], maxDepth: 1), 0);
    expect(
      _cycleWeight(
        _usageGraph([...chain, ('s', link(length), EdgeKind.reference)]),
        const ['s'],
        maxDepth: 1,
      ),
      15,
    );
  });

  test('a changed source without any node is reported unattributed', () {
    final report = ImpactAnalysis.analyze(
      _graph().snapshot(),
      changedSources: {'project:lib/a.dart', 'project:lib/ghost.dart'},
    );

    expect(report.unattributedSources, ['project:lib/ghost.dart']);
  });

  test('deeper symbols score lower than shallow ones', () {
    final report = ImpactAnalysis.analyze(
      _graph().snapshot(),
      changedSources: {'project:lib/a.dart'},
    );

    final shallow = report.impacted.firstWhere(
      (item) => item.id == 'project:lib/b.dart::Bar',
    );
    final deep = report.impacted.firstWhere(
      (item) => item.id == 'project:test/a_test.dart::main',
    );
    expect(shallow.riskScore, greaterThan(deep.riskScore));
    expect(shallow.riskLevel, 'high');
  });
}

/// 정렬 순서가 번호 순서와 같은 씨앗 ID다.
String _seed(int index) => 's${'$index'.padLeft(2, '0')}';

/// `::` 없는 ID의 선언 정점과 주어진 간선만 가진 그래프다 — 라이브러리 씨앗이
/// 덧붙지 않아 씨앗이 요청한 심볼 그대로다.
GraphSnapshot _usageGraph(
  List<(String, String, EdgeKind)> edges, {
  List<String> nodes = const [],
}) => GraphSnapshot(
  nodes: [
    for (final id in {
      ...nodes,
      for (final (from, to, _) in edges) ...[from, to],
    })
      GraphNode(id: id),
  ],
  edges: [
    for (final (from, to, kind) in edges)
      GraphEdge(sourceId: from, targetId: to, kind: kind),
  ],
);

/// [seeds]를 변경 심볼로 넣었을 때 cycle-participation 팩터의 가중치다.
int _cycleWeight(GraphSnapshot graph, List<String> seeds, {int? maxDepth}) =>
    ImpactAnalysis.analyze(graph, changedSymbols: seeds, maxDepth: maxDepth)
        .risk
        .factors
        .singleWhere((factor) => factor.name == 'cycle-participation')
        .weight;

/// 성능 수정 전의 씨앗별 전방 탐색이다 — 결과 동등성의 오라클로 옮겨 둔다.
bool _legacyHasCyclicSeed(
  List<String> seeds,
  List<(String, String, EdgeKind)> edges,
) {
  final sortedSeeds = seeds.toSet().toList()..sort();
  if (sortedSeeds.isEmpty) return false;
  final forward = <String, List<String>>{};
  for (final (from, to, kind) in edges.toSet()) {
    if (!kind.impliesUsage) continue;
    (forward[from] ??= <String>[]).add(to);
  }
  for (final seed in sortedSeeds.take(50)) {
    final seen = <String>{};
    final queue = <String>[seed];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final next in forward[current] ?? const <String>[]) {
        if (next == seed) return true;
        if (seen.add(next)) queue.add(next);
      }
    }
  }
  return false;
}
