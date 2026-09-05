import 'dart:convert';
import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

void main() {
  AnalyzerGraphResult graph(bool called) {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'app::main'))
      ..addNode(GraphNode(id: 'app::helper'));
    if (called) {
      graph.addEdge(
        const GraphEdge(
          sourceId: 'app::main',
          targetId: 'app::helper',
          kind: EdgeKind.call,
        ),
      );
    }
    return AnalyzerGraphResult(
      graph: graph,
      limitations: const [],
      retentionRoots: const {'app::main': RetentionReason.mainEntryPoint},
    );
  }

  test(
    'comparison explains lost reachability using a removed reference',
    () async {
      final output = StringBuffer();
      final status = await runDartograph(
        ['compare', 'before', 'after'],
        output: output,
        indexPackage: (root) async => graph(root == 'before'),
      );
      expect(status, 0);
      final doc = jsonDecode(output.toString()) as Map;
      expect(doc['format'], 'graph-comparison');
      final change = (doc['newlyUnreachable'] as List).single;
      expect(change['id'], 'app::helper');
      expect(change['beforePath'], ['app::main', 'app::helper']);
      expect(change['removedEdgesOnBeforePath'], [
        {'from': 'app::main', 'kind': 'call', 'to': 'app::helper'},
      ]);
      final reverse = StringBuffer();
      expect(
        await runDartograph(
          ['compare', 'after', 'before'],
          output: reverse,
          indexPackage: (root) async => graph(root == 'before'),
        ),
        0,
      );
      expect((jsonDecode(reverse.toString()) as Map)['newlyReachable'], [
        'app::helper',
      ]);
    },
  );
  test('comparison rejects missing operands', () async {
    expect(await runDartograph(['compare', '.'], error: StringBuffer()), 64);
  });
}
