import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/core/graph_snapshot.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/incremental_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 증분 해석의 계약을 고정한다 — 재사용·무효화·실패 경로가 모두 전체 해석과
/// 같은 산출물을 내야 한다. 기대값은 같은 입력을 전체 경로로 돌린 결과다.
void main() {
  test('incremental runs reuse facts and match full analysis', () async {
    final fixture = await _fixture({
      'pubspec.yaml': _appPubspec,
      'lib/app.dart': "export 'a.dart';\nexport 'service.dart';\n",
      'lib/a.dart': 'class A {}\n',
      'lib/service.dart': "import 'a.dart';\nclass Service {\n  A? field;\n}\n",
      'lib/other.dart': 'class Other {}\n',
      'lib/main.dart':
          "import 'service.dart';\nvoid main() {\n  Service();\n}\n",
    });
    addTearDown(fixture.dispose);
    final full = await _full(fixture.root);

    final first = await _incrementalRun(fixture);
    expect(first.stats.reusedFiles, 0);
    expect(first.stats.resolvedFiles, 5);
    expect(first.stats.cacheNotUpdated, isFalse);
    _expectSameOutput(first.result, full);
    // 전체 해석과 같다는 것만으로는 부족하다 — 구체적인 사실을 함께 고정한다.
    expect(
      first.result.graph.nodes.keys,
      containsAll(<String>[
        'project:lib/service.dart::Service',
        'project:lib/a.dart::A',
      ]),
    );
    expect(
      first.result.retentionRoots['project:lib/a.dart::A']?.name,
      'publicApi',
    );

    final second = await _incrementalRun(fixture);
    expect(second.stats.resolvedFiles, 0);
    expect(second.stats.reusedFiles, 5);
    _expectSameOutput(second.result, full);
  });

  test('a changed file re-resolves its reverse import closure only', () async {
    final fixture = await _fixture({
      'pubspec.yaml': _appPubspec,
      'lib/app.dart': "export 'model.dart';\n",
      'lib/model.dart': 'class Model {}\n',
      'lib/service.dart':
          "import 'model.dart';\nclass Service {\n  Model? field;\n}\n",
      'lib/main.dart':
          "import 'service.dart';\nvoid main() {\n  Service();\n}\n",
      'lib/other.dart': 'class Other {}\n',
    });
    addTearDown(fixture.dispose);
    await _incrementalRun(fixture);

    // model ← service ← main, 그리고 model을 export하는 app까지 폐쇄에 든다.
    await File(
      p.join(fixture.root, 'lib', 'model.dart'),
    ).writeAsString('class Model {}\nclass ModelExtra {}\n');
    final changed = await _incrementalRun(fixture);
    expect(changed.stats.resolvedFiles, 4);
    expect(changed.stats.reusedFiles, 1);
    _expectSameOutput(changed.result, await _full(fixture.root));

    // 의존자가 없는 파일은 그 파일만 다시 해석한다.
    await File(
      p.join(fixture.root, 'lib', 'other.dart'),
    ).writeAsString('class Other {}\nclass OtherExtra {}\n');
    final leaf = await _incrementalRun(fixture);
    expect(leaf.stats.resolvedFiles, 1);
    expect(leaf.stats.reusedFiles, 4);
    _expectSameOutput(leaf.result, await _full(fixture.root));
  });

  test('a new file invalidates the importer that declared it', () async {
    final fixture = await _fixture({
      'pubspec.yaml': _appPubspec,
      'lib/main.dart': "import 'late.dart';\nvoid main() {\n  Late();\n}\n",
    });
    addTearDown(fixture.dispose);
    final before = await _incrementalRun(fixture);
    expect(
      before.result.limitationDetails,
      anyElement(contains('source-analysis-errors: project:lib/main.dart')),
    );

    // 없는 파일을 import하던 main은 미해결 상태였다. 파일이 생기면 main의
    // 해석이 바뀌므로 다시 해석돼야 한다 — 선언된 지시문을 의존으로 세지
    // 않으면 여기서 낡은 사실이 재사용된다.
    await File(
      p.join(fixture.root, 'lib', 'late.dart'),
    ).writeAsString('class Late {}\n');
    final after = await _incrementalRun(fixture);
    expect(after.stats.resolvedFiles, 2);
    expect(
      after.result.graph.nodes.keys,
      contains('project:lib/late.dart::Late'),
    );
    _expectSameOutput(after.result, await _full(fixture.root));
  });

  test('a deleted file invalidates its dependents', () async {
    final fixture = await _fixture({
      'pubspec.yaml': _appPubspec,
      'lib/app.dart': "export 'a.dart';\n",
      'lib/a.dart': 'class A {}\n',
      'lib/other.dart': 'class Other {}\n',
      'lib/main.dart': "import 'a.dart';\nvoid main() {\n  A();\n}\n",
    });
    addTearDown(fixture.dispose);
    await _incrementalRun(fixture);

    await File(p.join(fixture.root, 'lib', 'a.dart')).delete();
    final after = await _incrementalRun(fixture);
    expect(after.stats.resolvedFiles, 2);
    expect(
      after.result.graph.nodes.keys,
      isNot(contains('project:lib/a.dart::A')),
    );
    _expectSameOutput(after.result, await _full(fixture.root));
  });

  test('part changes re-resolve the whole library', () async {
    final fixture = await _fixture({
      'pubspec.yaml': _appPubspec,
      'lib/app.dart': "export 'host.dart';\n",
      'lib/host.dart': "part 'host_part.dart';\nclass Host {}\n",
      'lib/host_part.dart': "part of 'host.dart';\nclass HostPart {}\n",
      'lib/other.dart': 'class Other {}\n',
    });
    addTearDown(fixture.dispose);
    final first = await _incrementalRun(fixture);
    expect(
      first.result.graph.nodes.keys,
      contains('project:lib/host.dart::HostPart'),
    );

    await File(p.join(fixture.root, 'lib', 'host_part.dart')).writeAsString(
      "part of 'host.dart';\nclass HostPart {}\nclass HostPartExtra {}\n",
    );
    final after = await _incrementalRun(fixture);
    // part·호스트·호스트를 export하는 app이 함께 다시 해석된다.
    expect(after.stats.resolvedFiles, 3);
    expect(after.stats.reusedFiles, 1);
    expect(
      after.result.graph.nodes.keys,
      contains('project:lib/host.dart::HostPartExtra'),
    );
    _expectSameOutput(after.result, await _full(fixture.root));
  });

  test('configuration change invalidates every file', () async {
    final fixture = await _fixture({
      'pubspec.yaml': _appPubspec,
      'lib/main.dart': 'void main() {}\n',
      'lib/other.dart': 'class Other {}\n',
    });
    addTearDown(fixture.dispose);
    await _incrementalRun(fixture);

    // dartograph.yaml은 해석 입력이다 — 내용이 바뀌면 모든 키가 바뀌어야 한다.
    await File(
      p.join(fixture.root, 'dartograph.yaml'),
    ).writeAsString('entry_points:\n  - lib/main.dart\n');
    final after = await _incrementalRun(fixture);
    expect(after.stats.resolvedFiles, 2);
    expect(after.stats.reusedFiles, 0);
    _expectSameOutput(after.result, await _full(fixture.root));
  });

  test('dependency package contents invalidate every file', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'dartograph-incremental-dependency.',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final dependency = Directory(p.join(workspace.path, 'dependency'));
    final application = Directory(p.join(workspace.path, 'application'));
    await _write(
      p.join(dependency.path, 'pubspec.yaml'),
      'name: dependency\nenvironment:\n  sdk: ^3.11.0\n',
    );
    final framework = File(p.join(dependency.path, 'lib', 'dependency.dart'));
    await framework.create(recursive: true);
    await framework.writeAsString('class Framework {}\n');
    await _write(
      p.join(application.path, 'pubspec.yaml'),
      'name: application\nenvironment:\n  sdk: ^3.11.0\n'
      'dependencies:\n  dependency:\n    path: ../dependency\n',
    );
    final main = File(p.join(application.path, 'lib', 'main.dart'));
    await main.create(recursive: true);
    await main.writeAsString(
      "import 'package:dependency/dependency.dart';\n"
      'void main() {\n  Framework();\n}\n',
    );
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: application.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
    final fixture = _Fixture(
      workspace,
      application.path,
      p.join(workspace.path, 'facts'),
    );

    final before = await _incrementalRun(fixture);
    await framework.writeAsString('class Framework {\n  void added() {}\n}\n');
    final after = await _incrementalRun(fixture);
    expect(after.stats.resolvedFiles, 1);
    expect(after.stats.reusedFiles, 0);
    _expectSameOutput(after.result, await _full(fixture.root));
    expect(
      after.result.graph.nodes.keys,
      isNot(contains('package:dependency/dependency.dart::Framework.added')),
    );
    expect(
      before.result.graph.nodes.keys,
      isNot(contains('package:dependency/dependency.dart::Framework.added')),
    );
  });

  test(
    'corrupt, versioned and unreadable caches fall back to full analysis',
    () async {
      final fixture = await _fixture({
        'pubspec.yaml': _appPubspec,
        'lib/main.dart': 'void main() {}\n',
        'lib/other.dart': 'class Other {}\n',
      });
      addTearDown(fixture.dispose);
      final cacheFile = File(p.join(fixture.cacheDirectory, 'facts.json'));
      final full = await _full(fixture.root);

      // 캐시 디렉터리가 없으면 첫 실행은 전체 해석이다.
      final first = await _incrementalRun(fixture);
      expect(first.stats.resolvedFiles, 2);
      _expectSameOutput(first.result, full);
      expect(cacheFile.existsSync(), isTrue);

      // 잘린 JSON은 전체 해석으로 폴백하고, 다음 실행이 캐시를 복구한다.
      await cacheFile.writeAsString('{');
      final corrupt = await _incrementalRun(fixture);
      expect(corrupt.stats.reusedFiles, 0);
      expect(corrupt.stats.resolvedFiles, 2);
      expect(corrupt.stats.cacheNotUpdated, isFalse);
      _expectSameOutput(corrupt.result, full);
      expect((await _incrementalRun(fixture)).stats.reusedFiles, 2);

      // 스키마 버전이 다르면 전부 미스다.
      await cacheFile.writeAsString('{"entries":{},"schemaVersion":99}');
      final versioned = await _incrementalRun(fixture);
      expect(versioned.stats.reusedFiles, 0);
      _expectSameOutput(versioned.result, full);

      // 항목 하나가 망가져도 그 파일만 다시 해석된다.
      final decoded = jsonDecode(await cacheFile.readAsString()) as Map;
      final entries = decoded['entries']! as Map;
      entries['lib/other.dart'] = {
        'facts': {'library': 7},
        'key': 'x',
      };
      await cacheFile.writeAsString(jsonEncode(decoded));
      final repaired = await _incrementalRun(fixture);
      expect(repaired.stats.resolvedFiles, 1);
      expect(repaired.stats.reusedFiles, 1);
      _expectSameOutput(repaired.result, full);

      // 캐시를 지워도(wipe) 결과는 그대로이고 다음 실행이 복구한다.
      await Directory(fixture.cacheDirectory).delete(recursive: true);
      final wiped = await _incrementalRun(fixture);
      expect(wiped.stats.reusedFiles, 0);
      _expectSameOutput(wiped.result, full);
      expect((await _incrementalRun(fixture)).stats.reusedFiles, 2);
    },
  );

  test(
    'a cache that cannot be written still reports complete results',
    () async {
      final fixture = await _fixture({
        'pubspec.yaml': _appPubspec,
        'lib/main.dart': 'void main() {}\n',
      });
      addTearDown(fixture.dispose);
      // 캐시 경로 자리에 파일을 두어 디렉터리 생성이 실패하게 만든다.
      await File(fixture.cacheDirectory).writeAsString('not a directory');
      final full = await _full(fixture.root);

      final result = await _incrementalRun(fixture);

      expect(result.stats.cacheNotUpdated, isTrue);
      expect(result.stats.resolvedFiles, 1);
      expect(
        result.result.limitationDetails,
        contains(
          'incremental-cache-write-failed: analysis is complete but the fact '
          'cache was not updated',
        ),
      );
      // 한계 문구 하나만 다르고 나머지 산출물은 전체 해석과 같다.
      _expectSameOutput(
        result.result,
        full,
        expectedExtraLimitations: const [
          'incremental-cache-write-failed: analysis is complete but the fact '
              'cache was not updated',
        ],
      );

      // 캐시를 쓸 수 없어도 다음 실행이 같은 결과를 다시 낸다.
      final again = await _incrementalRun(fixture);
      expect(again.stats.reusedFiles, 0);
      _expectSameOutput(
        again.result,
        full,
        expectedExtraLimitations: const [
          'incremental-cache-write-failed: analysis is complete but the fact '
              'cache was not updated',
        ],
      );
    },
  );

  test('resolution keys separate content, tool and configuration', () {
    final base = IncrementalCache.resolutionKey(
      toolVersion: '1.0.0',
      sdkVersion: 'Dart 3',
      configFingerprint: 'config',
    );
    final same = IncrementalCache.resolutionKey(
      toolVersion: '1.0.0',
      sdkVersion: 'Dart 3',
      configFingerprint: 'config',
    );
    expect(same, base);
    expect(
      IncrementalCache.resolutionKey(
        toolVersion: '1.0.1',
        sdkVersion: 'Dart 3',
        configFingerprint: 'config',
      ),
      isNot(base),
    );
    expect(
      IncrementalCache.resolutionKey(
        toolVersion: '1.0.0',
        sdkVersion: 'Dart 4',
        configFingerprint: 'config',
      ),
      isNot(base),
    );
    expect(
      IncrementalCache.resolutionKey(
        toolVersion: '1.0.0',
        sdkVersion: 'Dart 3',
        configFingerprint: 'other',
      ),
      isNot(base),
    );
    expect(
      IncrementalCache.keyFor(resolutionKey: base, contentHash: 'a'),
      isNot(IncrementalCache.keyFor(resolutionKey: base, contentHash: 'b')),
    );
    expect(
      IncrementalCache.keyFor(resolutionKey: base, contentHash: 'a'),
      IncrementalCache.keyFor(resolutionKey: base, contentHash: 'a'),
    );
  });

  test('reverse closure walks dependents transitively', () {
    final reverse = <String, Set<String>>{
      'lib/a.dart': {'lib/b.dart'},
      'lib/b.dart': {'lib/c.dart', 'lib/d.dart'},
    };

    expect(IncrementalCache.reverseClosure(const [], reverse), isEmpty);
    expect(IncrementalCache.reverseClosure(const ['lib/a.dart'], reverse), {
      'lib/a.dart',
      'lib/b.dart',
      'lib/c.dart',
      'lib/d.dart',
    });
    expect(IncrementalCache.reverseClosure(const ['lib/c.dart'], reverse), {
      'lib/c.dart',
    });
    // 순환 의존에서도 끝난다.
    expect(
      IncrementalCache.reverseClosure(
        const ['lib/a.dart'],
        {
          'lib/a.dart': {'lib/b.dart'},
          'lib/b.dart': {'lib/a.dart'},
        },
      ),
      {'lib/a.dart', 'lib/b.dart'},
    );
  });
}

const _appPubspec = 'name: app\nenvironment:\n  sdk: ^3.11.0\n';

/// 증분 실행 한 번의 관측값이다.
final class _IncrementalRun {
  const _IncrementalRun(this.result, this.stats);

  final AnalyzerGraphResult result;
  final IncrementalStats stats;
}

/// 사실 캐시를 초기화한 전체 해석이다(OS 사용자 캐시를 쓰지 않는다).
Future<AnalyzerGraphResult> _full(String root) =>
    AnalyzerGraphIndex(cache: _ColdCache()).index(root);

Future<_IncrementalRun> _incrementalRun(_Fixture fixture) async {
  final cache = IncrementalCache(fixture.cacheDirectory);
  final result = await AnalyzerGraphIndex(
    cache: _ColdCache(),
    incremental: cache,
  ).index(fixture.root);
  return _IncrementalRun(result, cache.stats);
}

/// 산출물이 byte 동등한지 확인한다. 한계 문구를 뺀 모든 관측값을 비교한다.
void _expectSameOutput(
  AnalyzerGraphResult actual,
  AnalyzerGraphResult expected, {
  List<String> expectedExtraLimitations = const [],
}) {
  expect(
    _digest(actual.graph.snapshot()),
    _digest(expected.graph.snapshot()),
    reason: '그래프가 전체 해석과 달라졌다',
  );
  expect(
    actual.limitations.map((item) => item.name).toList(),
    expected.limitations.map((item) => item.name).toList(),
  );
  expect(
    actual.limitationDetails,
    expected.limitationDetails + expectedExtraLimitations,
  );
  expect(
    _rootsDigest(actual),
    _rootsDigest(expected),
    reason: '보존 루트가 전체 해석과 달라졌다',
  );
}

/// 정점·간선의 결정적 직렬화다(해시 대조용).
String _digest(GraphSnapshot snapshot) => jsonEncode({
  'edges': [
    for (final edge in snapshot.edges)
      '${edge.sourceId}|${edge.kind.name}|${edge.targetId}',
  ],
  'nodes': [
    for (final node in snapshot.nodes)
      '${node.id}|${node.sourceUri}|${node.line}|${node.column}|'
          '${node.synthesized}|${node.isLibrary}|'
          '${node.isTypeDeclaration}|${node.isAbstract}|'
          '${node.isEnumConstant}',
  ],
});

String _rootsDigest(AnalyzerGraphResult result) {
  final ids = result.retentionRoots.keys.toList()..sort();
  return jsonEncode([
    for (final id in ids) '$id=${result.retentionRoots[id]!.name}',
  ]);
}

/// 분석 대상 루트와 캐시 디렉터리를 함께 가진 임시 픽스처다.
final class _Fixture {
  const _Fixture(this.workspace, this.root, this.cacheDirectory);

  final Directory workspace;
  final String root;
  final String cacheDirectory;

  Future<void> dispose() => workspace.delete(recursive: true);
}

Future<_Fixture> _fixture(Map<String, String> files) async {
  final workspace = await Directory.systemTemp.createTemp(
    'dartograph-incremental.',
  );
  final root = p.join(workspace.path, 'app');
  for (final entry in files.entries) {
    await _write(p.join(root, entry.key), entry.value);
  }
  return _Fixture(workspace, root, p.join(workspace.path, 'facts'));
}

Future<void> _write(String path, String contents) async {
  final file = File(path);
  await file.create(recursive: true);
  await file.writeAsString(contents);
}

/// 항상 miss인 캐시 — 전체 해석 경로를 그대로 쓴다.
final class _ColdCache implements FactCache {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String payload) async {}
}
