import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
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
