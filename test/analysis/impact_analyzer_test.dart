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
