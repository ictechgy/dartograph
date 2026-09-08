import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/affected_analyzer.dart';
import 'package:test/test.dart';

void main() {
  test('changed libraries collect transitive import and export dependents', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart'))
      ..addNode(GraphNode(id: 'project:lib/b.dart'))
      ..addNode(
        GraphNode(id: 'project:lib/c.dart', sourceUri: 'project:lib/c.dart'),
      )
      ..addNode(GraphNode(id: 'project:lib/d.dart'))
      ..addNode(GraphNode(id: 'project:lib/e.dart'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart',
          targetId: 'project:lib/b.dart',
          kind: EdgeKind.import,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/b.dart',
          targetId: 'project:lib/c.dart',
          kind: EdgeKind.import,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/d.dart',
          targetId: 'project:lib/c.dart',
          kind: EdgeKind.export,
        ),
      );

    final result = AffectedAnalysis.analyze(graph.snapshot(), {
      'project:lib/c.dart',
    });

    expect(result.changed, ['project:lib/c.dart']);
    expect(result.affected.map((item) => item.toJson()).toList(), [
      {
        'depth': 2,
        'id': 'project:lib/a.dart',
        'path': [
          'project:lib/a.dart',
          'project:lib/b.dart',
          'project:lib/c.dart',
        ],
      },
      {
        'depth': 1,
        'id': 'project:lib/b.dart',
        'path': ['project:lib/b.dart', 'project:lib/c.dart'],
      },
      {
        'depth': 1,
        'id': 'project:lib/d.dart',
        'path': ['project:lib/d.dart', 'project:lib/c.dart'],
      },
    ]);
  });

  test('a changed part file is attributed to its host library', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/host.dart'))
      ..addNode(
        GraphNode(
          id: 'project:lib/host.dart::User',
          sourceUri: 'project:lib/host.g.dart',
        ),
      )
      ..addNode(GraphNode(id: 'project:lib/consumer.dart'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/consumer.dart',
          targetId: 'project:lib/host.dart',
          kind: EdgeKind.import,
        ),
      );

    final result = AffectedAnalysis.analyze(graph.snapshot(), {
      'project:lib/host.g.dart',
    });

    expect(result.changed, ['project:lib/host.dart']);
    expect(result.affected.single.id, 'project:lib/consumer.dart');
    expect(result.affected.single.path, [
      'project:lib/consumer.dart',
      'project:lib/host.dart',
    ]);
  });

  test('import cycles terminate and usage edges do not propagate', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart'))
      ..addNode(
        GraphNode(id: 'project:lib/b.dart', sourceUri: 'project:lib/b.dart'),
      )
      ..addNode(GraphNode(id: 'project:lib/a.dart::run'))
      ..addNode(GraphNode(id: 'project:lib/b.dart::work'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart',
          targetId: 'project:lib/b.dart',
          kind: EdgeKind.import,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/b.dart',
          targetId: 'project:lib/a.dart',
          kind: EdgeKind.import,
        ),
      )
      // 선언 수준 call 간선은 라이브러리 영향 반경을 전파하지 않는다.
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::run',
          targetId: 'project:lib/b.dart::work',
          kind: EdgeKind.call,
        ),
      );

    final result = AffectedAnalysis.analyze(graph.snapshot(), {
      'project:lib/b.dart',
    });

    expect(result.changed, ['project:lib/b.dart']);
    expect(result.affected.single.id, 'project:lib/a.dart');
    expect(result.affected.single.depth, 1);
    expect(result.affected.single.path, [
      'project:lib/a.dart',
      'project:lib/b.dart',
    ]);
  });

  test('the nearest changed library wins deterministically', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart'))
      ..addNode(
        GraphNode(id: 'project:lib/b.dart', sourceUri: 'project:lib/b.dart'),
      )
      ..addNode(
        GraphNode(id: 'project:lib/d.dart', sourceUri: 'project:lib/d.dart'),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart',
          targetId: 'project:lib/b.dart',
          kind: EdgeKind.import,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart',
          targetId: 'project:lib/d.dart',
          kind: EdgeKind.import,
        ),
      );

    final result = AffectedAnalysis.analyze(graph.snapshot(), {
      'project:lib/d.dart',
      'project:lib/b.dart',
    });

    expect(result.changed, ['project:lib/b.dart', 'project:lib/d.dart']);
    expect(result.affected.single.id, 'project:lib/a.dart');
    expect(result.affected.single.depth, 1);
    // 동률은 정렬된 씨앗 순서(b < d)로 깨져 결정적이다.
    expect(result.affected.single.path, [
      'project:lib/a.dart',
      'project:lib/b.dart',
    ]);
  });

  test('no changed sources answer with empty lists', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart'))
      ..addNode(GraphNode(id: 'project:lib/b.dart'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart',
          targetId: 'project:lib/b.dart',
          kind: EdgeKind.import,
        ),
      );

    final result = AffectedAnalysis.analyze(graph.snapshot(), const {});

    expect(result.changed, isEmpty);
    expect(result.affected, isEmpty);
  });

  test('a changed source whose library node is absent does not seed', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart'))
      ..addNode(
        GraphNode(
          id: 'project:lib/ghost.dart::run',
          sourceUri: 'project:lib/ghost.dart',
        ),
      );

    final result = AffectedAnalysis.analyze(graph.snapshot(), {
      'project:lib/ghost.dart',
    });

    // 선언 ID의 라이브러리 접두가 노드로 없으면(합성 그래프·매핑 오류) 씨앗이
    // 되지 않는다. 존재하지 않는 라이브러리를 changed로 답하지 않는다.
    expect(result.changed, isEmpty);
    expect(result.affected, isEmpty);
  });
}
