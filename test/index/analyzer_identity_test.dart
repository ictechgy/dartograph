import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/analyzer_identity.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// dartograph가 링크한 analyzer가 다르면 같은 도구 버전·SDK라도 캐시를 재사용하지
/// 않는지 고정한다. analyzer 마이너마다 해석 결과가 다를 수 있다(14.6의 include
/// exclude 변경). 분석 대상의 package_config는 dartograph 자신의 analyzer를 담지
/// 않으므로(전역 설치·AOT) 그것만으로는 무효화되지 않는다.
void main() {
  late Directory workspace;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('dartograph-analyzer-id.');
  });
  tearDown(() => workspace.deleteSync(recursive: true));

  test('the JIT identity names the analyzer package this test links', () {
    // 기대값은 이 저장소의 package_config에서 직접 읽는다(제품 코드와 독립).
    final config =
        jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
            as Map<String, Object?>;
    final analyzer = (config['packages']! as List).cast<Map>().singleWhere(
      (package) => package['name'] == 'analyzer',
    );
    final rootUri = analyzer['rootUri'] as String;
    final root = Uri.parse(
      '${p.toUri(p.absolute('.dart_tool')).toString()}/',
    ).resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
    final pubspec =
        loadYaml(File.fromUri(root.resolve('pubspec.yaml')).readAsStringSync())
            as YamlMap;

    expect(
      analyzerPackageIdentity(),
      contains('analyzer ${pubspec['version']}'),
    );
  });

  test('without package resolution the executable fingerprint is used', () {
    final binary = File(p.join(workspace.path, 'dartograph'))
      ..writeAsStringSync('first build');
    String identity() => analyzerPackageIdentity(
      resolvePackageUri: (_) => null,
      executable: binary.path,
    );

    final first = identity();
    expect(first, identity(), reason: 'the same binary keeps its identity');
    binary
      ..writeAsStringSync('a rebuilt binary of another size')
      ..setLastModifiedSync(DateTime(2001));
    expect(identity(), isNot(first));
  });

  test('a different analyzer identity does not reuse cached results', () async {
    final root = Directory(p.join(workspace.path, 'app'))..createSync();
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: app\n');
    File(p.join(root.path, 'bin', 'main.dart'))
      ..parent.createSync()
      ..writeAsStringSync('void main() {}\n');
    final cache = _MemoryCache();
    Future<void> index(String analyzer) => AnalyzerGraphIndex(
      cache: cache,
      userCacheEnvironment: const {},
      analyzerIdentity: analyzer,
    ).index(root.path);

    await index('analyzer 14.5.0');
    final keys = cache.keys;
    await index('analyzer 14.5.0');
    expect(cache.keys, keys, reason: 'the same analyzer reuses its entry');
    cache.reads.clear();
    await index('analyzer 14.7.0');
    // 결과와 dup 토큰 항목이 새 키로 저장된다. 이전 항목을 읽지 않았다.
    expect(cache.keys.difference(keys), isNotEmpty);
    expect(cache.reads.where(keys.contains), isEmpty);
  });
}

/// 실행 사이에 결과를 보관하는 메모리 사실 캐시다.
final class _MemoryCache implements FactCache {
  final _entries = <String, String>{};

  /// 읽은 키 중 항목이 있던 키다(적중).
  final reads = <String>[];

  @override
  Future<String?> read(String key) async {
    final payload = _entries[key];
    if (payload != null) reads.add(key);
    return payload;
  }

  @override
  Future<void> write(String key, String payload) async =>
      _entries[key] = payload;

  /// 지금까지 쓴 키다.
  Set<String> get keys => {..._entries.keys};
}
