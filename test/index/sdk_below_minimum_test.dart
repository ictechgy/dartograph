import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/incremental_cache.dart';
import 'package:test/test.dart';

/// 분석에 쓰는 Dart SDK가 패키지 `environment.sdk` 하한보다 낮을 때 실제 analyzer
/// 색인이 그 사실을 한계로 세는지 고정한다. 오류가 아니며 그래프는 그대로다.
void main() {
  // `dart test`는 SDK 안의 VM으로 돌고, 색인은 실행 중인 VM의 SDK를 가장 먼저
  // 쓴다. 그 SDK 버전은 VM 버전 문자열의 첫 낱말이다(제품의 탐색과 따로 읽는다).
  final sdkVersion = Platform.version.split(' ').first;

  String limitation(int count, String packages) =>
      'sdk-below-minimum: Dart SDK $sdkVersion used for analysis is below the '
      'environment.sdk lower bound of $count package(s): $packages; SDK '
      'libraries and language features newer than $sdkVersion may not '
      'resolve, so reachability can be incomplete (analyze with a Dart SDK '
      'that satisfies environment.sdk)';

  late Directory root;

  Future<void> write(String relative, String content) async {
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  /// [environment]를 pubspec 이름 뒤에 그대로 붙인 패키지를 만든다.
  Future<void> package(String environment) =>
      write('pubspec.yaml', 'name: floor\npublish_to: none\n$environment');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dartograph-sdk-floor.');
    await write('lib/floor.dart', 'class Floor {}\n');
    await write('bin/main.dart', 'void main() {}\n');
  });
  tearDown(() => root.delete(recursive: true));

  Iterable<String> sdkFloor(AnalyzerGraphResult result) => result
      .limitationDetails
      .where((detail) => detail.startsWith('sdk-below-minimum:'));

  Future<AnalyzerGraphResult> index({FactCache? cache}) => AnalyzerGraphIndex(
    cache: cache,
    userCacheEnvironment: const {},
  ).index(root.path);

  test('a lower bound above the analysis SDK is counted', () async {
    await package('environment:\n  sdk: ^99.0.0\n');

    final result = await index();

    expect(sdkFloor(result), [limitation(1, 'pubspec.yaml (>=99.0.0)')]);
    // 한계만 더한다. 그래프는 충족하는 제약과 같다.
    expect(result.graph.nodes.keys, contains('project:bin/main.dart::main'));
  });

  test('an exclusive lower bound at the analysis SDK is counted', () async {
    await package("environment:\n  sdk: '>$sdkVersion <100.0.0'\n");

    expect(sdkFloor(await index()), [
      limitation(1, 'pubspec.yaml (>$sdkVersion)'),
    ]);
  });

  test('an inclusive lower bound at the analysis SDK is not counted', () async {
    await package("environment:\n  sdk: '>=$sdkVersion <100.0.0'\n");

    expect(sdkFloor(await index()), isEmpty);
  });

  test('a lower bound below the analysis SDK is not counted', () async {
    await package('environment:\n  sdk: ^3.0.0\n');

    expect(sdkFloor(await index()), isEmpty);
  });

  test(
    'a package without an environment.sdk constraint is not counted',
    () async {
      for (final environment in [
        '',
        'environment:\n',
        'environment:\n  flutter: ">=99.0.0"\n',
      ]) {
        await package(environment);

        expect(sdkFloor(await index()), isEmpty, reason: environment);
      }
    },
  );

  test('constraints without a lower bound are not counted', () async {
    for (final constraint in ['any', "'<99.0.0'", 'not-a-version', '99']) {
      await package('environment:\n  sdk: $constraint\n');

      expect(sdkFloor(await index()), isEmpty, reason: constraint);
    }
  });

  test('a warm cache follows the pubspec constraint both ways', () async {
    final cache = _MemoryCache();
    await package('environment:\n  sdk: ^3.0.0\n');
    expect(sdkFloor(await index(cache: cache)), isEmpty);

    await package('environment:\n  sdk: ^99.0.0\n');
    expect(sdkFloor(await index(cache: cache)), hasLength(1));

    await package('environment:\n  sdk: ^3.0.0\n');
    expect(sdkFloor(await index(cache: cache)), isEmpty);
  });

  test('the incremental path counts it on full and reused runs', () async {
    await package('environment:\n  sdk: ^99.0.0\n');
    final facts = await Directory.systemTemp.createTemp(
      'dartograph-floor-incr.',
    );
    addTearDown(() => facts.delete(recursive: true));
    Future<AnalyzerGraphResult> incremental() => AnalyzerGraphIndex(
      incremental: IncrementalCache(facts.path),
    ).index(root.path);

    final first = await incremental();
    // 두 번째 실행은 모든 파일의 사실을 캐시에서 재사용하고 결과만 다시 조립한다.
    final reused = await incremental();

    for (final result in [first, reused]) {
      expect(sdkFloor(result), [limitation(1, 'pubspec.yaml (>=99.0.0)')]);
    }
  });

  test('workspace aggregation counts every analyzed package', () async {
    await write('pubspec.yaml', '''
name: ws_root
publish_to: none
environment:
  sdk: ^99.0.0
workspace:
  - pkgs/a
  - pkgs/b
''');
    await write('pkgs/a/pubspec.yaml', '''
name: a
environment:
  sdk: '>99.1.0 <100.0.0'
resolution: workspace
''');
    await write('pkgs/a/lib/a.dart', 'class A {}\n');
    // 충족하는 멤버는 세지 않는다.
    await write('pkgs/b/pubspec.yaml', '''
name: b
environment:
  sdk: ^3.0.0
resolution: workspace
''');
    await write('pkgs/b/lib/b.dart', 'class B {}\n');

    final aggregated = await AnalyzerGraphIndex(
      aggregateWorkspace: true,
      userCacheEnvironment: const {},
    ).index(root.path);
    final single = await index();

    expect(sdkFloor(aggregated), [
      limitation(2, 'pkgs/a/pubspec.yaml (>99.1.0), pubspec.yaml (>=99.0.0)'),
    ]);
    // 멤버를 집계하지 않으면 분석한 패키지는 루트 하나다.
    expect(sdkFloor(single), [limitation(1, 'pubspec.yaml (>=99.0.0)')]);
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
}
