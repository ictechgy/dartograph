import 'package:dartograph/dartograph.dart';
import 'package:test/test.dart';

void main() {
  group('CodeGraph', () {
    test('rejects an edge whose source node is absent', () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'package:app/a.dart::A'));

      expect(
        () => graph.addEdge(
          const GraphEdge(
            sourceId: 'package:app/missing.dart::Missing',
            targetId: 'package:app/a.dart::A',
            kind: EdgeKind.reference,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects an edge whose target node is absent', () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'package:app/a.dart::A'));

      expect(
        () => graph.addEdge(
          const GraphEdge(
            sourceId: 'package:app/a.dart::A',
            targetId: 'package:app/missing.dart::Missing',
            kind: EdgeKind.reference,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('returns usage edges from a node in deterministic order', () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'package:app/z.dart::Z'))
        ..addNode(GraphNode(id: 'package:app/a.dart::A'))
        ..addNode(GraphNode(id: 'package:app/m.dart::M'))
        ..addEdge(
          const GraphEdge(
            sourceId: 'package:app/z.dart::Z',
            targetId: 'package:app/m.dart::M',
            kind: EdgeKind.reference,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'package:app/z.dart::Z',
            targetId: 'package:app/a.dart::A',
            kind: EdgeKind.call,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'package:app/z.dart::Z',
            targetId: 'package:app/a.dart::A',
            kind: EdgeKind.override,
          ),
        );

      expect(graph.usageEdgesFrom('package:app/z.dart::Z'), const [
        GraphEdge(
          sourceId: 'package:app/z.dart::Z',
          targetId: 'package:app/a.dart::A',
          kind: EdgeKind.call,
        ),
        GraphEdge(
          sourceId: 'package:app/z.dart::Z',
          targetId: 'package:app/a.dart::A',
          kind: EdgeKind.override,
        ),
        GraphEdge(
          sourceId: 'package:app/z.dart::Z',
          targetId: 'package:app/m.dart::M',
          kind: EdgeKind.reference,
        ),
      ]);
    });

    test('rejects duplicate node identifiers', () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'package:app/a.dart::A'));

      expect(
        () => graph.addNode(GraphNode(id: 'package:app/a.dart::A')),
        throwsArgumentError,
      );
    });

    test('exposes nodes and edges in stable order through read-only views', () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'z'))
        ..addNode(GraphNode(id: 'a'))
        ..addEdge(
          const GraphEdge(
            sourceId: 'z',
            targetId: 'a',
            kind: EdgeKind.reference,
          ),
        );

      expect(graph.nodes.keys, ['a', 'z']);
      expect(graph.edges, const [
        GraphEdge(sourceId: 'z', targetId: 'a', kind: EdgeKind.reference),
      ]);
      expect(
        () => graph.nodes['new'] = GraphNode(id: 'new'),
        throwsUnsupportedError,
      );
      expect(
        () => graph.edges.add(
          const GraphEdge(sourceId: 'a', targetId: 'z', kind: EdgeKind.call),
        ),
        throwsUnsupportedError,
      );
    });

    test('looks up nodes without rebuilding the sorted snapshot', () {
      final node = GraphNode(id: 'package:app/a.dart::A');
      final graph = CodeGraph()..addNode(node);

      expect(graph.containsNode(node.id), isTrue);
      expect(graph.containsNode('missing'), isFalse);
      expect(graph.node(node.id), same(node));
      expect(graph.node('missing'), isNull);
    });

    test('snapshots stay immutable when the mutable graph changes', () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'package:app/a.dart::A'));
      final snapshot = graph.snapshot();

      graph.addNode(GraphNode(id: 'package:app/b.dart::B'));

      expect(snapshot.nodes.map((node) => node.id), ['package:app/a.dart::A']);
      expect(snapshot.edges, isEmpty);
      expect(
        () => snapshot.nodes.add(GraphNode(id: 'package:app/c.dart::C')),
        throwsUnsupportedError,
      );
      expect(
        () => snapshot.edges.add(
          const GraphEdge(
            sourceId: 'package:app/a.dart::A',
            targetId: 'package:app/a.dart::A',
            kind: EdgeKind.reference,
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('GraphSnapshot sorts input and enforces graph invariants', () {
      final a = GraphNode(id: 'a');
      final b = GraphNode(id: 'b');
      final snapshot = GraphSnapshot(
        nodes: [b, a],
        edges: const [
          GraphEdge(sourceId: 'b', targetId: 'a', kind: EdgeKind.reference),
        ],
      );

      expect(snapshot.nodes, [a, b]);
      expect(snapshot.edges, const [
        GraphEdge(sourceId: 'b', targetId: 'a', kind: EdgeKind.reference),
      ]);
      expect(
        () => GraphSnapshot(nodes: [a, a], edges: const []),
        throwsArgumentError,
      );
      expect(
        () => GraphSnapshot(
          nodes: [a],
          edges: const [
            GraphEdge(sourceId: 'a', targetId: 'missing', kind: EdgeKind.call),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  test('GraphNode preserves source evidence independently from identity', () {
    final node = GraphNode(
      id: 'package:app/host.dart::GeneratedType',
      sourceUri: 'project:lib/host.g.dart',
      line: 12,
      column: 3,
      synthesized: true,
    );

    expect(node.id, 'package:app/host.dart::GeneratedType');
    expect(node.sourceUri, 'project:lib/host.g.dart');
    expect(node.line, 12);
    expect(node.column, 3);
    expect(node.synthesized, isTrue);
  });

  test('GraphNode has value semantics for graph snapshots', () {
    expect(
      GraphNode(
        id: 'package:app/a.dart::A',
        sourceUri: 'project:lib/a.dart',
        line: 2,
        column: 3,
      ),
      GraphNode(
        id: 'package:app/a.dart::A',
        sourceUri: 'project:lib/a.dart',
        line: 2,
        column: 3,
      ),
    );
  });

  test('GraphNode rejects invalid identity and source positions', () {
    expect(() => GraphNode(id: ''), throwsArgumentError);
    expect(() => GraphNode(id: 'a', line: 0), throwsArgumentError);
    expect(() => GraphNode(id: 'a', column: 0), throwsArgumentError);
  });

  test('GraphNode rejects contradictory declaration flags', () {
    expect(
      () => GraphNode(id: 'a', isAbstract: true),
      throwsArgumentError,
      reason: 'isAbstract requires a type declaration',
    );
    expect(
      () => GraphNode(id: 'a', isEnumConstant: true, isTypeDeclaration: true),
      throwsArgumentError,
      reason: 'an enum constant is never a type declaration',
    );
    // 추이 차단: isAbstract⇒isTypeDeclaration, isEnumConstant⇒¬isTypeDeclaration
    // 이므로 isAbstract+isEnumConstant 조합도 도달할 수 없다.
    expect(
      () => GraphNode(
        id: 'a',
        isAbstract: true,
        isTypeDeclaration: true,
        isEnumConstant: true,
      ),
      throwsArgumentError,
    );
  });

  test('equal GraphNodes are interchangeable in sets and maps', () {
    final first = GraphNode(
      id: 'a',
      sourceUri: 'project:lib/a.dart',
      line: 1,
      column: 2,
      synthesized: true,
      isTypeDeclaration: true,
    );
    final second = GraphNode(
      id: 'a',
      sourceUri: 'project:lib/a.dart',
      line: 1,
      column: 2,
      synthesized: true,
      isTypeDeclaration: true,
    );
    expect(first, second);
    expect({first, second}, hasLength(1));
    expect({first: 1}[second], 1);
    // 필드 하나(line)만 달라도 동등하지 않다(evidence 포함 값 비교).
    expect(
      first,
      isNot(
        GraphNode(
          id: 'a',
          sourceUri: 'project:lib/a.dart',
          line: 9,
          column: 2,
          synthesized: true,
          isTypeDeclaration: true,
        ),
      ),
    );
  });

  test('equal GraphEdges deduplicate in a set', () {
    const first = GraphEdge(sourceId: 'a', targetId: 'b', kind: EdgeKind.call);
    final second = GraphEdge(sourceId: 'a', targetId: 'b', kind: EdgeKind.call);

    expect({first, second}, hasLength(1));
  });

  test('EdgeKind distinguishes usage from structural relationships', () {
    expect(EdgeKind.values.where((kind) => kind.impliesUsage), [
      EdgeKind.call,
      EdgeKind.reference,
      EdgeKind.inheritance,
      EdgeKind.implements,
      EdgeKind.mixin,
      EdgeKind.override,
      EdgeKind.import,
      EdgeKind.export,
    ]);
    expect(EdgeKind.member.impliesUsage, isFalse);
  });
}
