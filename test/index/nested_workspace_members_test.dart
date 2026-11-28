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
  /// [members]를 [declarer]가 선언한 중첩 멤버로 센 줄이다.
  String nestedLine(String members, String declarer) =>
      'workspace-members-not-indexed: $members are nested workspace members '
      'declared by $declarer; --workspace aggregates only the members listed '
      'in the root pubspec; run dartograph on each member root';

  final expected = nestedLine('pkgs/nest/empty, pkgs/nest/sub', 'pkgs/nest');

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

  group('globs and deeper nesting', () {
    late Directory root;

    void put(String relative, String content) {
      File(p.join(root.path, relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    /// 언어 버전 3.11(글롭 허용)의 워크스페이스 멤버 패키지다.
    void package(String path, String name, [String workspace = '']) {
      put(
        '$path/pubspec.yaml',
        'name: $name\npublish_to: none\nenvironment:\n  sdk: ^3.11.0\n'
            'resolution: workspace\n$workspace',
      );
      put('$path/lib/$name.dart', 'class ${name}Orphan {}\n');
    }

    setUp(() async {
      root = Directory(
        Directory.systemTemp
            .createTempSync('dartograph-nested-glob.')
            .resolveSymbolicLinksSync(),
      );
      put(
        'pubspec.yaml',
        'name: glob_root\npublish_to: none\nenvironment:\n  sdk: ^3.11.0\n'
            'workspace:\n  - pkgs/a\n  - pkgs/b\n  - pkgs/c\n  - pkgs/d\n'
            '  - pkgs/e\n',
      );
      // a: 첫 마디부터 글롭이라 글롭 앞 디렉터리가 멤버 자신이다(멤버 lib/ 파일과 무관하게 센다).
      package('pkgs/a', 'a', 'workspace:\n  - sub_*\n');
      package('pkgs/a/sub_x', 'sub_x');
      package('pkgs/a/sub_y', 'sub_y');
      // b: `*`는 q1과 이미 분석되는 b의 example/을 고른다. pubspec 없는 lib/은 고르지 않는다.
      package('pkgs/b', 'b', 'workspace:\n  - "*"\n');
      for (final name in ['q1', 'q2', 'q3', 'q4']) {
        package('pkgs/b/$name', name);
      }
      package('pkgs/b/example', 'b_example');
      // c: p1은 source_packages라 lib/가 분석되고 p2는 분석되지 않는다.
      package('pkgs/c', 'c', 'workspace:\n  - packages/*\n');
      package('pkgs/c/packages/p1', 'p1');
      package('pkgs/c/packages/p2', 'p2');
      // d: 선택지 글롭은 펼치지 않고 패턴으로 센다.
      package('pkgs/d', 'd', 'workspace:\n  - "{m1,m2}"\n');
      package('pkgs/d/m1', 'm1');
      package('pkgs/d/m2', 'm2');
      // e: 중첩 멤버 sub가 다시 deeper를 선언한다.
      package('pkgs/e', 'e', 'workspace:\n  - sub\n');
      package('pkgs/e/sub', 'sub', 'workspace:\n  - deeper\n');
      package('pkgs/e/sub/deeper', 'deeper');
      final pub = await Process.run(Platform.resolvedExecutable, const [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: root.path);
      expect(pub.exitCode, 0, reason: '${pub.stdout}${pub.stderr}');
      put('dartograph.yaml', 'source_packages:\n  - pkgs/c/packages/p1\n');
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('every unanalyzed nested member is named or counted', () async {
      final result = await AnalyzerGraphIndex(
        aggregateWorkspace: true,
        userCacheEnvironment: const {},
      ).index(root.path);

      expect(notIndexedOf(result)..sort(), [
        nestedLine('pkgs/a/sub_x, pkgs/a/sub_y', 'pkgs/a'),
        // 앞의 셋만 적고 나머지는 수로 센다.
        nestedLine('pkgs/b/q1, pkgs/b/q2, pkgs/b/q3 and 1 more', 'pkgs/b'),
        nestedLine('pkgs/c/packages/p2', 'pkgs/c'),
        'workspace-members-not-indexed: pkgs/d/{m1,m2} are workspace member '
            'globs declared by pkgs/d that dartograph does not expand; the '
            'packages they match are not aggregated as workspace members '
            '(their files are analyzed only when they lie in an analyzed '
            'source directory); run dartograph on each member root',
        nestedLine('pkgs/e/sub', 'pkgs/e'),
        nestedLine('pkgs/e/sub/deeper', 'pkgs/e/sub'),
      ]);
      // 줄의 근거: 센 패키지의 선언은 그래프에 없고, 세지 않은 것은 있다.
      final nodes = result.graph.nodes.keys.toSet();
      for (final name in [
        'sub_x',
        'sub_y',
        'q1',
        'q4',
        'p2',
        'm1',
        'sub',
        'deeper',
      ]) {
        expect(nodes.where((id) => id.startsWith('package:$name/')), isEmpty);
      }
      expect(
        nodes,
        contains('package:b_example/b_example.dart::b_exampleOrphan'),
      );
      expect(nodes, contains('package:p1/p1.dart::p1Orphan'));
    });
  });

  test(
    'globs without a match and nesting past the depth cap are counted',
    () async {
      // pub은 맞는 것이 없는 글롭을 거부하므로 package config을 손으로 쓴다.
      final root = Directory(
        Directory.systemTemp
            .createTempSync('dartograph-nested-depth.')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => root.deleteSync(recursive: true));
      void put(String relative, String content) {
        File(p.join(root.path, relative))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
      }

      String pubspec(String name, String workspace) =>
          'name: $name\npublish_to: none\nenvironment:\n  sdk: ^3.11.0\n'
          'resolution: workspace\nworkspace:\n$workspace';
      put(
        'pubspec.yaml',
        'name: depth_root\npublish_to: none\nenvironment:\n  sdk: ^3.11.0\n'
            'workspace:\n  - pkgs/n0\n',
      );
      put(
        '.dart_tool/package_config.json',
        '{"configVersion": 2, "packages": ['
            '{"name": "depth_root", "rootUri": "../", "packageUri": "lib/"},'
            '{"name": "n0", "rootUri": "../pkgs/n0", "packageUri": "lib/"}]}\n',
      );
      // n0은 사슬의 시작 n1, 맞는 것이 없는 글롭, 이름 그대로 맞는 `sub*`를 선언한다.
      put(
        'pkgs/n0/pubspec.yaml',
        pubspec('n0', '  - n1\n  - nothing_*\n  - sub*\n'),
      );
      put('pkgs/n0/lib/n0.dart', 'class N0 {}\n');
      put('pkgs/n0/sub/pubspec.yaml', 'name: sub\n');
      // n1부터 n33까지 각자 다음 단계를 선언하는 사슬이다.
      var path = 'pkgs/n0';
      for (var level = 1; level <= 33; level++) {
        path = '$path/n$level';
        put('$path/pubspec.yaml', pubspec('n$level', '  - n${level + 1}\n'));
      }

      final result = await AnalyzerGraphIndex(
        aggregateWorkspace: true,
        userCacheEnvironment: const {},
      ).index(root.path);

      final lines = notIndexedOf(result);
      expect(lines, contains(nestedLine('pkgs/n0/n1, pkgs/n0/sub', 'pkgs/n0')));
      expect(
        lines,
        contains(
          'workspace-members-not-indexed: pkgs/n0/nothing_* are workspace '
          'member globs declared by pkgs/n0 that dartograph does not expand; '
          'the packages they match are not aggregated as workspace members '
          '(their files are analyzed only when they lie in an analyzed source '
          'directory); run dartograph on each member root',
        ),
      );
      // n0(깊이 0)부터 n31(깊이 31)까지 32개 패키지의 항목을 펼친다. n32는 세지만
      // 그 pubspec은 따라가지 않으므로 그것이 선언한 n33을 따로 알린다.
      final n32 = [
        for (var level = 1; level <= 32; level++) 'n$level',
      ].join('/');
      expect(
        lines.where((line) => line.contains('are nested workspace members')),
        hasLength(32),
      );
      expect(
        lines,
        contains(
          'workspace-members-not-indexed: the workspace members declared by '
          'pkgs/n0/$n32 were not followed (nesting deeper than 32 levels); '
          'run dartograph on each member root',
        ),
      );
      expect(lines, hasLength(34));
    },
  );
}
