import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 패키지 안에 목록을 읽을 수 없는 디렉터리가 있을 때의 색인 회귀 테스트다(#160).
///
/// 0.17.0은 그런 디렉터리 하나로 색인 전체가 `PathAccessException`으로 실패해
/// "unable to index the package"만 남겼다. 이제 분석 범위 밖 디렉터리
/// (`android/.gradle`)에는 내려가지 않고, 범위 안(`lib/locked`)은 건너뛰고 센다.
///
/// 권한 비트는 root에게 강제되지 않으므로, chmod 뒤에도 목록을 읽을 수 있으면 이
/// 호스트에서는 검증할 수 없어 건너뛴다(CI 러너는 비root 사용자다).
void main() {
  late Directory workspace;
  final locked = <String>[];

  setUp(() async {
    final created = await Directory.systemTemp.createTemp('dartograph-unread.');
    workspace = Directory(created.resolveSymbolicLinksSync());
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
  bool lock(String relative) {
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

  test('an unreadable source directory is skipped and counted; one outside '
      'the source scope is not visited', () async {
    write('pubspec.yaml', 'name: unread\nenvironment:\n  sdk: ^3.11.0\n');
    write('lib/unread.dart', 'int visible() => 1;\n');
    write('lib/locked/hidden.dart', 'int hidden() => 2;\n');
    write('android/.gradle/locked/state.bin', 'x');
    if (!lock('lib/locked') || !lock('android/.gradle/locked')) {
      markTestSkipped('permission bits are not enforced for this user');
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
  }, skip: Platform.isWindows ? 'POSIX permission bits' : false);
}

/// 매번 비어 있는 사실 캐시다. 캐시 적중으로 색인 경로를 건너뛰지 않게 한다.
final class _ColdCache implements FactCache {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String payload) async {}
}
