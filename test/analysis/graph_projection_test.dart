import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/graph_projection.dart';
import 'package:test/test.dart';

void main() {
  GraphSnapshot sample() => GraphSnapshot(
    nodes: [
      GraphNode(id: 'project:lib/a.dart', sourceUri: 'project:lib/a.dart'),
      GraphNode(
        id: 'project:lib/a.dart::Foo',
        sourceUri: 'project:lib/a.dart',
        line: 1,
        isTypeDeclaration: true,
      ),
      GraphNode(
        id: 'project:lib/a.dart::Foo.bar',
        sourceUri: 'project:lib/a.dart',
        line: 2,
      ),
      GraphNode(id: 'project:lib/a.dart::top', sourceUri: 'project:lib/a.dart'),
      GraphNode(id: 'project:lib/b.dart', sourceUri: 'project:lib/b.dart'),
      GraphNode(
        id: 'project:lib/b.dart::Baz',
        sourceUri: 'project:lib/b.dart',
        isTypeDeclaration: true,
      ),
      GraphNode(id: 'package:app/src/x.dart'),
    ],
    edges: const [
      GraphEdge(
        sourceId: 'project:lib/a.dart',
        targetId: 'project:lib/b.dart',
        kind: EdgeKind.import,
      ),
      GraphEdge(
        sourceId: 'project:lib/a.dart::Foo.bar',
        targetId: 'project:lib/b.dart::Baz',
        kind: EdgeKind.call,
      ),
      GraphEdge(
        sourceId: 'project:lib/a.dart::Foo',
        targetId: 'project:lib/a.dart::Foo.bar',
        kind: EdgeKind.member,
      ),
      GraphEdge(
        sourceId: 'project:lib/a.dart::top',
        targetId: 'project:lib/a.dart::Foo',
        kind: EdgeKind.reference,
      ),
    ],
  );

  test('symbol level is the identity projection', () {
    final graph = sample();
    expect(GraphProjection.atLevel(graph, GraphLevel.symbol), same(graph));
  });

  test('file level folds declarations into libraries', () {
    final projected = GraphProjection.atLevel(sample(), GraphLevel.file);

    expect(projected.nodes.map((node) => node.id).toList(), [
      'package:app/src/x.dart',
      'project:lib/a.dart',
      'project:lib/b.dart',
    ]);
    // 라이브러리 대표 노드는 실재 노드의 필드를 보존한다.
    expect(
      projected.nodes
          .firstWhere((node) => node.id == 'project:lib/a.dart')
          .sourceUri,
      'project:lib/a.dart',
    );
    // 멤버·라이브러리 내부 관계는 자기 순환이 되어 사라지고, 경계 간선은
    // 종류별로 남는다(중복은 한 번).
    expect(
      projected.edges
          .map((edge) => '${edge.sourceId} ${edge.kind.name} ${edge.targetId}')
          .toList(),
      [
        'project:lib/a.dart call project:lib/b.dart',
        'project:lib/a.dart import project:lib/b.dart',
      ],
    );
  });

  test('type level folds members into their container declarations', () {
    final projected = GraphProjection.atLevel(sample(), GraphLevel.type);

    expect(projected.nodes.map((node) => node.id).toList(), [
      'package:app/src/x.dart',
      'project:lib/a.dart',
      'project:lib/a.dart::Foo',
      'project:lib/a.dart::top',
      'project:lib/b.dart',
      'project:lib/b.dart::Baz',
    ]);
    expect(
      projected.edges
          .map((edge) => '${edge.sourceId} ${edge.kind.name} ${edge.targetId}')
          .toList(),
      [
        'project:lib/a.dart import project:lib/b.dart',
        'project:lib/a.dart::Foo call project:lib/b.dart::Baz',
        'project:lib/a.dart::top reference project:lib/a.dart::Foo',
      ],
    );
  });

  test('a member without a container node keeps itself', () {
    final orphan = GraphSnapshot(
      nodes: [GraphNode(id: 'project:lib/a.dart::Ghost.run')],
      edges: const [],
    );

    final projected = GraphProjection.atLevel(orphan, GraphLevel.type);

    expect(projected.nodes.single.id, 'project:lib/a.dart::Ghost.run');
  });

  test('collapse summarizes libraries to folder depth', () {
    final fileLevel = GraphProjection.atLevel(sample(), GraphLevel.file);

    final depthOne = GraphProjection.collapse(fileLevel, 1);
    expect(depthOne.nodes.map((node) => node.id).toList(), [
      'package:app',
      'project:lib',
    ]);
    // 같은 폴더로 접힌 라이브러리 사이 간선은 자기 순환이 되어 사라진다.
    expect(depthOne.edges, isEmpty);
    // 폴더 대표는 파일이 아니므로 위치 필드를 발명하지 않는다.
    expect(
      depthOne.nodes.firstWhere((node) => node.id == 'project:lib').sourceUri,
      isNull,
    );

    // depth 2: `package:`는 패키지명이 첫 세그먼트라 `package:app/src`로
    // 접히고, 두 세그먼트인 `project:lib/*.dart`는 그대로다.
    final depthTwo = GraphProjection.collapse(fileLevel, 2);
    expect(depthTwo.nodes.map((node) => node.id).toList(), [
      'package:app/src',
      'project:lib/a.dart',
      'project:lib/b.dart',
    ]);
    expect(depthTwo.edges, hasLength(2));
  });

  test('collapse below one is rejected', () {
    expect(() => GraphProjection.collapse(sample(), 0), throwsArgumentError);
  });

  test('projections are deterministic across runs', () {
    final first = GraphProjection.atLevel(sample(), GraphLevel.file);
    final second = GraphProjection.atLevel(sample(), GraphLevel.file);
    expect(
      first.nodes.map((node) => node.id).toList(),
      second.nodes.map((node) => node.id).toList(),
    );
    expect(first.edges.toSet(), second.edges.toSet());
  });
}
