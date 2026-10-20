import 'dart:convert';
import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/markdown_fixture_support.dart';
import '../support/read_boundary_support.dart';

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

  test('impact --limit cuts the coverage list to the reported symbols and '
      'records the cut', () async {
    final changes = changedFile(['lib/a.dart']).path;
    Future<Map<String, Object?>> render(String limit) async {
      final output = StringBuffer();
      final status = await run([
        'impact',
        '--changed',
        changes,
        '--limit',
        limit,
        '--format',
        'json',
        directory.path,
      ], output: output);
      expect(status, 0, reason: 'limit $limit');
      return jsonDecode(output.toString()) as Map<String, Object?>;
    }

    // 영향 4개 중 1개만 보고하면 coverage 목록도 그 1개다. 개수는 전체로 남고
    // 잘린 수는 truncated와 limitation이 알린다.
    final limited = await render('1');
    final coverage = limited['coverage'] as Map<String, Object?>;
    expect(coverage['missedWithoutPrecheck'], ['project:lib/b.dart']);
    expect(coverage['transitivelyImpacted'], 4);
    expect((limited['impacted'] as List).map((item) => (item as Map)['id']), [
      'project:lib/b.dart',
    ]);
    expect(limited['truncated'], 3);
    expect(limited['limitations'], [
      'impact-coverage-truncated: --limit 1 omitted 3 of 4 impacted '
          'symbol(s) from coverage.missedWithoutPrecheck',
    ]);

    // limit이 영향 수와 같으면 자르지 않고 limitation도 없다.
    final whole = await render('4');
    expect((whole['coverage'] as Map)['missedWithoutPrecheck'], [
      'project:lib/b.dart',
      'project:lib/b.dart::Bar',
      'project:test/a_test.dart',
      'project:test/a_test.dart::main',
    ]);
    expect(whole['truncated'], 0);
    expect(whole['limitations'], isEmpty);
  });

  test(
    'impact --limit keeps the whole coverage count in text and markdown',
    () async {
      final changes = changedFile(['lib/a.dart']).path;
      Future<String> render(String format) async {
        final output = StringBuffer();
        final status = await run([
          'impact',
          '--changed',
          changes,
          '--limit',
          '1',
          '--format',
          format,
          directory.path,
        ], output: output);
        expect(status, 0, reason: format);
        return output.toString();
      }

      const cut =
          'impact-coverage-truncated: --limit 1 omitted 3 of 4 impacted '
          'symbol(s) from coverage.missedWithoutPrecheck';
      final text = await render('text');
      expect(
        text,
        contains(
          '\ncoverage: 4 impacted symbol(s) would be missed by inspecting '
          'changed files only\n',
        ),
      );
      expect(text, contains('\nlimitation: $cut\n'));
      final markdown = await render('markdown');
      expect(
        markdown,
        contains(
          '\n4 impacted symbol(s) would be missed by inspecting changed '
          'files only.\n',
        ),
      );
      expect(markdown, contains('\n- $cut\n'));
      final annotations = await render('github-actions');
      expect(
        annotations,
        contains('\n::notice title=dartograph limitation::$cut\n'),
      );
    },
  );

  test(
    'impact --limit sarif carries the cut coverage list and its limitation',
    () async {
      final output = StringBuffer();
      final status = await run([
        'impact',
        '--changed',
        changedFile(['lib/a.dart']).path,
        '--limit',
        '1',
        '--format',
        'sarif',
        directory.path,
      ], output: output);

      expect(status, 0);
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      final runDocument = (document['runs']! as List).single as Map;
      final invocation = (runDocument['invocations'] as List).single as Map;
      final properties = invocation['properties'] as Map;
      expect((properties['coverage'] as Map)['missedWithoutPrecheck'], [
        'project:lib/b.dart',
      ]);
      expect((properties['coverage'] as Map)['transitivelyImpacted'], 4);
      expect(properties['limitations'], [
        'impact-coverage-truncated: --limit 1 omitted 3 of 4 impacted '
            'symbol(s) from coverage.missedWithoutPrecheck',
      ]);
    },
  );

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

  test(
    'impact rejects a --changed device or FIFO by its cause as usage',
    () async {
      // 길이를 본 뒤 전체를 읽던 수정 전 코드는 /dev/zero 링크면 상한 없이 읽고
      // 쓰는 쪽이 없는 FIFO면 영구 대기했다. 여기서는 /dev/null과 쓰는 쪽이 붙은
      // FIFO라 수정 전 코드도 빈 내용을 읽고 'Invalid changed list'로 끝난다.
      final device = p.join(directory.path, 'device.json');
      await Link(device).create('/dev/null');
      final fifo = await fifoWithRepeatingWriter(
        p.join(directory.path, 'pipe.json'),
      );
      for (final path in [device, fifo]) {
        final error = StringBuffer();
        final status = await run([
          'impact',
          '--changed',
          path,
          directory.path,
        ], error: error);

        expect(status, 64, reason: path);
        // 사용자가 준 경로 문제다. 분석 입력 거부(종료 2)로 진단하지 않는다.
        expect(
          error.toString(),
          'Changed list must be a regular file (not a device, FIFO, or '
          'socket): $path\n',
        );
      }
    },
    skip: Platform.isWindows,
  );

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

  test('impact --format test-list prints only affected test paths', () async {
    final output = StringBuffer();
    expect(
      await run([
        'impact',
        '--changed',
        changedFile(['lib/a.dart']).path,
        '--format',
        'test-list',
        directory.path,
      ], output: output),
      0,
    );
    // lib/a.dart 변경 → test/a_test.dart가 전이 의존한다. 목록은 경로만
    // 한 줄에 하나씩 싣고 헤더·limitations를 붙이지 않는다.
    expect(output.toString(), 'test/a_test.dart\n');
  });

  test('impact --format test-list is not truncated by --limit', () async {
    // 영향받는 테스트가 2개인 그래프로 만든다 — 테스트가 1개뿐이면
    // --limit 1이 테스트 목록을 자르는 잘못된 구현도 같은 출력을 낸다.
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::Foo',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addNode(GraphNode(id: 'project:test/a_test.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:test/a_test.dart::main',
          sourceUri: 'project:test/a_test.dart',
        ),
      )
      ..addNode(GraphNode(id: 'project:test/b_test.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:test/b_test.dart::main',
          sourceUri: 'project:test/b_test.dart',
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:test/a_test.dart::main',
          targetId: 'project:lib/a.dart::Foo',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:test/b_test.dart::main',
          targetId: 'project:lib/a.dart::Foo',
          kind: EdgeKind.call,
        ),
      );
    final twoTests = AnalyzerGraphResult(graph: graph, limitations: const []);
    final output = StringBuffer();
    expect(
      await runDartograph(
        [
          'impact',
          '--changed',
          changedFile(['lib/a.dart']).path,
          '--format',
          'test-list',
          '--limit',
          '1',
          directory.path,
        ],
        output: output,
        indexPackage: (_) async => twoTests,
      ),
      0,
    );
    // --limit은 impacted 목록만 자르고 테스트 선택은 항상 전체다 — 두
    // 테스트가 모두 나와야 잘림 구현과 구분된다.
    expect(output.toString(), 'test/a_test.dart\ntest/b_test.dart\n');
  });

  test('impact --format test-list is empty when no test is affected', () async {
    final output = StringBuffer();
    expect(
      await run([
        'impact',
        '--changed',
        // 테스트 파일 자체를 바꾸면 의존하는 테스트가 없어 빈 출력이다 —
        // 소비자가 빈 출력으로 `dart test`를 실행하지 않게 가드해야 한다.
        changedFile(['test/a_test.dart']).path,
        '--format',
        'test-list',
        directory.path,
      ], output: output),
      0,
    );
    expect(output.toString(), isEmpty);
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

  test(
    'impact markdown keeps hostile paths inside intact code spans',
    () async {
      // 백틱이 든 파일명은 단일 백틱 span을 일찍 닫아 뒤의 링크·멘션을 Markdown으로
      // 살린다. 구분자를 내용의 가장 긴 백틱 run보다 길게 잡아야 원문이 span에 남고,
      // 저장소 유래 limitation은 링크·HTML·멘션을 열지 못하는 문구가 된다.
      const evil = 'project:lib/b`[x](https://evil.example) @victim.dart';
      const evilTest = 'project:test/c`@victim_test.dart';
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
        ..addNode(
          GraphNode(
            id: 'project:lib/a.dart::Foo',
            sourceUri: 'project:lib/a.dart',
          ),
        )
        ..addNode(GraphNode(id: evil, isLibrary: true))
        ..addNode(
          GraphNode(id: '$evil::Bar', sourceUri: evil, line: 3, column: 5),
        )
        ..addNode(GraphNode(id: evilTest, isLibrary: true))
        ..addNode(GraphNode(id: '$evilTest::main', sourceUri: evilTest))
        ..addEdge(
          const GraphEdge(
            sourceId: '$evil::Bar',
            targetId: 'project:lib/a.dart::Foo',
            kind: EdgeKind.call,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: '$evilTest::main',
            targetId: '$evil::Bar',
            kind: EdgeKind.call,
          ),
        );
      final hostileIndex = AnalyzerGraphResult(
        graph: graph,
        limitations: const [],
        limitationDetails: const [hostileMarkdownText],
      );
      Future<(int, String)> render(String symbol) async {
        final output = StringBuffer();
        final status = await runDartograph(
          [
            'impact',
            '--symbol',
            symbol,
            '--format',
            'markdown',
            directory.path,
          ],
          output: output,
          error: StringBuffer(),
          indexPackage: (_) async => hostileIndex,
        );
        return (status, output.toString());
      }

      final (status, markdown) = await render('project:lib/a.dart::Foo');
      expect(status, 0);
      const bar = 'project:lib/b`[x](https://evil.example) @victim.dart::Bar';
      expect(markdown, contains('| ``$bar`` | declaration |'));
      expect(
        markdown,
        contains('| ``lib/b`[x](https://evil.example) @victim.dart:3`` |'),
      );
      expect(
        markdown,
        contains('|  |  |  | ``$bar → project:lib/a.dart::Foo`` |'),
      );
      expect(markdown, contains('\n- ``test/c`@victim_test.dart`` (depth 2)'));
      expect(
        markdown,
        contains(
          '\n- ``$bar`` → `project:lib/a.dart::Foo` (call) at '
          '``lib/b`[x](https://evil.example) @victim.dart:3:5``\n',
        ),
      );
      expect(markdown, contains('\n- $escapedMarkdownText\n'));

      final (missingStatus, missing) = await render('project:lib/a.dart::G`x');
      expect(missingStatus, 64);
      expect(
        missing,
        contains(
          'Requested symbols absent from the graph: '
          '``project:lib/a.dart::G`x``\n',
        ),
      );
    },
  );
}
