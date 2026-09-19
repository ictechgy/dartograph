import 'dart:convert';
import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `query --with-source`가 보고된 선언 위치의 소스 줄을 붙이는지 검증한다.
/// 파일 읽기는 index가 아니라 CLI가 하고, 소스가 없는 합성 정점은 조용히
/// 생략되어야 한다.
void main() {
  late Directory root;
  late AnalyzerGraphResult indexed;

  Future<AnalyzerGraphResult> Function(String) injected() =>
      (_) async => indexed;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('query-source.');
    addTearDown(() => root.delete(recursive: true));
    File(p.join(root.path, 'lib', 'a.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('class Foo {\n  int x = 1;\n}\n');
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::Foo',
          sourceUri: 'project:lib/a.dart',
          line: 1,
        ),
      );
    indexed = AnalyzerGraphResult(graph: graph, limitations: const []);
  });

  Future<({int status, Map<String, Object?> document})> query(
    List<String> arguments,
  ) async {
    final output = StringBuffer();
    final status = await runDartograph(
      arguments,
      output: output,
      error: StringBuffer(),
      indexPackage: injected(),
    );
    return (
      status: status,
      document: output.isEmpty
          ? const <String, Object?>{}
          : jsonDecode(output.toString()) as Map<String, Object?>,
    );
  }

  test('omits source by default', () async {
    final result = await query(['query', 'Foo', root.path]);
    expect(result.status, ExitStatus.success.code);
    final subject =
        (result.document['result'] as Map<String, Object?>)['subject']
            as Map<String, Object?>;
    expect(subject.containsKey('source'), isFalse);
  });

  test('with-source attaches the declaration line', () async {
    final result = await query(['query', 'Foo', '--with-source', root.path]);
    expect(result.status, ExitStatus.success.code);
    final subject =
        (result.document['result'] as Map<String, Object?>)['subject']
            as Map<String, Object?>;
    expect(subject['source'], [
      {'line': 1, 'text': 'class Foo {'},
    ]);
  });

  test('source-context widens the line window', () async {
    final result = await query([
      'query',
      'Foo',
      '--with-source',
      '--source-context',
      '1',
      root.path,
    ]);
    expect(result.status, ExitStatus.success.code);
    final subject =
        (result.document['result'] as Map<String, Object?>)['subject']
            as Map<String, Object?>;
    // line 1에서 위로는 더 갈 수 없으므로 아래 줄만 넓어진다.
    expect(subject['source'], [
      {'line': 1, 'text': 'class Foo {'},
      {'line': 2, 'text': '  int x = 1;'},
    ]);
  });

  test('source-context without with-source is a usage error', () async {
    final result = await query([
      'query',
      'Foo',
      '--source-context',
      '1',
      root.path,
    ]);
    expect(result.status, ExitStatus.usage.code);
  });

  test('duplicate with-source is a usage error', () async {
    final result = await query([
      'query',
      'Foo',
      '--with-source',
      '--with-source',
      root.path,
    ]);
    expect(result.status, ExitStatus.usage.code);
  });

  test('batch attaches source to each result', () async {
    final requests = File(p.join(root.path, 'requests.json'))
      ..writeAsStringSync('["Foo"]');
    final result = await query([
      'query',
      '--batch',
      requests.path,
      '--with-source',
      root.path,
    ]);
    expect(result.status, ExitStatus.success.code);
    final results = result.document['results'] as List;
    final subject =
        ((results.single as Map)['result'] as Map)['subject']
            as Map<String, Object?>;
    expect(subject['source'], [
      {'line': 1, 'text': 'class Foo {'},
    ]);
  });
}
