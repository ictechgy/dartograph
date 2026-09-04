import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/architecture_metrics.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Martin metrics count distinct dependencies and sort deterministically',
    () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'a', isTypeDeclaration: true))
        ..addNode(GraphNode(id: 'b', isTypeDeclaration: true, isAbstract: true))
        ..addNode(GraphNode(id: 'c'))
        ..addEdge(
          const GraphEdge(sourceId: 'a', targetId: 'b', kind: EdgeKind.call),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'a',
            targetId: 'b',
            kind: EdgeKind.reference,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'c',
            targetId: 'b',
            kind: EdgeKind.reference,
          ),
        );

      final metrics = ArchitectureMetricsCalculator().calculate(
        graph.snapshot(),
      );
      final byId = {for (final item in metrics) item.id: item};

      expect(byId['a']!.toJson(), {
        'abstractness': 0.0,
        'afferentCoupling': 0,
        'distance': 0.0,
        'efferentCoupling': 1,
        'id': 'a',
        'instability': 1.0,
        'isolated': false,
      });
      expect(byId['b']!.afferentCoupling, 2);
      expect(byId['b']!.abstractness, 1.0);
      expect(metrics.map((item) => item.id), ['a', 'b', 'c']);
    },
  );

  test(
    'zero denominators are defined as zero and isolated nodes sort last',
    () {
      final graph = CodeGraph()..addNode(GraphNode(id: 'alone'));

      final metrics = ArchitectureMetricsCalculator().calculate(
        graph.snapshot(),
      );

      expect(metrics.single.instability, 0.0);
      expect(metrics.single.abstractness, 0.0);
      expect(metrics.single.distance, 1.0);
      expect(metrics.single.isolated, isTrue);
    },
  );

  test('metrics aggregate type composition and coupling by library', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'package:app/a.dart'))
      ..addNode(
        GraphNode(id: 'package:app/a.dart::Concrete', isTypeDeclaration: true),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/a.dart::Port',
          isTypeDeclaration: true,
          isAbstract: true,
        ),
      )
      ..addNode(GraphNode(id: 'package:app/b.dart'))
      ..addNode(
        GraphNode(
          id: 'package:app/b.dart::Repository',
          isTypeDeclaration: true,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/a.dart::Concrete',
          targetId: 'package:app/a.dart::Port',
          kind: EdgeKind.reference,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/a.dart::Concrete',
          targetId: 'package:app/b.dart::Repository',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/a.dart::Port',
          targetId: 'package:app/b.dart::Repository',
          kind: EdgeKind.reference,
        ),
      );

    final metrics = ArchitectureMetricsCalculator().calculate(graph.snapshot());
    final byId = {for (final item in metrics) item.id: item};

    expect(byId.keys, {'package:app/a.dart', 'package:app/b.dart'});
    expect(byId['package:app/a.dart']!.abstractness, 0.5);
    expect(byId['package:app/a.dart']!.efferentCoupling, 1);
    expect(byId['package:app/a.dart']!.afferentCoupling, 0);
    expect(byId['package:app/b.dart']!.afferentCoupling, 1);
  });
}
