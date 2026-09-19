import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/dependency_tools.dart';
import 'package:dartograph/src/index/incremental_cache.dart';
import 'package:test/test.dart';

void main() {
  test(
    'workspace member indexes its own sources and resolves sibling imports',
    () async {
      final workspace = await _makeWorkspace();
      addTearDown(() => workspace.delete(recursive: true));
      final member = Directory('${workspace.path}/pkgs/pkg_b');

      final result = await AnalyzerGraphIndex().index(member.path);
      // 멤버 스캔은 멤버 패키지만 분석한다 — 형제 패키지는 package: 의존이지
      // project: 소스가 아니다(단일 패키지 계약 유지).
      expect(result.graph.nodes.keys, contains('package:pkg_b/b.dart::main'));
      expect(
        result.graph.nodes.keys,
        isNot(contains('package:pkg_a/a.dart::Foo')),
      );
      expect(
        result.limitationDetails.where(
          (detail) => detail.startsWith('workspace-members-not-indexed:'),
        ),
        isEmpty,
      );
      // 형제 멤버를 import한 지시문은 선언된 URI 기준으로 deps 감사 입력에 남는다.
      expect(result.packageImports['pkg_a'], isNotEmpty);
    },
  );

  test(
    'workspace root scan reports unindexed member packages as a limitation',
    () async {
      final workspace = await _makeWorkspace();
      addTearDown(() => workspace.delete(recursive: true));

      final result = await AnalyzerGraphIndex().index(workspace.path);
      // 루트 자체의 소스는 분석되지만 멤버 패키지는 분석 대상 디렉터리 밖이다 —
      // 빈 결과가 "소스 없음"과 구분되도록 선언된 멤버가 limitation에 남는다.
      expect(result.graph.nodes.keys, contains('package:ws_root/root.dart'));
      final detail = result.limitationDetails.singleWhere(
        (entry) => entry.startsWith('workspace-members-not-indexed:'),
      );
      expect(detail, contains('pkgs/pkg_a'));
      expect(detail, contains('pkgs/pkg_b'));
    },
  );

  test(
    'incremental runs report the same workspace limitation as a full scan',
    () async {
      final workspace = await _makeWorkspace();
      addTearDown(() => workspace.delete(recursive: true));
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'dartograph-incr.',
      );
      addTearDown(() => cacheDirectory.delete(recursive: true));
      final index = AnalyzerGraphIndex(
        incremental: IncrementalCache(cacheDirectory.path),
      );

      // 첫 실행으로 증분 상태를 채운 뒤 파일을 바꿔 두 번째 실행이 캐시된
      // 결과를 통째로 재사용하지 못하고 증분 재분석을 하게 만든다.
      // limitation은 분석 경로가 아니라 결과 조립에서 나오므로 양쪽이 같아야 한다.
      final first = await index.index(workspace.path);
      await File(
        '${workspace.path}/lib/root.dart',
      ).writeAsString('class RootPackage { int field = 1; }\n');
      final second = await index.index(workspace.path);
      for (final result in [first, second]) {
        expect(
          result.limitationDetails.where(
            (detail) => detail.startsWith('workspace-members-not-indexed:'),
          ),
          isNotEmpty,
        );
      }
      expect(second.limitationDetails, first.limitationDetails);
    },
  );

  test(
    'member dependency tool detection uses the ancestor package_config',
    () async {
      final workspace = await _makeWorkspace();
      addTearDown(() => workspace.delete(recursive: true));
      final member = Directory('${workspace.path}/pkgs/pkg_b');

      final detected = detectToolLikeDependencies(member.path, {'pkg_a'});
      // 멤버는 자체 .dart_tool/package_config.json이 없어도 루트의 설정으로
      // 의존성 루트를 확인한다 — 잘못된 missing 보고가 없어야 한다.
      expect(
        detected.limitations.where(
          (entry) => entry.startsWith('package-config-missing:'),
        ),
        isEmpty,
      );
    },
  );

  group('workspace aggregation (--workspace)', () {
    test('member sources join one graph with cross-member edges', () async {
      final workspace = await _makeWorkspace();
      addTearDown(() => workspace.delete(recursive: true));

      final result = await AnalyzerGraphIndex(
        aggregateWorkspace: true,
      ).index(workspace.path);

      // 루트 + 두 멤버의 선언이 한 그래프에 있다 — 소스 ID는 루트 기준
      // project: 경로이고 라이브러리 ID는 package: 정규 URI다.
      expect(result.graph.nodes.keys, contains('package:ws_root/root.dart'));
      expect(result.graph.nodes.keys, contains('package:pkg_a/a.dart::Foo'));
      expect(result.graph.nodes.keys, contains('package:pkg_b/b.dart::main'));
      expect(
        result.graph.nodes.values.any(
          (node) => node.sourceUri == 'project:pkgs/pkg_a/lib/a.dart',
        ),
        isTrue,
      );
      // 멤버 간 package: 간선은 analyzer 정규 URI로 그대로 연결된다.
      expect(
        result.graph.edges.any(
          (edge) =>
              edge.sourceId == 'package:pkg_b/b.dart' &&
              edge.targetId == 'package:pkg_a/a.dart',
        ),
        isTrue,
      );
      // 집계된 멤버가 출력에 남고 미색인 보고는 사라진다.
      expect(
        result.limitationDetails.where(
          (detail) => detail.startsWith('workspace-members-indexed:'),
        ),
        isNotEmpty,
      );
      expect(
        result.limitationDetails.where(
          (detail) => detail.startsWith('workspace-members-not-indexed:'),
        ),
        isEmpty,
      );
      expect(result.workspacePackages.map((package) => package.path), [
        'pkgs/pkg_a',
        'pkgs/pkg_b',
      ]);
      expect(result.workspacePackages.map((package) => package.name), [
        'pkg_a',
        'pkg_b',
      ]);
    });

    test(
      'member barrel, main, and test sources keep package-relative retention',
      () async {
        final workspace = await _makeWorkspace();
        addTearDown(() => workspace.delete(recursive: true));
        // pkg_a에 대표 라이브러리를 추가한다 — export된 Foo가 공개 API 보존
        // 루트를 받아야 한다(다른 멤버가 import하지 않아도 살아 있는 근거).
        await File(
          '${workspace.path}/pkgs/pkg_a/lib/pkg_a.dart',
        ).writeAsString("export 'a.dart';\n");
        await Directory(
          '${workspace.path}/pkgs/pkg_a/test',
        ).create(recursive: true);
        await File(
          '${workspace.path}/pkgs/pkg_a/test/a_test.dart',
        ).writeAsString('''
import 'package:pkg_a/a.dart';

void testMain() { Foo(); }
''');

        final result = await AnalyzerGraphIndex(
          aggregateWorkspace: true,
        ).index(workspace.path);

        expect(
          result.retentionRoots['package:pkg_a/a.dart::Foo'],
          RetentionReason.publicApi,
        );
        // 멤버 lib/ 안의 main도 루트와 같은 진입점 보존을 받는다 —
        // 루트 기준 상대 경로가 아니라 멤버 패키지 기준으로 판정됐다는 증거다.
        expect(
          result.retentionRoots['package:pkg_b/b.dart::main'],
          RetentionReason.mainEntryPoint,
        );
        // test/ 소스는 package: 밖이라 루트 기준 project: ID를 갖는다.
        expect(
          result
              .retentionRoots['project:pkgs/pkg_a/test/a_test.dart::testMain'],
          RetentionReason.visibleForTesting,
        );
      },
    );

    test(
      'requires a pub workspace root when aggregation is explicit',
      () async {
        final workspace = await _makeWorkspace();
        addTearDown(() => workspace.delete(recursive: true));
        // 멤버 자체는 workspace:를 선언하지 않는다 — 명시 플래그는 조용히 단일
        // 패키지로 내려가지 않고 루트와 같은 FormatException 계약으로 실패한다.
        final member = Directory('${workspace.path}/pkgs/pkg_b');

        await expectLater(
          AnalyzerGraphIndex(aggregateWorkspace: true).index(member.path),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('missing or invalid member paths are skipped and reported', () async {
      final workspace = await _makeWorkspace();
      addTearDown(() => workspace.delete(recursive: true));
      await File('${workspace.path}/pubspec.yaml').writeAsString('''
name: ws_root
environment:
  sdk: ^3.8.0
workspace:
  - pkgs/pkg_a
  - pkgs/missing
  - ../outside
  - pkgs/no_pubspec
''');
      await Directory(
        '${workspace.path}/pkgs/no_pubspec/lib',
      ).create(recursive: true);
      await File(
        '${workspace.path}/pkgs/no_pubspec/lib/x.dart',
      ).writeAsString('class X {}\n');

      final result = await AnalyzerGraphIndex(
        aggregateWorkspace: true,
      ).index(workspace.path);

      expect(result.graph.nodes.keys, contains('package:pkg_a/a.dart::Foo'));
      final skipped = result.limitationDetails.singleWhere(
        (detail) => detail.startsWith('workspace-members-not-indexed:'),
      );
      expect(skipped, contains('../outside'));
      expect(skipped, contains('pkgs/missing'));
      expect(skipped, contains('pkgs/no_pubspec'));
      // 건너뛴 멤버의 소스는 그래프에 없다.
      expect(
        result.graph.nodes.keys.any(
          (id) => id.startsWith('package:pkg_a/../') || id.contains('/x.dart'),
        ),
        isFalse,
      );
    });

    test('a symlinked member directory is skipped, not followed', () async {
      final workspace = await _makeWorkspace();
      addTearDown(() => workspace.delete(recursive: true));
      // 멤버 디렉터리가 루트 밖을 가리키는 symlink면 어휘적 멤버 접두사는
      // 루트 안에 있지만 실제 읽기는 밖에서 일어난다 — source_packages와
      // 같은 비symlink 계약으로 건너뛰고 보고해야 한다.
      final outside = await Directory.systemTemp.createTemp(
        'dartograph-ws-outside.',
      );
      addTearDown(() => outside.delete(recursive: true));
      await Directory('${outside.path}/lib').create();
      await File('${outside.path}/pubspec.yaml').writeAsString('''
name: pkg_link
environment:
  sdk: ^3.8.0
''');
      await File(
        '${outside.path}/lib/escaped.dart',
      ).writeAsString('class Escaped {}\n');
      await Link('${workspace.path}/pkgs/pkg_link').create(outside.path);
      await File('${workspace.path}/pubspec.yaml').writeAsString('''
name: ws_root
environment:
  sdk: ^3.8.0
workspace:
  - pkgs/pkg_a
  - pkgs/pkg_link
''');

      final result = await AnalyzerGraphIndex(
        aggregateWorkspace: true,
      ).index(workspace.path);

      final skipped = result.limitationDetails.singleWhere(
        (detail) => detail.startsWith('workspace-members-not-indexed:'),
      );
      expect(skipped, contains('pkgs/pkg_link'));
      expect(
        result.graph.nodes.keys.any((id) => id.contains('escaped')),
        isFalse,
      );
      // 일반 멤버는 루트의 symlink 조상 유무와 무관하게 색인된다 —
      // 해석된 루트 기준 비교가 아니면 이 멤버도 함께 건너뛰어진다.
      expect(result.graph.nodes.keys, contains('package:pkg_a/a.dart::Foo'));
    });

    test(
      'a workspace whose members are all unreadable fails explicitly',
      () async {
        final workspace = await _makeWorkspace();
        addTearDown(() => workspace.delete(recursive: true));
        // 선언된 멤버가 전부 건너뛰어지면 명시 요구가 조용히 단일 패키지
        // 감사로 내려가지 않도록 루트 계약과 같은 FormatException이다.
        await File('${workspace.path}/pubspec.yaml').writeAsString('''
name: ws_root
environment:
  sdk: ^3.8.0
workspace:
  - pkgs/missing
''');

        await expectLater(
          AnalyzerGraphIndex(aggregateWorkspace: true).index(workspace.path),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'a skipped member inside a standard directory stays unindexed',
      () async {
        final workspace = await _makeWorkspace();
        addTearDown(() => workspace.delete(recursive: true));
        // example/은 루트 표준 디렉터리라 pubspec 없는 선언 멤버의 소스도
        // 루트 스코프로 잡힐 수 있다 — 건너뛴 멤버로 보고하면서 루트 소스로
        // 색인하면 보고가 거짓이 되므로 스코프에서 제외돼야 한다.
        await Directory(
          '${workspace.path}/example/demo/lib',
        ).create(recursive: true);
        await File(
          '${workspace.path}/example/demo/lib/demo.dart',
        ).writeAsString('class DemoSkipped {}\n');
        await File('${workspace.path}/pubspec.yaml').writeAsString('''
name: ws_root
environment:
  sdk: ^3.8.0
workspace:
  - pkgs/pkg_a
  - example/demo
''');

        final result = await AnalyzerGraphIndex(
          aggregateWorkspace: true,
        ).index(workspace.path);

        final skipped = result.limitationDetails.singleWhere(
          (detail) => detail.startsWith('workspace-members-not-indexed:'),
        );
        expect(skipped, contains('example/demo'));
        expect(
          result.graph.nodes.keys.any((id) => id.contains('example/demo')),
          isFalse,
        );
        // 노드 ID 형식에 의존하지 않는 선언 이름 기준 확인이다.
        expect(
          result.graph.nodes.keys.any((id) => id.contains('DemoSkipped')),
          isFalse,
        );
      },
    );

    test(
      'member pubspec with invalid name fails like the root contract',
      () async {
        final workspace = await _makeWorkspace();
        addTearDown(() => workspace.delete(recursive: true));
        await File('${workspace.path}/pkgs/pkg_a/pubspec.yaml').writeAsString(
          '''
name: not-a-valid-name!
environment:
  sdk: ^3.8.0
resolution: workspace
''',
        );

        await expectLater(
          AnalyzerGraphIndex(aggregateWorkspace: true).index(workspace.path),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'member dartograph.yaml is not read and its skip is reported',
      () async {
        final workspace = await _makeWorkspace();
        addTearDown(() => workspace.delete(recursive: true));
        await File(
          '${workspace.path}/pkgs/pkg_a/dartograph.yaml',
        ).writeAsString('''
include:
  - 'pkgs/pkg_a/lib/**'
''');

        final result = await AnalyzerGraphIndex(
          aggregateWorkspace: true,
        ).index(workspace.path);

        expect(
          result.limitationDetails.where(
            (detail) => detail.startsWith('workspace-member-config-ignored:'),
          ),
          isNotEmpty,
        );
        // 멤버 설정이 적용됐다면 루트·pkg_b 소스는 범위 밖이었을 것이다.
        expect(result.graph.nodes.keys, contains('package:pkg_b/b.dart::main'));
      },
    );

    test(
      'aggregated and single-package runs do not share cache entries',
      () async {
        final workspace = await _makeWorkspace();
        addTearDown(() => workspace.delete(recursive: true));
        final cache = _MemoryCache();

        await AnalyzerGraphIndex(cache: cache).index(workspace.path);
        expect(cache.writes, 1);
        await AnalyzerGraphIndex(
          cache: cache,
          aggregateWorkspace: true,
        ).index(workspace.path);
        expect(
          cache.writes,
          2,
          reason: 'workspace and single-package cache keys must differ',
        );
        expect(cache.values.length, 2);
        // 단일 패키지 항목은 워크스페이스 집계 결과로 덮어쓰이지 않았다.
        for (final payload in cache.values.values) {
          final document = (jsonDecode(payload) as Map).cast<String, Object?>();
          expect(document['schemaVersion'], isA<int>());
        }
      },
    );

    test('incremental aggregation matches a fresh full analysis', () async {
      final workspace = await _makeWorkspace();
      addTearDown(() => workspace.delete(recursive: true));
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'dartograph-incr-ws.',
      );
      addTearDown(() => cacheDirectory.delete(recursive: true));
      final index = AnalyzerGraphIndex(
        incremental: IncrementalCache(cacheDirectory.path),
        aggregateWorkspace: true,
      );

      final first = await index.index(workspace.path);
      // 멤버 파일을 바꿔 증분 재분석을 유도한다.
      await File(
        '${workspace.path}/pkgs/pkg_a/lib/a.dart',
      ).writeAsString('class Foo { void call() {} int extra = 1; }\n');
      final second = await index.index(workspace.path);

      for (final result in [first, second]) {
        expect(result.graph.nodes.keys, contains('package:pkg_b/b.dart::main'));
        expect(result.workspacePackages.map((package) => package.path), [
          'pkgs/pkg_a',
          'pkgs/pkg_b',
        ]);
      }
      expect(
        second.graph.nodes.keys.toList()..sort(),
        isNot(contains('package:pkg_b/nope.dart')),
      );
      // 증분 결과의 멤버 매니페스트는 전체 해석과 같다.
      expect(
        second.workspacePackages.first.dependencies,
        first.workspacePackages.first.dependencies,
      );
    });

    test(
      'resolveProjectUnits sees member sources only when opted in',
      () async {
        final workspace = await _makeWorkspace();
        addTearDown(() => workspace.delete(recursive: true));

        final aggregated = await resolveProjectUnits(
          workspace.path,
          aggregateWorkspace: true,
        );
        final single = await resolveProjectUnits(workspace.path);

        bool hasMember(ResolvedUnitResult unit) =>
            unit.path.contains('/pkgs/pkg_a/lib/a.dart');
        expect(aggregated.any(hasMember), isTrue);
        expect(single.any(hasMember), isFalse);
      },
    );
  });

  test(
    'member analysis cache key includes the workspace root package_config',
    () async {
      final workspace = await _makeWorkspace();
      addTearDown(() => workspace.delete(recursive: true));
      final member = Directory('${workspace.path}/pkgs/pkg_b');
      final cache = _MemoryCache();
      final index = AnalyzerGraphIndex(cache: cache);

      await index.index(member.path);
      expect(cache.writes, 1);

      // 루트 `pub get` 결과물이 바뀌면 멤버의 해석 입력도 바뀌었을 수 있다 —
      // 멤버에 자체 package_config가 없어도 캐시 키가 갱신돼 재분석해야 한다.
      final configFile = File(
        '${workspace.path}/.dart_tool/package_config.json',
      );
      final document =
          (jsonDecode(await configFile.readAsString()) as Map)
              .cast<String, Object?>()
            ..['generator'] = 'dartograph-test-touch';
      await configFile.writeAsString(jsonEncode(document));

      await index.index(member.path);
      expect(
        cache.writes,
        2,
        reason:
            'workspace root package_config changes must invalidate member '
            'analysis caches',
      );
    },
  );
}

/// `workspace:` 멤버를 가진 실제 pub 워크스페이스를 만든다 — package_config는
/// 루트에만 생성되고 멤버는 `resolution: workspace`를 선언한다(pub 계약).
Future<Directory> _makeWorkspace() async {
  final workspace = await Directory.systemTemp.createTemp(
    'dartograph-workspace.',
  );
  await Directory('${workspace.path}/lib').create();
  await File(
    '${workspace.path}/lib/root.dart',
  ).writeAsString('class RootPackage {}\n');
  await File('${workspace.path}/pubspec.yaml').writeAsString('''
name: ws_root
environment:
  sdk: ^3.8.0
workspace:
  - pkgs/pkg_a
  - pkgs/pkg_b
''');
  await Directory('${workspace.path}/pkgs/pkg_a/lib').create(recursive: true);
  await File('${workspace.path}/pkgs/pkg_a/pubspec.yaml').writeAsString('''
name: pkg_a
environment:
  sdk: ^3.8.0
resolution: workspace
''');
  await File(
    '${workspace.path}/pkgs/pkg_a/lib/a.dart',
  ).writeAsString('class Foo { void call() {} }\n');
  await Directory('${workspace.path}/pkgs/pkg_b/lib').create(recursive: true);
  await File('${workspace.path}/pkgs/pkg_b/pubspec.yaml').writeAsString('''
name: pkg_b
environment:
  sdk: ^3.8.0
resolution: workspace
dependencies:
  pkg_a:
''');
  await File('${workspace.path}/pkgs/pkg_b/lib/b.dart').writeAsString('''
import 'package:pkg_a/a.dart';

void main() { Foo().call(); }
''');
  final result = await Process.run(Platform.resolvedExecutable, const [
    'pub',
    'get',
    '--offline',
  ], workingDirectory: workspace.path);
  expect(result.exitCode, 0, reason: result.stderr as String);
  return workspace;
}

final class _MemoryCache implements FactCache {
  final values = <String, String>{};
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    return values[key];
  }

  @override
  Future<void> write(String key, String payload) async {
    writes++;
    values[key] = payload;
  }
}
