import 'dart:convert';
import 'package:dartograph/dartograph.dart';

/// 같은 그래프·질의를 반복 분석 방식과 공유 세션 방식으로 측정한다.
void main() {
  final graph = CodeGraph();
  for (var i = 0; i < 2000; i++) {
    graph.addNode(GraphNode(id: 'app::node$i'));
    if (i > 0) {
      graph.addEdge(
        GraphEdge(
          sourceId: 'app::node${i - 1}',
          targetId: 'app::node$i',
          kind: EdgeKind.call,
        ),
      );
    }
  }
  final snapshot = graph.snapshot();
  const roots = {'app::node0': RetentionReason.mainEntryPoint};
  final requests = [for (var i = 0; i < 100; i++) 'app::node$i'];
  final watch = Stopwatch()..start();
  final separate = [
    for (final name in requests)
      SymbolQuerySession(
        graph: snapshot,
        roots: roots,
        limitations: const [],
      ).query(name),
  ];
  final separateMicros = watch.elapsedMicroseconds;
  watch.reset();
  final session = SymbolQuerySession(
    graph: snapshot,
    roots: roots,
    limitations: const [],
  );
  final batch = [for (final name in requests) session.query(name)];
  final batchMicros = watch.elapsedMicroseconds;
  if (jsonEncode(separate) != jsonEncode(batch)) {
    throw StateError('Query results differ');
  }
  print(
    jsonEncode({
      'nodes': 2000,
      'queries': requests.length,
      'separateMicros': separateMicros,
      'sessionMicros': batchMicros,
      'identicalResults': true,
    }),
  );
}
