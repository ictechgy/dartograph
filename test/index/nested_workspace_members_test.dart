import 'dart:io';

import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/incremental_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `--workspace`가 집계하지 않은 중첩 워크스페이스 멤버를 실제 analyzer 색인이
/// `workspace-members-not-indexed:` 한계로 세는지 고정한다.
///
/// pub은 멤버 pubspec의 `workspace:`가 선언한 패키지도 같은 해석에 넣는다(아래
/// fixture는 `dart pub get --offline`이 받아들인다). 집계는 루트 목록만 따르므로
/// 이전에는 그 멤버의 소스가 빠진 결과가 한계 없이 "발견 없음"으로 끝났다.
void main() {
  late Directory workspace;

  void write(String relative, String content) {
    File(p.join(workspace.path, relative))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  /// 루트 목록에 없는 멤버 pubspec이다(`resolution: workspace`).
  void member(String path, String name, [String extra = '']) {
    write('$path/pubspec.yaml', '''
name: $name
publish_to: none
environment:
  sdk: ^3.6.0
resolution: workspace
$extra''');
    write('$path/lib/$name.dart', 'void ${name}Api() {}\n');
    write('$path/lib/orphan.dart', 'class ${name}Orphan {}\n');
  }

  setUp(() async {
    workspace = Directory(
      Directory.systemTemp
          .createTempSync('dartograph-nested-workspace.')
          .resolveSymbolicLinksSync(),
    );
    // 루트는 pkgs/nest와, pkgs/nest/sub 안쪽의 pkgs/nest/sub/inner만 나열한다.
    write('pubspec.yaml', '''
name: ws_root
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - pkgs/nest
  - pkgs/nest/sub/inner
''');
    write('lib/ws_root.dart', 'void rootApi() {}\n');
    // pkgs/nest는 자기 표준 소스 디렉터리 안의 example과 그 밖의 sub·empty를
    // 중첩 멤버로 선언한다. empty에는 Dart 파일이 없다.
    member('pkgs/nest', 'nest', '''
workspace:
  - sub
  - example
  - empty
''');
    member('pkgs/nest/example', 'nest_example');
    member('pkgs/nest/sub', 'sub');
    member('pkgs/nest/sub/inner', 'inner');
    write('pkgs/nest/empty/pubspec.yaml', '''
name: empty
publish_to: none
environment:
  sdk: ^3.6.0
resolution: workspace
''');
    final pub = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: workspace.path);
    expect(pub.exitCode, 0, reason: '${pub.stdout}${pub.stderr}');
  });
  tearDown(() => workspace.deleteSync(recursive: true));

  List<String> notIndexedOf(AnalyzerGraphResult result) => [
    for (final detail in result.limitationDetails)
      if (detail.startsWith('workspace-members-not-indexed:')) detail,
  ];

  // example은 pkgs/nest의 example/ 디렉터리로 이미 분석돼 세지 않는다. sub는 더
  // 안쪽 집계 멤버(inner)의 파일만 담고 있어 센다. empty는 파일이 없어 센다.
  const expected =
      'workspace-members-not-indexed: pkgs/nest/empty, pkgs/nest/sub are '
      'nested workspace members declared by pkgs/nest; --workspace aggregates '
      'only the members listed in the root pubspec; run dartograph --workspace '
      'on pkgs/nest to analyze them';

  test('nested members outside the analysis scope are reported', () async {
    final result = await AnalyzerGraphIndex(
      aggregateWorkspace: true,
      userCacheEnvironment: const {},
    ).index(workspace.path);

    expect(notIndexedOf(result), [expected]);
    final nodes = result.graph.nodes.keys.toSet();
    // 한계의 근거: sub의 선언은 그래프에 없고, example·inner의 선언은 있다.
    expect(nodes.where((id) => id.startsWith('package:sub/')), isEmpty);
    expect(
      nodes,
      contains('package:nest_example/orphan.dart::nest_exampleOrphan'),
    );
    expect(nodes, contains('package:inner/orphan.dart::innerOrphan'));
  });

  test('without --workspace the root line is unchanged', () async {
    final result = await AnalyzerGraphIndex(
      userCacheEnvironment: const {},
    ).index(workspace.path);

    expect(notIndexedOf(result), [
      'workspace-members-not-indexed: pkgs/nest, pkgs/nest/sub/inner are '
          'separate workspace packages; run dartograph on each member root',
    ]);
  });

  test(
    'aggregating the declaring member analyzes the nested members',
    () async {
      final result = await AnalyzerGraphIndex(
        aggregateWorkspace: true,
        userCacheEnvironment: const {},
      ).index(p.join(workspace.path, 'pkgs', 'nest'));

      // pkgs/nest를 루트로 집계하면 sub·example·empty가 멤버가 되어 줄이 없다.
      expect(notIndexedOf(result), isEmpty);
      expect(
        result.graph.nodes.keys,
        contains('package:sub/orphan.dart::subOrphan'),
      );
    },
  );

  test('the incremental path reports the same line', () async {
    final facts = Directory(p.join(workspace.path, '.facts'));
    Future<AnalyzerGraphResult> incremental() => AnalyzerGraphIndex(
      aggregateWorkspace: true,
      incremental: IncrementalCache(facts.path),
    ).index(workspace.path);

    final first = await incremental();
    final reused = await incremental();

    expect(notIndexedOf(first), [expected]);
    expect(notIndexedOf(reused), [expected]);
  });
}
