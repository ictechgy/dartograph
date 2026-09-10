import 'dart:convert';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/export/graph_exporter.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

void main() {
  AnalyzerGraphResult indexed() {
    final graph = CodeGraph()
      ..addNode(
        GraphNode(id: 'project:lib/a.dart', sourceUri: 'project:lib/a.dart'),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::Foo',
          sourceUri: 'project:lib/a.dart',
          line: 1,
          isTypeDeclaration: true,
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::Foo.bar',
          sourceUri: 'project:lib/a.dart',
          line: 2,
        ),
      )
      ..addNode(
        GraphNode(id: 'project:lib/b.dart', sourceUri: 'project:lib/b.dart'),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/b.dart::Baz',
          sourceUri: 'project:lib/b.dart',
          isTypeDeclaration: true,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart',
          targetId: 'project:lib/b.dart',
          kind: EdgeKind.import,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::Foo.bar',
          targetId: 'project:lib/b.dart::Baz',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::Foo',
          targetId: 'project:lib/a.dart::Foo.bar',
          kind: EdgeKind.member,
        ),
      );
    return AnalyzerGraphResult(graph: graph, limitations: const []);
  }

  test('graph --format dot colors nodes that participate in cycles', () async {
    // a→b→a 순환: 참여 정점 둘만 붉게 색칠되고 순환 밖 c는 그대로다.
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'a'))
      ..addNode(GraphNode(id: 'b'))
      ..addNode(GraphNode(id: 'c'))
      ..addEdge(
        const GraphEdge(sourceId: 'a', targetId: 'b', kind: EdgeKind.call),
      )
      ..addEdge(
        const GraphEdge(sourceId: 'b', targetId: 'a', kind: EdgeKind.call),
      )
      ..addEdge(
        const GraphEdge(sourceId: 'c', targetId: 'a', kind: EdgeKind.call),
      );
    final output = StringBuffer();
    expect(
      await runDartograph(
        ['graph', '--format', 'dot', '.'],
        output: output,
        indexPackage: (_) async =>
            AnalyzerGraphResult(graph: graph, limitations: const []),
      ),
      ExitStatus.success.code,
    );
    expect(
      output.toString(),
      'digraph dartograph {\n'
      '  "a" [color=red fontcolor=red];\n'
      '  "b" [color=red fontcolor=red];\n'
      '  "c";\n'
      '  "a" -> "b" [label="call"];\n'
      '  "b" -> "a" [label="call"];\n'
      '  "c" -> "a" [label="call"];\n'
      '}\n',
    );

    // 같은 CLI 경로라도 순환이 없으면 색칠이 없다(기존 출력 바이트 보존).
    final acyclic = StringBuffer();
    expect(
      await runDartograph(
        ['graph', '--format', 'dot', '.'],
        output: acyclic,
        indexPackage: (_) async => AnalyzerGraphResult(
          graph: CodeGraph()
            ..addNode(GraphNode(id: 'a'))
            ..addNode(GraphNode(id: 'b'))
            ..addEdge(
              const GraphEdge(
                sourceId: 'a',
                targetId: 'b',
                kind: EdgeKind.call,
              ),
            ),
          limitations: const [],
        ),
      ),
      ExitStatus.success.code,
    );
    expect(acyclic.toString(), isNot(contains('color=red')));
  });

  test('graph --level file answers the library graph', () async {
    final output = StringBuffer();
    expect(
      await runDartograph(
        ['graph', '--format', 'json', '--level', 'file', '.'],
        output: output,
        indexPackage: (_) async => indexed(),
      ),
      ExitStatus.success.code,
    );
    expect(
      output.toString(),
      '{"edges":[{"kind":"call","source":"project:lib/a.dart","target":'
      '"project:lib/b.dart"},{"kind":"import","source":"project:lib/a.dart",'
      '"target":"project:lib/b.dart"}],"limitations":[],"nodes":[{"id":'
      '"project:lib/a.dart","isAbstract":false,"isTypeDeclaration":false,'
      '"sourceUri":"project:lib/a.dart","synthesized":false},{"id":'
      '"project:lib/b.dart","isAbstract":false,"isTypeDeclaration":false,'
      '"sourceUri":"project:lib/b.dart","synthesized":false}]}\n',
    );
  });

  test('graph --level type folds members into containers', () async {
    final output = StringBuffer();
    expect(
      await runDartograph(
        ['graph', '--format', 'json', '--level', 'type', '.'],
        output: output,
        indexPackage: (_) async => indexed(),
      ),
      ExitStatus.success.code,
    );
    expect(
      output.toString(),
      '{"edges":[{"kind":"import","source":"project:lib/a.dart","target":'
      '"project:lib/b.dart"},{"kind":"call","source":"project:lib/a.dart::Foo",'
      '"target":"project:lib/b.dart::Baz"}],"limitations":[],"nodes":[{"id":'
      '"project:lib/a.dart","isAbstract":false,"isTypeDeclaration":false,'
      '"sourceUri":"project:lib/a.dart","synthesized":false},{"id":'
      '"project:lib/a.dart::Foo","isAbstract":false,"isTypeDeclaration":true,'
      '"line":1,"sourceUri":"project:lib/a.dart","synthesized":false},{"id":'
      '"project:lib/b.dart","isAbstract":false,"isTypeDeclaration":false,'
      '"sourceUri":"project:lib/b.dart","synthesized":false},{"id":'
      '"project:lib/b.dart::Baz","isAbstract":false,"isTypeDeclaration":true,'
      '"sourceUri":"project:lib/b.dart","synthesized":false}]}\n',
    );
  });

  test('graph --collapse summarizes the file level into folders', () async {
    final output = StringBuffer();
    // 플래그 순서는 무관하다(--collapse가 --level보다 앞에 와도 같다).
    expect(
      await runDartograph(
        [
          'graph',
          '--format',
          'json',
          '--collapse',
          '1',
          '--level',
          'file',
          '.',
        ],
        output: output,
        indexPackage: (_) async => indexed(),
      ),
      ExitStatus.success.code,
    );
    // 같은 폴더로 접힌 라이브러리 사이 간선은 자기 순환이 되어 사라지고,
    // 폴더 집계 정점은 위치 필드를 갖지 않는다.
    expect(
      output.toString(),
      '{"edges":[],"limitations":[],"nodes":[{"id":"project:lib",'
      '"isAbstract":false,"isTypeDeclaration":false,"synthesized":false}]}\n',
    );
  });

  test('the default and explicit symbol level keep the full graph', () async {
    final implicit = StringBuffer();
    final explicit = StringBuffer();
    expect(
      await runDartograph(
        ['graph', '--format', 'json', '.'],
        output: implicit,
        indexPackage: (_) async => indexed(),
      ),
      ExitStatus.success.code,
    );
    expect(
      await runDartograph(
        ['graph', '--format', 'json', '--level', 'symbol', '.'],
        output: explicit,
        indexPackage: (_) async => indexed(),
      ),
      ExitStatus.success.code,
    );
    expect(implicit.toString(), explicit.toString());
    // 기본값 출력은 수준 도입 전과 동일하다(직렬화기 직행과 byte 동일).
    expect(implicit.toString(), GraphExporter.json(indexed().graph.snapshot()));
  });

  test('html renders the projected graph', () async {
    final output = StringBuffer();
    expect(
      await runDartograph(
        ['graph', '--format', 'html', '--level', 'file', '.'],
        output: output,
        indexPackage: (_) async => indexed(),
      ),
      ExitStatus.success.code,
    );
    const marker = '<script id="graph-data" type="application/json">';
    final begin = output.toString().indexOf(marker);
    final end = output.toString().indexOf('</script>', begin);
    final payload =
        jsonDecode(output.toString().substring(begin + marker.length, end))
            as Map<String, Object?>;
    expect(payload['nodes'], hasLength(2));
    expect(payload['edges'], hasLength(2));
  });

  test('graph level and collapse misuse are usage errors', () async {
    var calls = 0;
    final errors = StringBuffer();
    for (final invocation in [
      ['graph', '--format', 'json', '--level', 'module', '.'],
      ['graph', '--format', 'json', '--level', 'file', '--level', 'type', '.'],
      ['graph', '--format', 'json', '--level'],
      ['graph', '--format', 'json', '--collapse', '1', '.'],
      ['graph', '--format', 'json', '--level', 'type', '--collapse', '1', '.'],
      ['graph', '--format', 'json', '--level', 'file', '--collapse', '0', '.'],
      ['graph', '--format', 'json', '--level', 'file', '--collapse', 'x', '.'],
      ['graph', '--format', 'json', '--level', 'file', '--collapse'],
      ['graph', '--format', 'json', '--collapse', '1', '--collapse', '2', '.'],
    ]) {
      expect(
        await runDartograph(
          invocation,
          output: StringBuffer(),
          error: errors,
          indexPackage: (_) async {
            calls++;
            return indexed();
          },
        ),
        ExitStatus.usage.code,
        reason: invocation.join(' '),
      );
    }
    expect(calls, 0);
    expect(errors.toString(), contains('Unknown graph level: module'));
    expect(
      errors.toString(),
      contains('graph --collapse requires --level file.'),
    );
  });
}
