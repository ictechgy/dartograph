import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/core/retention_reason.dart';
import 'package:dartograph/src/export/graph_exporter.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/incremental_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final scope in ['package', 'workspace root', 'workspace member']) {
    test('$scope build.yaml changes keep cached analysis fresh', () async {
      final root = await Directory.systemTemp.createTemp(
        'dartograph-build-cache.',
      );
      final incrementalDirectory = await Directory.systemTemp.createTemp(
        'dartograph-build-incremental.',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => incrementalDirectory.delete(recursive: true));
      final workspace = scope != 'package';
      final member = scope == 'workspace member';
      await File(p.join(root.path, 'pubspec.yaml')).writeAsString('''
name: cache_root
environment:
  sdk: ^3.11.0
${workspace ? 'workspace:\n  - pkgs/builder\n' : ''}
''');
      if (workspace) {
        final directory = Directory(p.join(root.path, 'pkgs', 'builder'));
        await directory.create(recursive: true);
        await File(p.join(directory.path, 'pubspec.yaml')).writeAsString('''
name: cache_builder
resolution: workspace
environment:
  sdk: ^3.11.0
''');
      }
      final package = member ? p.join(root.path, 'pkgs', 'builder') : root.path;
      final name = member ? 'cache_builder' : 'cache_root';
      await Directory(p.join(package, 'lib')).create();
      await File(p.join(package, 'lib', 'builder.dart')).writeAsString('''
Object firstBuilder(Object options) => options;
Object otherBuilder(Object options) => options;
Object unrelated() => Object();
''');
      final pubGet = await Process.run(Platform.resolvedExecutable, const [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: root.path);
      expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
      final cache = _MemoryFactCache();
      final index = AnalyzerGraphIndex(
        cache: cache,
        aggregateWorkspace: workspace,
      );
      final buildFile = File(p.join(package, 'build.yaml'));
      final prefix = 'package:$name/builder.dart::';

      Future<void> check({String? factory, bool malformed = false}) async {
        final warmed = await index.index(root.path);
        final fresh = await AnalyzerGraphIndex(
          cache: _MemoryFactCache(),
          aggregateWorkspace: workspace,
        ).index(root.path);
        // 증분 경로는 매번 보존 루트를 조립한다. 전체 결과 캐시 수정 뒤에도
        // 두 경로의 그래프·보존·한계 계약을 같게 유지한다.
        final incremental = await AnalyzerGraphIndex(
          incremental: IncrementalCache(incrementalDirectory.path),
          aggregateWorkspace: workspace,
        ).index(root.path);
        for (final result in [warmed, fresh, incremental]) {
          expect(
            result.retentionRoots['${prefix}firstBuilder'],
            factory == 'firstBuilder' ? RetentionReason.buildRunner : isNull,
          );
          expect(
            result.retentionRoots['${prefix}otherBuilder'],
            factory == 'otherBuilder' ? RetentionReason.buildRunner : isNull,
          );
          expect(result.retentionRoots['${prefix}unrelated'], isNull);
          expect(
            result.limitationDetails.any(
              (detail) => detail.startsWith('build-yaml-unparsed:'),
            ),
            malformed,
          );
          expect(result.retentionRoots, fresh.retentionRoots);
          expect(result.limitations, fresh.limitations);
          expect(result.limitationDetails, fresh.limitationDetails);
          expect(
            GraphExporter.json(result.graph.snapshot()),
            GraphExporter.json(fresh.graph.snapshot()),
          );
        }
        final writes = cache.writeCount;
        final hit = await index.index(root.path);
        expect(
          cache.writeCount,
          writes,
          reason: 'unchanged input must be a cache hit',
        );
        expect(hit.retentionRoots, fresh.retentionRoots);
        expect(hit.limitationDetails, fresh.limitationDetails);
      }

      String config(String factory) =>
          '''
builders:
  fixture:
    import: 'package:$name/builder.dart'
    builder_factories: ['$factory']
''';

      await check();
      await buildFile.writeAsString(config('firstBuilder'));
      await check(factory: 'firstBuilder');
      final originalModified = (await buildFile.stat()).modified;
      await buildFile.writeAsString(config('otherBuilder'));
      await buildFile.setLastModified(originalModified);
      await check(factory: 'otherBuilder');
      await buildFile.writeAsString('builders: [');
      await check(malformed: true);
      await buildFile.writeAsString(config('firstBuilder'));
      await check(factory: 'firstBuilder');
      await buildFile.delete();
      await check();
    });
  }
}

final class _MemoryFactCache implements FactCache {
  final values = <String, String>{};
  var writeCount = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String payload) async {
    writeCount++;
    values[key] = payload;
  }
}
