// 사례마다 실제 analyzer 전체 분석을 여섯 번(편집 둘 × 데운·차가운 비교) 돌린다.
// 공유 호스트에서 기본 30초를 넘는 일이 있어 다른 무거운 테스트처럼 넉넉히 둔다.
@Timeout(Duration(seconds: 90))
library;

import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `include:`로 닿는 옵션 파일을 고친 뒤 데워진 전체 결과 캐시가 낡은 결과를
/// 돌려주지 않는지 고정한다. analyzer는 include한 파일의 `analyzer: exclude:`도
/// 적용하므로(14.6부터는 패키지 기준으로) 그 파일이 키에 없으면 제외를 풀거나
/// 걸어도 이전 그래프가 재사용된다.
void main() {
  late Directory workspace;
  late String app;

  void write(String relative, String content) {
    File(p.join(workspace.path, relative))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  const excludeLegacy = 'analyzer:\n  exclude:\n    - "lib/legacy/**"\n';
  const excludeNothing = 'analyzer:\n  exclude: []\n';
  // 조상 디렉터리의 옵션 파일 패턴은 그 파일의 디렉터리 기준이다(모든 analyzer).
  const excludeLegacyAnywhere = 'analyzer:\n  exclude:\n    - "**/legacy/**"\n';
  const legacyLibrary = 'project:lib/legacy/old.dart';

  setUp(() {
    workspace = Directory(
      Directory.systemTemp
          .createTempSync('dartograph-options-include.')
          .resolveSymbolicLinksSync(),
    );
    app = p.join(workspace.path, 'app');
    write('app/pubspec.yaml', 'name: app\npublish_to: none\n');
    write('app/bin/main.dart', 'void main() {}\n');
    write('app/lib/legacy/old.dart', 'void old() {}\n');
  });
  tearDown(() => workspace.deleteSync(recursive: true));

  Future<AnalyzerGraphResult> index(FactCache cache) => AnalyzerGraphIndex(
    cache: cache,
    userCacheEnvironment: const {},
  ).index(app);

  bool analyzesLegacy(AnalyzerGraphResult result) =>
      result.graph.containsNode(legacyLibrary);

  /// [included] 파일을 [before]에서 [after]로 고치고, 데워진 캐시의 결과가 차가운
  /// 결과와 같으며 새 키로 저장됐는지 확인한다. 고친 뒤의 차가운 결과를 돌려준다.
  Future<AnalyzerGraphResult> edit(
    String included, {
    required String before,
    required String after,
  }) async {
    final cache = _MemoryCache();
    write(included, before);
    await index(cache);
    final keys = cache.keys;
    write(included, after);

    final warm = await index(cache);
    final cold = await index(_MemoryCache());

    expect(
      cache.keys,
      isNot(keys),
      reason: '$included must be a cache key input',
    );
    expect(warm.graph.nodes.keys, cold.graph.nodes.keys);
    expect(warm.limitationDetails, cold.limitationDetails);
    return cold;
  }

  test('a same-directory include is keyed in both directions', () async {
    // 같은 디렉터리 include는 검증한 모든 analyzer(14.3–14.7)가 적용한다.
    write('app/analysis_options.yaml', 'include: shared_options.yaml\n');

    final lifted = await edit(
      'app/shared_options.yaml',
      before: excludeLegacy,
      after: excludeNothing,
    );
    expect(analyzesLegacy(lifted), isTrue);

    final excluded = await edit(
      'app/shared_options.yaml',
      before: excludeNothing,
      after: excludeLegacy,
    );
    expect(analyzesLegacy(excluded), isFalse);
  });

  test('an include outside the package root is keyed', () async {
    write('app/analysis_options.yaml', 'include: ../shared/options.yaml\n');

    await edit(
      'shared/options.yaml',
      before: excludeLegacy,
      after: excludeNothing,
    );
    await edit(
      'shared/options.yaml',
      before: excludeNothing,
      after: excludeLegacy,
    );
  });

  test(
    'every file of an include list and of a nested include is keyed',
    () async {
      write(
        'app/analysis_options.yaml',
        'include:\n  - first.yaml\n  - ../shared/second.yaml\n',
      );
      write('app/first.yaml', 'linter:\n  rules: []\n');
      write('shared/second.yaml', 'include: third.yaml\n');

      await edit(
        'shared/third.yaml',
        before: excludeLegacy,
        after: excludeNothing,
      );
      await edit(
        'app/first.yaml',
        before: excludeNothing,
        after: excludeLegacy,
      );
    },
  );

  test('a file: URI include is keyed', () async {
    final shared = p.join(workspace.path, 'shared', 'uri.yaml');
    write('app/analysis_options.yaml', 'include: ${Uri.file(shared)}\n');

    await edit('shared/uri.yaml', before: excludeLegacy, after: excludeNothing);
  });

  test('a package: include is resolved through package_config', () async {
    // 공유 lint 패키지(루트 밖 path 의존)의 이름이 analysis_options.yaml이
    // 아닌 옵션 파일을 package_config로 찾는다. 그 파일이 다시 package:로 잇는
    // 파일도 같다.
    write('app/analysis_options.yaml', 'include: package:lints_x/all.yaml\n');
    write('lints_x/pubspec.yaml', 'name: lints_x\n');
    write('lints_x/lib/all.yaml', 'include: package:lints_x/core.yaml\n');
    write('app/.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {"name": "app", "rootUri": "../", "packageUri": "lib/"},
    {"name": "lints_x", "rootUri": "../../lints_x/", "packageUri": "lib/"}
  ]
}
''');

    await edit(
      'lints_x/lib/core.yaml',
      before: excludeLegacy,
      after: excludeNothing,
    );
    await edit(
      'lints_x/lib/core.yaml',
      before: excludeNothing,
      after: excludeLegacy,
    );
  });

  // 패키지에 자기 analysis_options.yaml이 없으면 analyzer는 조상 디렉터리에서 가장
  // 가까운 것을 쓴다(14.3–14.7의 `findAnalysisOptionsYamlFile`). 모노레포 루트의
  // 옵션 파일이 그 예다. 그 파일과 그것의 include 체인이 루트 밖이어도 키다.
  test(
    'an inherited ancestor options file is keyed in both directions',
    () async {
      final lifted = await edit(
        'analysis_options.yaml',
        before: excludeLegacyAnywhere,
        after: excludeNothing,
      );
      expect(analyzesLegacy(lifted), isTrue);

      final excluded = await edit(
        'analysis_options.yaml',
        before: excludeNothing,
        after: excludeLegacyAnywhere,
      );
      expect(analyzesLegacy(excluded), isFalse);
    },
  );

  test('the include chain of an inherited options file is keyed', () async {
    write('analysis_options.yaml', 'include: shared/monorepo.yaml\n');

    final lifted = await edit(
      'shared/monorepo.yaml',
      before: excludeLegacyAnywhere,
      after: excludeNothing,
    );
    expect(analyzesLegacy(lifted), isTrue);
    await edit(
      'shared/monorepo.yaml',
      before: excludeNothing,
      after: excludeLegacyAnywhere,
    );
  });

  test('an ancestor options file the package overrides is not keyed', () async {
    // 자기 옵션 파일이 있으면 analyzer는 조상을 보지 않는다. 키도 analyzer가 실제로
    // 읽는 파일만 따른다.
    write('app/analysis_options.yaml', excludeNothing);
    write('analysis_options.yaml', excludeLegacyAnywhere);
    final cache = _MemoryCache();
    await index(cache);
    final keys = cache.keys;

    write('analysis_options.yaml', 'analyzer:\n  exclude:\n    - "bin/**"\n');
    final warm = await index(cache);

    expect(cache.keys, keys);
    expect(analyzesLegacy(warm), isTrue);
  });
}

/// 실행 사이에 결과를 보관하는 메모리 사실 캐시다. 데워진 캐시를 흉내 낸다.
final class _MemoryCache implements FactCache {
  final _entries = <String, String>{};

  @override
  Future<String?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, String payload) async =>
      _entries[key] = payload;

  /// 지금까지 쓴 키다. 키가 바뀌면 새 항목이 생긴다.
  Set<String> get keys => {..._entries.keys};
}
