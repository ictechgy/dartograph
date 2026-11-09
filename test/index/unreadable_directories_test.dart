import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/bridge_index.dart';
import 'package:dartograph/src/index/project_files.dart';
import 'package:dartograph/src/index/route_call_index.dart';
import 'package:dartograph/src/index/schema_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 패키지 안에 목록을 읽을 수 없는 디렉터리가 있을 때의 색인 회귀 테스트다(#160).
///
/// 0.17.0은 그런 디렉터리 하나로 색인 전체가 `PathAccessException`으로 실패해
/// "unable to index the package"만 남겼다. 이제 그래프 색인은 분석 범위 밖
/// 디렉터리(`android/.gradle`)에 내려가지 않고, 범위 안(`lib/locked`)은 건너뛰고
/// 센다. 공유 순회(`bridges`·`schema`·`routes`·`runtime`)도 건너뛰고 센다.
///
/// 권한 비트는 root에게 강제되지 않으므로, chmod 뒤에도 목록을 읽을 수 있으면 이
/// 호스트에서는 검증할 수 없어 건너뛴다(CI 러너는 비root 사용자다). root에서는
/// `setpriv --bounding-set -dac_override,-dac_read_search`로 실행하면 검증된다.
void main() {
  late Directory workspace;
  final locked = <String>[];

  setUp(() async {
    final created = await Directory.systemTemp.createTemp('dartograph-unread.');
    workspace = Directory(created.resolveSymbolicLinksSync());
    File(
      p.join(workspace.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: unread\nenvironment:\n  sdk: ^3.11.0\n');
    File(p.join(workspace.path, 'lib', 'unread.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('int visible() => 1;\n');
  });
  tearDown(() async {
    // 잠근 디렉터리를 풀어야 비root 사용자가 임시 디렉터리를 지울 수 있다.
    for (final path in locked) {
      Process.runSync('chmod', ['755', path]);
    }
    locked.clear();
    await workspace.delete(recursive: true);
  });

  /// [relative]에 [content] 파일을 만든다.
  void write(String relative, String content) =>
      File(p.join(workspace.path, relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  /// [relative] 디렉터리의 권한을 모두 지운다. 그래도 읽히면 false다.
  ///
  /// Windows에는 POSIX 권한 비트가 없으므로 언제나 false다(테스트를 건너뛴다).
  bool lock(String relative) {
    if (Platform.isWindows) return false;
    final path = p.join(workspace.path, relative);
    Process.runSync('chmod', ['000', path]);
    locked.add(path);
    try {
      Directory(path).listSync();
      return false;
    } on FileSystemException {
      return true;
    }
  }

  /// [relative] 디렉터리를 다시 연다.
  void unlock(String relative) {
    final path = p.join(workspace.path, relative);
    Process.runSync('chmod', ['755', path]);
    locked.remove(path);
  }

  /// 권한이 강제되지 않는 호스트에서 테스트를 건너뛰게 하는 표지다.
  const notEnforced =
      'POSIX permission bits are not enforced for this user or platform';

  /// [limitations] 중 읽지 못한 디렉터리 한계만 고른다.
  List<String> unreadable(List<String> limitations) => [
    for (final limitation in limitations)
      if (limitation.startsWith('unreadable-directories:')) limitation,
  ];

  test('an unreadable source directory is skipped and counted; one outside '
      'the source scope is not visited', () async {
    write('lib/locked/hidden.dart', 'int hidden() => 2;\n');
    write('android/.gradle/locked/state.bin', 'x');
    if (!lock('lib/locked') || !lock('android/.gradle/locked')) {
      markTestSkipped(notEnforced);
      return;
    }

    final result = await AnalyzerGraphIndex(
      cache: _ColdCache(),
    ).index(workspace.path);

    final ids = result.graph.nodes.keys;
    expect(ids, contains(contains('lib/unread.dart')));
    expect(ids, isNot(contains(contains('hidden'))));
    // lib/locked 하나만 센다 — android/.gradle은 분석 범위가 닿지 않아 열지 않는다.
    expect(
      result.limitationDetails,
      contains(unreadableDirectoriesLimitation(1)),
    );
  });

  test('a warm cache does not hide a directory locked afterwards', () async {
    Directory(p.join(workspace.path, 'lib', 'feature')).createSync();
    final cache = _MemoryCache();
    final warm = await AnalyzerGraphIndex(cache: cache).index(workspace.path);
    expect(unreadable(warm.limitationDetails), isEmpty);
    if (!lock('lib/feature')) {
      markTestSkipped(notEnforced);
      return;
    }

    final locked = await AnalyzerGraphIndex(cache: cache).index(workspace.path);

    expect(unreadable(locked.limitationDetails), [
      unreadableDirectoriesLimitation(1),
    ]);
  });

  test('a cached limitation does not outlive the unlocked directory', () async {
    Directory(p.join(workspace.path, 'lib', 'feature')).createSync();
    if (!lock('lib/feature')) {
      markTestSkipped(notEnforced);
      return;
    }
    final cache = _MemoryCache();
    final locked = await AnalyzerGraphIndex(cache: cache).index(workspace.path);
    expect(unreadable(locked.limitationDetails), hasLength(1));
    unlock('lib/feature');

    final reopened = await AnalyzerGraphIndex(
      cache: cache,
    ).index(workspace.path);

    expect(unreadable(reopened.limitationDetails), isEmpty);
  });

  test('a generated file in a hidden source directory is part of the cache '
      'key', () async {
    // 키의 루트 순회는 숨김 디렉터리를 가지치기하지만 생성 파일 보충은 lib/.x/에도
    // 내려간다. 키가 그곳을 보지 않으면 고친 뒤에도 낡은 결과가 재사용된다.
    write('lib/.generated/model.g.dart', 'int alphaGenerated() => 1;\n');
    final cache = _MemoryCache();
    final before = await AnalyzerGraphIndex(cache: cache).index(workspace.path);
    expect(before.graph.nodes.keys, contains(contains('alphaGenerated')));

    write('lib/.generated/model.g.dart', 'int betaGenerated() => 2;\n');
    final after = await AnalyzerGraphIndex(cache: cache).index(workspace.path);

    expect(after.graph.nodes.keys, contains(contains('betaGenerated')));
    expect(after.graph.nodes.keys, isNot(contains(contains('alphaGenerated'))));
  });

  group('shared project walk', () {
    test('records an unreadable subdirectory and keeps walking', () {
      write('lib/locked/hidden.dart', 'int hidden() => 2;\n');
      if (!lock('lib/locked')) {
        markTestSkipped(notEnforced);
        return;
      }
      final visits = LinkedDirectoryVisits();

      final files = indexProjectFiles(
        workspace,
        linkedDirectories: visits,
      ).map((file) => p.relative(file.path, from: workspace.path)).toList();

      expect(
        files,
        containsAll(['pubspec.yaml', p.join('lib', 'unread.dart')]),
      );
      expect(visits.unreadable, {p.join(workspace.path, 'lib', 'locked')});
    });

    test('rethrows when the start directory cannot be listed', () {
      Directory(p.join(workspace.path, 'lib', 'locked')).createSync();
      if (!lock('lib/locked')) {
        markTestSkipped(notEnforced);
        return;
      }
      final visits = LinkedDirectoryVisits();

      expect(
        () => indexProjectFiles(
          Directory(p.join(workspace.path, 'lib', 'locked')),
          linkedDirectories: visits,
        ).toList(),
        throwsA(isA<FileSystemException>()),
      );
      expect(visits.unreadable, isEmpty);
    });

    test('bridges, schema, and routes report the skipped directory', () async {
      write('lib/locked/hidden.dart', 'int hidden() => 2;\n');
      if (!lock('lib/locked')) {
        markTestSkipped(notEnforced);
        return;
      }
      final expected = unreadableDirectoriesLimitation(1);

      expect(indexBridges(workspace.path).limitations, contains(expected));
      expect(
        (await indexSchema(workspace.path)).limitations,
        contains(expected),
      );
      expect(
        (await indexRouteCalls(workspace.path)).limitations,
        contains(expected),
      );
    });
  });
}

/// 매번 비어 있는 사실 캐시다. 캐시 적중으로 색인 경로를 건너뛰지 않게 한다.
final class _ColdCache implements FactCache {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String payload) async {}
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
