import 'dart:convert';
import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

void main() {
  test('batch rejects option-shaped root before indexing', () async {
    final directory = await Directory.systemTemp.createTemp('query-batch.');
    addTearDown(() => directory.delete(recursive: true));
    final requests = File('${directory.path}/requests.json');
    await requests.writeAsString('["Live"]');
    var calls = 0;
    expect(
      await runDartograph(
        ['query', '--batch', requests.path, '--baseline'],
        error: StringBuffer(),
        indexPackage: (_) async {
          calls++;
          throw StateError('unexpected indexing');
        },
      ),
      64,
    );
    expect(calls, 0);
  });
  test(
    'batch handles ambiguity and baseline without losing individual status',
    () async {
      final directory = await Directory.systemTemp.createTemp('query-batch.');
      addTearDown(() => directory.delete(recursive: true));
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'app::A.run'))
        ..addNode(GraphNode(id: 'app::B.run'));
      final indexed = AnalyzerGraphResult(graph: graph, limitations: const []);
      final baseline = '${directory.path}/baseline.json';
      expect(
        await runDartograph(
          ['baseline', '--write', baseline, '.'],
          output: StringBuffer(),
          indexPackage: (_) async => indexed,
        ),
        0,
      );
      final requests = File('${directory.path}/requests.json');
      await requests.writeAsString('["run", "app::A.run"]');
      final output = StringBuffer();
      expect(
        await runDartograph(
          ['query', '--batch', requests.path, '--baseline', baseline, '.'],
          output: output,
          indexPackage: (_) async => indexed,
        ),
        0,
      );
      final results = (jsonDecode(output.toString()) as Map)['results'] as List;
      expect(results.first['status'], 'ambiguous');
      expect(
        results.last['result']['reachability']['suppressedByBaseline'],
        true,
      );
    },
  );
  test(
    'batch preserves request order and indexes once including misses',
    () async {
      final directory = await Directory.systemTemp.createTemp('query-batch.');
      addTearDown(() => directory.delete(recursive: true));
      final requests = File('${directory.path}/requests.json');
      await requests.writeAsString('["Live", "Missing", "Live"]');
      var calls = 0;
      final output = StringBuffer();
      final graph = CodeGraph()..addNode(GraphNode(id: 'app::Live'));
      final status = await runDartograph(
        ['query', '--batch', requests.path, '.'],
        output: output,
        indexPackage: (_) async {
          calls++;
          return AnalyzerGraphResult(graph: graph, limitations: const []);
        },
      );
      expect(status, 64);
      expect(calls, 1);
      final document = jsonDecode(output.toString()) as Map;
      expect(document['format'], 'symbol-query-batch');
      expect((document['results'] as List).map((e) => e['status']), [
        'found',
        'notFound',
        'found',
      ]);
    },
  );

  test('malformed batch is rejected before indexing', () async {
    final directory = await Directory.systemTemp.createTemp('query-batch.');
    addTearDown(() => directory.delete(recursive: true));
    final requests = File('${directory.path}/requests.json');
    for (final source in ['{}', '[1]', '[]', '[""]', '{']) {
      await requests.writeAsString(source);
      var calls = 0;
      final status = await runDartograph(
        ['query', '--batch', requests.path, '.'],
        error: StringBuffer(),
        indexPackage: (_) async {
          calls++;
          throw StateError('must not index');
        },
      );
      expect(status, 64);
      expect(calls, 0);
    }
  });
}
