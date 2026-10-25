import 'dart:io';

import 'package:dartograph/src/analysis/impact_analyzer.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'real analyzer override facts connect implementation edits to base-typed callers',
    () async {
      final root = await Directory.systemTemp.createTemp('impact-dispatch.');
      addTearDown(() => root.delete(recursive: true));
      final source = File(p.join(root.path, 'lib', 'api.dart'))
        ..createSync(recursive: true);
      source.writeAsStringSync('''
abstract interface class Api { int value(); }
class Impl implements Api { @override int value() => 1; }
int invoke(Api api) => api.value();
''');
      final indexed = await AnalyzerGraphIndex().index(root.path);
      final report = ImpactAnalysis.analyze(
        indexed.graph.snapshot(),
        changedSymbols: ['project:lib/api.dart::Impl.value'],
      );
      final caller = report.impacted.singleWhere(
        (item) => item.id == 'project:lib/api.dart::invoke',
      );
      expect(caller.path, [
        'project:lib/api.dart::invoke',
        'project:lib/api.dart::Api.value',
        'project:lib/api.dart::Impl.value',
      ]);
      expect(
        caller.pathEvidence.last['traversal'],
        'implementation-to-contract',
      );
      expect(
        caller.pathEvidence.last['from'],
        'project:lib/api.dart::Impl.value',
      );
      expect(caller.pathEvidence.last['to'], 'project:lib/api.dart::Api.value');

      final firstCapture = await captureAnalysisInputs(root.path);
      source.writeAsStringSync(
        source.readAsStringSync().replaceFirst('=> 1', '=> 2'),
      );
      final secondCapture = await captureAnalysisInputs(root.path);
      expect(firstCapture.contentHash, isNot(secondCapture.contentHash));
      final reindexed = await AnalyzerGraphIndex().index(root.path);
      expect(
        reindexed.graph.snapshot().edges,
        indexed.graph.snapshot().edges,
        reason:
            'body-only edits need content freshness even with identical topology',
      );
    },
  );
}
