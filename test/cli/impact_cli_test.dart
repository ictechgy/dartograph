import 'dart:convert';
import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String canonicalRoot;
  late AnalyzerGraphResult indexed;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('impact-cli.');
    canonicalRoot = await directory.resolveSymbolicLinks();
    for (final relative in const [
      'lib/a.dart',
      'lib/b.dart',
      'test/a_test.dart',
    ]) {
      final file = File(p.join(directory.path, relative))
        ..createSync(recursive: true);
      file.writeAsStringSync('// $relative\n');
    }
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::Foo',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addNode(GraphNode(id: 'project:lib/b.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:lib/b.dart::Bar',
          sourceUri: 'project:lib/b.dart',
        ),
      )
      ..addNode(GraphNode(id: 'project:test/a_test.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:test/a_test.dart::main',
          sourceUri: 'project:test/a_test.dart',
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/b.dart',
          targetId: 'project:lib/a.dart',
          kind: EdgeKind.import,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/b.dart::Bar',
          targetId: 'project:lib/a.dart::Foo',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:test/a_test.dart',
          targetId: 'project:lib/b.dart',
          kind: EdgeKind.import,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:test/a_test.dart::main',
          targetId: 'project:lib/b.dart::Bar',
          kind: EdgeKind.call,
        ),
      );
    indexed = AnalyzerGraphResult(graph: graph, limitations: const []);
  });

  tearDown(() => directory.delete(recursive: true));

  Future<int> run(
    List<String> arguments, {
    StringBuffer? output,
    StringBuffer? error,
  }) => runDartograph(
    arguments,
    output: output ?? StringBuffer(),
    error: error ?? StringBuffer(),
    indexPackage: (_) async => indexed,
    changedFilesSince: (reference, root) async {
      return {p.normalize(p.join(canonicalRoot, 'lib/a.dart'))};
    },
  );

  File changedFile(List<String> entries) {
    final file = File(p.join(directory.path, 'changes.json'));
    file.writeAsStringSync(jsonEncode(entries));
    return file;
  }

  test('impact --changed answers the impact document and exits 0', () async {
    final output = StringBuffer();
    final status = await run([
      'impact',
      '--changed',
      changedFile(['lib/a.dart']).path,
      '--format',
      'json',
      directory.path,
    ], output: output);

    expect(status, 0);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    expect(document['version'], 1);
    expect(document['truncated'], 0);
    expect(document['changed'], {
      'libraries': ['project:lib/a.dart'],
      'sources': ['lib/a.dart'],
      'symbols': ['project:lib/a.dart::Foo'],
      'unattributedSources': <Object?>[],
    });
    final coverage = document['coverage'] as Map<String, Object?>;
    expect(coverage['directlyChangedSymbols'], 1);
    expect(coverage['transitivelyImpacted'], 4);
    expect((coverage['missedWithoutPrecheck'] as List).length, 4);
    final impacted = (document['impacted'] as List)
        .cast<Map<String, Object?>>();
    expect(impacted.first['depth'], 1);
    final callSites = (document['callSites'] as List)
        .cast<Map<String, Object?>>();
    expect(callSites.single['to'], 'project:lib/a.dart::Foo');
    expect(callSites.single['from'], 'project:lib/b.dart::Bar');
    expect((document['risk'] as Map)['level'], 'low');
  });

  test('impact --symbol resolves a known id and reports known:true', () async {
    final output = StringBuffer();
    final status = await run([
      'impact',
      '--symbol',
      'project:lib/a.dart::Foo',
      '--format',
      'json',
      directory.path,
    ], output: output);

    expect(status, 0);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    expect(document['explain'], 'impact');
    expect(document['id'], 'project:lib/a.dart::Foo');
    expect(document['known'], isTrue);
  });

  test(
    'impact --symbol reports known:false and exits 64 for an absent id',
    () async {
      final output = StringBuffer();
      final status = await run([
        'impact',
        '--symbol',
        'project:lib/a.dart::Ghost',
        '--format',
        'json',
        directory.path,
      ], output: output);

      expect(status, 64);
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(document['known'], isFalse);
      expect(document['missingSymbols'], ['project:lib/a.dart::Ghost']);
    },
  );

  test('impact --since reports the changed seed from git', () async {
    final output = StringBuffer();
    final status = await run([
      'impact',
      '--since',
      'origin/main',
      '--format',
      'json',
      directory.path,
    ], output: output);

    expect(status, 0);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    expect((document['changed'] as Map)['sources'], ['lib/a.dart']);
  });

  test('impact --fail-on turns a risk level into exit 1', () async {
    final changes = changedFile(['lib/a.dart']).path;
    expect(
      await run([
        'impact',
        '--changed',
        changes,
        '--fail-on',
        'low',
        directory.path,
      ]),
      1,
    );
    expect(
      await run([
        'impact',
        '--changed',
        changes,
        '--fail-on',
        'high',
        directory.path,
      ]),
      0,
    );
    expect(await run(['impact', '--changed', changes, directory.path]), 0);
  });

  test('impact misuse is a usage error', () async {
    final changes = changedFile(['lib/a.dart']).path;
    final cases = <List<String>>[
      // 씨앗 입력 없음
      ['impact', directory.path],
      // 씨앗 입력 두 개
      [
        'impact',
        '--since',
        'HEAD',
        '--symbol',
        'lib/a.dart::Foo',
        directory.path,
      ],
      // 알 수 없는 형식
      ['impact', '--since', 'HEAD', '--format', 'xml', directory.path],
      // 중복 플래그
      ['impact', '--since', 'A', '--since', 'B', directory.path],
      // 잘못된 깊이
      ['impact', '--since', 'HEAD', '--depth', '0', directory.path],
      // 알 수 없는 fail-on
      ['impact', '--since', 'HEAD', '--fail-on', 'sometimes', directory.path],
      // 패키지 루트 없음
      ['impact', '--changed', changes],
    ];
    for (final arguments in cases) {
      final error = StringBuffer();
      expect(await run(arguments, error: error), 64, reason: '$arguments');
    }
  });

  test('impact reports an invalid --changed file as usage', () async {
    final invalid = File(p.join(directory.path, 'bad.json'))
      ..writeAsStringSync('{"not": "a list"}');
    final error = StringBuffer();
    final status = await run([
      'impact',
      '--changed',
      invalid.path,
      directory.path,
    ], error: error);

    expect(status, 64);
    expect(error.toString(), contains('Invalid changed list'));
  });

  test('impact reports an unreadable --changed file as usage', () async {
    // 없는 입력 경로는 분석 실패(2)가 아니라 잘못된 사용(64)이다.
    final missing = p.join(directory.path, 'does-not-exist.json');
    final error = StringBuffer();
    final status = await run([
      'impact',
      '--changed',
      missing,
      directory.path,
    ], error: error);

    expect(status, 64);
    expect(error.toString(), contains('Changed list could not be read'));
    expect(error.toString(), contains(missing));
  });

  test('impact renders text, markdown, and sarif losslessly', () async {
    final changes = changedFile(['lib/a.dart']).path;
    final text = StringBuffer();
    expect(
      await run([
        'impact',
        '--changed',
        changes,
        '--format',
        'text',
        directory.path,
      ], output: text),
      0,
    );
    expect(text.toString(), contains('risk: low'));
    expect(text.toString(), contains('project:lib/b.dart::Bar'));

    final markdown = StringBuffer();
    expect(
      await run([
        'impact',
        '--changed',
        changes,
        '--format',
        'markdown',
        directory.path,
      ], output: markdown),
      0,
    );
    expect(markdown.toString(), startsWith('# dartograph impact report'));
    expect(markdown.toString(), contains('## Precheck coverage'));

    final sarif = StringBuffer();
    expect(
      await run([
        'impact',
        '--changed',
        changes,
        '--format',
        'sarif',
        directory.path,
      ], output: sarif),
      0,
    );
    final document = jsonDecode(sarif.toString()) as Map<String, Object?>;
    expect(document['version'], '2.1.0');
    expect((document['runs'] as List).single, isA<Map>());
  });

  test('sarif results carry a repository-relative physical location', () async {
    final changes = changedFile(['lib/a.dart']).path;
    final sarif = StringBuffer();
    expect(
      await run([
        'impact',
        '--changed',
        changes,
        '--format',
        'sarif',
        directory.path,
      ], output: sarif),
      0,
    );
    final document = jsonDecode(sarif.toString()) as Map<String, Object?>;
    final runDocument = (document['runs']! as List).single as Map;
    final results = runDocument['results'] as List;
    expect(results, isNotEmpty);
    for (final result in results) {
      final location = ((result as Map)['locations'] as List).single as Map;
      final uri =
          ((location['physicalLocation'] as Map)['artifactLocation']
                  as Map)['uri']
              as String;
      // GitHub code scanning은 package: URI나 절대 경로를 거부한다.
      expect(uri, isNot(contains('://')));
      expect(uri, isNot(startsWith('package:')));
      expect(uri, isNot(startsWith('/')));
    }
  });

  test('impact output is byte-identical across runs', () async {
    final changes = changedFile(['lib/a.dart']).path;
    Future<String> render() async {
      final output = StringBuffer();
      await run([
        'impact',
        '--changed',
        changes,
        '--format',
        'json',
        directory.path,
      ], output: output);
      return output.toString();
    }

    expect(await render(), await render());
  });
}
