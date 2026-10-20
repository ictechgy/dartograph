import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/bridge_index.dart';
import 'package:dartograph/src/index/incremental_cache.dart';
import 'package:dartograph/src/index/project_files.dart';
import 'package:dartograph/src/index/route_call_index.dart';
import 'package:dartograph/src/index/schema_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 같은 디렉터리로 가는 심볼릭 링크 경로를 한 번만 여는 열거 규칙의 회귀 테스트다.
///
/// 기대값은 픽스처 구조에서 손으로 센 값이다. 공유 링크 트리(DAG)는 `lib/d0..dN`의
/// 각 단계가 파일 하나와 다음 단계를 가리키는 링크 `a`·`b`를 둔다. 이름순 순회에서
/// `lib/d0`의 `a` 사슬이 모든 단계를 먼저 연다. 그래서 남는 경로는 실제 위치
/// `lib/d{i}/f{i}.dart`(N+1개)와 링크 경로 `lib/d0/a/…/f{i}.dart`(N개)다. 건너뛰는
/// 경로는 사슬의 `b` N개와 실제 `lib/d1..d{N-1}`의 `a`·`b` 2(N-1)개, 모두 3N-2개다.
void main() {
  late Directory workspace;
  var fixtures = 0;

  setUp(() async {
    final created = await Directory.systemTemp.createTemp(
      'dartograph-linked-directories.',
    );
    // macOS의 /var → /private/var 같은 조상 링크를 풀어 경로 비교를 단순하게 한다.
    workspace = Directory(created.resolveSymbolicLinksSync());
  });
  tearDown(() => workspace.delete(recursive: true));

  /// pubspec과 [files]만 둔 패키지 루트다. 값이 `-> `로 시작하면 그 대상의 링크다.
  Future<String> package(Map<String, String> files) async {
    final root = p.join(workspace.path, 'package-${fixtures++}');
    final entries = {
      'pubspec.yaml': 'name: linked\nenvironment:\n  sdk: ^3.11.0\n',
      ...files,
    };
    for (final MapEntry(key: path, value: content) in entries.entries) {
      final target = p.join(root, path);
      await Directory(p.dirname(target)).create(recursive: true);
      if (content.startsWith('-> ')) {
        await Link(target).create(content.substring(3));
      } else {
        await File(target).writeAsString(content);
      }
    }
    return root;
  }

  /// 깊이 [depth]의 공유 링크 트리다(재현 도구 dag_make.sh와 같은 모양).
  Future<String> dagPackage(int depth) => package({
    'lib/dag.dart': 'void main() {}\n',
    for (var i = 0; i <= depth; i++) 'lib/d$i/f$i.dart': 'class C$i {}\n',
    for (var i = 0; i < depth; i++) ...{
      'lib/d$i/a': '-> ../d${i + 1}',
      'lib/d$i/b': '-> ../d${i + 1}',
    },
  });

  /// [dagPackage]에서 남아야 하는 라이브러리 ID다.
  Set<String> dagLibraries(int depth) => {
    'project:lib/dag.dart',
    for (var i = 0; i <= depth; i++) 'project:lib/d$i/f$i.dart',
    for (var i = 1; i <= depth; i++) 'project:lib/d0/${'a/' * i}f$i.dart',
  };

  Set<String> libraries(AnalyzerGraphResult result) => {
    for (final node in result.graph.nodes.values)
      if (node.isLibrary) node.id,
  };

  /// [limitations]가 알린 건너뛴 링크 경로 수다. 그 limitation이 없으면 0이다.
  int skippedCount(Iterable<String> limitations) {
    final counts = [
      for (final limitation in limitations)
        if (RegExp(
              r'^symlink-duplicate-directories: (\d+) ',
            ).firstMatch(limitation)
            case final match?)
          int.parse(match[1]!),
    ];
    expect(counts.length, lessThanOrEqualTo(1), reason: '$limitations');
    return counts.isEmpty ? 0 : counts.single;
  }

  Future<AnalyzerGraphResult> index(String root) =>
      AnalyzerGraphIndex(cache: _ColdCache()).index(root);

  /// [root]에서 [indexProjectFiles]가 내는 `.dart` 파일의 루트 상대 경로다.
  List<String> projectDartFiles(String root, LinkedDirectoryVisits visits) => [
    for (final file in indexProjectFiles(
      Directory(root),
      linkedDirectories: visits,
    ))
      if (file.path.endsWith('.dart'))
        p.posix.joinAll(p.split(p.relative(file.path, from: root))),
  ];

  group('analysis units', () {
    test(
      'a shared-link tree keeps one link path per directory and counts the rest',
      () async {
        final root = await dagPackage(4);

        final result = await index(root);

        expect(libraries(result), dagLibraries(4));
        expect(skippedCount(result.limitationDetails), 3 * 4 - 2);
      },
    );

    test('a depth-16 shared-link tree is enumerated in linear time', () async {
      // 수정 전에는 2^17개 가까운 경로를 분석 단위로 열거해 수 분이 걸렸다(기본
      // timeout 30초를 넘긴다). 수정 뒤에는 이 머신에서 몇 초 안이다.
      final root = await dagPackage(16);
      final stopwatch = Stopwatch()..start();

      final result = await index(root);

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 20)));
      expect(libraries(result), dagLibraries(16));
      expect(skippedCount(result.limitationDetails), 3 * 16 - 2);
    });

    test('the incremental path reports the same units and count', () async {
      final root = await dagPackage(4);

      final result = await AnalyzerGraphIndex(
        incremental: IncrementalCache('$root.facts'),
      ).index(root);

      expect(libraries(result), dagLibraries(4));
      expect(skippedCount(result.limitationDetails), 3 * 4 - 2);
    });

    test('links that only form cycles add no limitation', () async {
      final root = await package({
        'lib/main.dart': 'void main() {}\n',
        'lib/src/a.dart': 'class A {}\n',
        'lib/src/self': '-> .',
        'lib/src/up': '-> ..',
      });

      final result = await index(root);

      expect(libraries(result), {
        'project:lib/main.dart',
        'project:lib/src/a.dart',
      });
      expect(skippedCount(result.limitationDetails), 0);
    });

    test(
      'later links to the same directory are skipped by name order',
      () async {
        // 형제 링크를 여럿 두어, 목록 순서(파일 시스템마다 다르다)를 그대로 쓰면 남는
        // 경로가 이름순 첫 경로와 어긋나게 한다(APFS는 이 이름들을 f부터 돌려준다).
        final root = await package({
          'lib/main.dart': 'void main() {}\n',
          'shared/s.dart': 'class S {}\n',
          for (final name in const ['m', 'f', 'x', 'c', 'q'])
            'lib/$name': '-> ../shared',
        });

        final result = await index(root);

        expect(libraries(result), {
          'project:lib/main.dart',
          'project:lib/c/s.dart',
        });
        expect(skippedCount(result.limitationDetails), 4);
      },
    );

    test('a real directory and one link to it are both analyzed', () async {
      final root = await package({
        'lib/src/x.dart': 'class X {}\n',
        'lib/src/inner/y.dart': 'class Y {}\n',
        'lib/alias': '-> src',
      });

      final result = await index(root);

      expect(libraries(result), {
        'project:lib/alias/inner/y.dart',
        'project:lib/alias/x.dart',
        'project:lib/src/inner/y.dart',
        'project:lib/src/x.dart',
      });
      expect(skippedCount(result.limitationDetails), 0);
    });

    test('a link into an already linked directory is skipped', () async {
      // lib/a가 shared 전체를, lib/b가 그 하위 sub를 가리킨다. sub는 lib/a/sub로 이미
      // 열렸다. 링크 대상만 세면 lib/b도 열려 같은 파일이 두 경로로 분석된다.
      final root = await package({
        'shared/sub/y.dart': 'class Y {}\n',
        'lib/a': '-> ../shared',
        'lib/b': '-> ../shared/sub',
      });

      final result = await index(root);

      expect(libraries(result), {'project:lib/a/sub/y.dart'});
      expect(skippedCount(result.limitationDetails), 1);
    });

    test('a link outside the analyzed directories does not take the place of '
        'one inside', () async {
      // aaa/는 분석 범위 밖이라 그 아래로 내려가지 않는다. 내려가면 이름순으로 먼저인
      // aaa/x가 shared를 차지해 lib/x의 소스가 그래프에서 빠진다.
      final root = await package({
        'shared/s.dart': 'class S {}\n',
        'aaa/x': '-> ../shared',
        'lib/x': '-> ../shared',
      });

      final result = await index(root);

      expect(libraries(result), {'project:lib/x/s.dart'});
      expect(skippedCount(result.limitationDetails), 0);
    });

    test('resolved units share the rule and report the count', () async {
      final root = await package({
        'shared/s.dart': 'class S {}\n',
        'lib/a': '-> ../shared',
        'lib/b': '-> ../shared',
      });
      final visits = LinkedDirectoryVisits();

      final units = await resolveProjectUnits(root, linkedDirectories: visits);

      expect(
        [for (final unit in units) p.relative(unit.path, from: root)],
        [p.join('lib', 'a', 's.dart')],
      );
      expect(visits.skipped, hasLength(1));
      expect(visits.skipped.single.path, p.join(root, 'lib', 'b'));
    });
  });

  group('project file enumeration', () {
    test(
      'a shared-link tree yields each directory once per path kind',
      () async {
        final root = await dagPackage(16);
        final visits = LinkedDirectoryVisits();

        final files = projectDartFiles(root, visits);

        expect(files.toSet(), {
          for (final id in dagLibraries(16)) id.substring('project:'.length),
        });
        expect(files, hasLength(files.toSet().length));
        expect(visits.skipped, hasLength(3 * 16 - 2));
      },
    );

    test('a real chain with a link to each depth stays linear', () async {
      // 링크 대상만 한 번씩 세면 lib/l{i}마다 그 아래 실제 사슬을 다시 열어 경로가
      // 링크 수의 제곱으로 는다(여기서는 8+7+…+1 = 36개).
      const depth = 8;
      final chain = [for (var i = 1; i <= depth; i++) 'n$i'];
      final root = await package({
        for (var i = 1; i <= depth; i++)
          'lib/chain/${chain.take(i).join('/')}/f.dart': 'class F$i {}\n',
        for (var i = 1; i <= depth; i++)
          'lib/l$i': '-> chain/${chain.take(i).join('/')}',
      });
      final visits = LinkedDirectoryVisits();

      final files = projectDartFiles(root, visits);

      expect(files, [
        for (var i = 1; i <= depth; i++)
          'lib/chain/${chain.take(i).join('/')}/f.dart',
        for (var i = 1; i <= depth; i++)
          'lib/l1/${chain.skip(1).take(i - 1).followedBy(['f.dart']).join('/')}',
      ]);
      expect(visits.skipped, hasLength(depth - 1));
    });

    test('cycles are not entered and not counted', () async {
      final root = await package({
        'lib/a.dart': 'class A {}\n',
        'shared/s.dart': 'class S {}\n',
        'shared/self': '-> .',
        'lib/linked': '-> ../shared',
      });
      final visits = LinkedDirectoryVisits();

      final files = projectDartFiles(root, visits);

      expect(files, ['lib/a.dart', 'lib/linked/s.dart', 'shared/s.dart']);
      expect(visits.skipped, isEmpty);
    });

    test('a start below a symlinked ancestor keeps real locations', () async {
      // 시작 경로가 정규 경로가 아니어도(macOS의 /var 등) 링크를 거치지 않은 실제
      // 디렉터리는 링크 경로로 다루지 않는다.
      final root = await package({
        'lib/src/x.dart': 'class X {}\n',
        'lib/alias': '-> src',
      });
      final entry = p.join(workspace.path, 'entry');
      await Link(entry).create(root);
      final visits = LinkedDirectoryVisits();

      final files = [
        for (final file in indexProjectFiles(
          Directory(entry),
          linkedDirectories: visits,
        ))
          if (file.path.endsWith('.dart'))
            p.posix.joinAll(p.split(p.relative(file.path, from: entry))),
      ];

      expect(files, ['lib/alias/x.dart', 'lib/src/x.dart']);
      expect(visits.skipped, isEmpty);
    });
  });

  group('other producers', () {
    late String root;

    setUp(() async {
      root = await package({
        'shared/s.dart': 'class S {}\n',
        'lib/a': '-> ../shared',
        'lib/b': '-> ../shared',
        'lib/main.dart': 'void main() {}\n',
      });
    });

    test('bridges reports the skipped link path', () {
      expect(skippedCount(indexBridges(root).limitations), 1);
    });

    test('schema reports the skipped link path', () async {
      expect(skippedCount((await indexSchema(root)).limitations), 1);
    });

    test('routes reports the skipped link path', () async {
      expect(skippedCount((await indexRouteCalls(root)).limitations), 1);
    });
  });
}

/// 항상 miss인 캐시 — OS 사용자 캐시를 쓰지 않고 전체 해석 경로를 탄다.
final class _ColdCache implements FactCache {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String payload) async {}
}
