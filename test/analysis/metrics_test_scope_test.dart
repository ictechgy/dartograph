import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/architecture_metrics.dart';
import 'package:test/test.dart';

void main() {
  test(
    'test libraries do not become metric subjects or production coupling',
    () {
      final graph = CodeGraph()
        ..addNode(
          GraphNode(
            id: 'package:app/math.dart',
            sourceUri: 'project:lib/math.dart',
            isLibrary: true,
          ),
        )
        ..addNode(
          GraphNode(
            id: 'project:bin/main.dart',
            sourceUri: 'project:bin/main.dart',
            isLibrary: true,
          ),
        )
        ..addNode(
          GraphNode(
            id: 'project:test/math_test.dart',
            sourceUri: 'project:test/math_test.dart',
            isLibrary: true,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'project:bin/main.dart',
            targetId: 'package:app/math.dart',
            kind: EdgeKind.import,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'project:test/math_test.dart',
            targetId: 'package:app/math.dart',
            kind: EdgeKind.import,
          ),
        );
      final metrics = ArchitectureMetricsCalculator().calculate(
        graph.snapshot(),
      );
      expect(
        metrics.map((item) => item.id),
        isNot(contains('project:test/math_test.dart')),
      );
      expect(
        metrics
            .singleWhere((item) => item.id == 'package:app/math.dart')
            .afferentCoupling,
        1,
      );
      final includingTests = ArchitectureMetricsCalculator().calculate(
        graph.snapshot(),
        includeTests: true,
      );
      expect(
        includingTests.map((item) => item.id),
        contains('project:test/math_test.dart'),
      );
      expect(
        includingTests
            .singleWhere((item) => item.id == 'package:app/math.dart')
            .afferentCoupling,
        2,
      );
    },
  );
}
