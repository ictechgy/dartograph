import 'dart:convert';
import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File rules;
  late AnalyzerGraphResult indexed;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('dartograph-phase5-cli.');
    rules = File('${temporary.path}/layers.yaml');
    await rules.writeAsString('''
layers:
  - name: first
    match: [a]
  - name: second
    match: [b]
rules:
  - name: first cannot reach second
    from: first
    deny: [second]
''');
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'b', sourceUri: 'project:lib/b.dart', line: 2))
      ..addNode(GraphNode(id: 'a', sourceUri: 'project:lib/a.dart', line: 1))
      ..addEdge(
        const GraphEdge(sourceId: 'a', targetId: 'b', kind: EdgeKind.call),
      )
      ..addEdge(
        const GraphEdge(sourceId: 'b', targetId: 'a', kind: EdgeKind.reference),
      );
    indexed = AnalyzerGraphResult(
      graph: graph,
      limitations: const [AnalyzerLimitation.conditionalConfiguration],
    );
  });

  tearDown(() => temporary.delete(recursive: true));

  Future<int> run(List<String> arguments, StringBuffer output) => runDartograph(
    arguments,
    output: output,
    error: StringBuffer(),
    indexPackage: (_) async => indexed,
  );

  test(
    'cycles emits evidence and only strict mode turns findings into status 1',
    () async {
      final normal = StringBuffer();
      final strict = StringBuffer();

      expect(
        await run(['cycles', temporary.path], normal),
        ExitStatus.success.code,
      );
      expect(
        await run(['cycles', '--strict', temporary.path], strict),
        ExitStatus.findings.code,
      );
      expect(strict.toString(), normal.toString());
      expect(
        await run(['cycles', temporary.path, '--strict'], StringBuffer()),
        ExitStatus.findings.code,
      );
      final document = jsonDecode(normal.toString()) as Map<String, Object?>;
      expect(document['limitations'], isNotEmpty);
      final finding =
          (document['cycles']! as List<Object?>).single as Map<String, Object?>;
      expect(finding, containsPair('path', ['a', 'b', 'a']));
      expect(finding, contains('breakCandidate'));
    },
  );

  test(
    'rules reads YAML and preserves violation evidence under strict mode',
    () async {
      final output = StringBuffer();

      final status = await run([
        'rules',
        '--config',
        rules.path,
        '--strict',
        temporary.path,
      ], output);

      expect(status, ExitStatus.findings.code);
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      final violation =
          (document['violations']! as List<Object?>).single
              as Map<String, Object?>;
      expect(violation, containsPair('path', ['a', 'b']));
      expect(violation, contains('evidence'));
      expect(document['limitations'], isNotEmpty);
    },
  );

  test(
    'metrics is deterministic and strict mode flags non-isolated distance over tolerance',
    () async {
      final first = StringBuffer();
      final second = StringBuffer();

      expect(
        await run(['metrics', temporary.path], first),
        ExitStatus.success.code,
      );
      expect(
        await run(['metrics', '--strict', temporary.path], second),
        ExitStatus.findings.code,
      );
      expect(second.toString(), first.toString());
      expect(
        await run(['metrics', temporary.path, '--strict'], StringBuffer()),
        ExitStatus.findings.code,
      );
      final document = jsonDecode(first.toString()) as Map<String, Object?>;
      expect(document.keys, ['limitations', 'metrics', 'tolerance']);
      expect(document['tolerance'], 0.3);
    },
  );

  test('rules returns analysis failure for invalid configuration', () async {
    await rules.writeAsString('layers: wrong');
    final error = StringBuffer();

    final status = await runDartograph(
      ['rules', '--config', rules.path, temporary.path],
      error: error,
      indexPackage: (_) async => indexed,
    );

    expect(status, ExitStatus.failure.code);
    expect(error.toString(), contains('Analysis failed:'));
    expect(error.toString(), isNot(contains(rules.path)));
  });
}
