import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/core/retention_reason.dart';
import 'package:dartograph/src/export/graph_exporter.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'file fact cache round-trips payloads and rejects unsafe keys',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'dartograph-file-cache.',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = FileFactCache(directory);
      final key = 'a' * 64;

      expect(await cache.read(key), isNull);
      await cache.write(key, '{"value":1}');
      expect(await cache.read(key), '{"value":1}');
      await cache.write(key, '{"value":2}');
      expect(await cache.read(key), '{"value":2}');
      await expectLater(cache.read('../outside'), throwsArgumentError);
      await expectLater(cache.write('../outside', 'bad'), throwsArgumentError);
    },
  );

  test('default cache location is outside the analyzed project', () async {
    final root = await Directory.systemTemp.createTemp(
      'dartograph-untrusted-project.',
    );
    addTearDown(() => root.delete(recursive: true));
    final cacheBase = p.join(root.parent.path, 'trusted-user-cache');

    final directory = defaultAnalyzerCacheDirectory(
      await root.resolveSymbolicLinks(),
      environment: {
        'HOME': cacheBase,
        'LOCALAPPDATA': cacheBase,
        'XDG_CACHE_HOME': cacheBase,
      },
    );

    expect(directory, isNotNull);
    expect(p.isWithin(root.path, directory!.path), isFalse);
    expect(p.basename(directory.path), matches(RegExp(r'^[a-f0-9]{64}$')));
  });

  test(
    'analyzer cache reuses, invalidates, and repairs facts safely',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dartograph-analysis-cache.',
      );
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/pubspec.yaml').writeAsString('''
name: cache_fixture
environment:
  sdk: ^3.11.0
''');
      await Directory('${root.path}/lib').create();
      final source = File('${root.path}/lib/cache_fixture.dart');
      await source.writeAsString('class First {}\n');
      final cache = _MemoryFactCache();
      final index = AnalyzerGraphIndex(cache: cache);

      final first = await index.index(root.path);
      final second = await index.index(root.path);
      expect(cache.readCount, 2);
      expect(cache.writeCount, 1);
      expect(
        GraphExporter.json(second.graph.snapshot()),
        GraphExporter.json(first.graph.snapshot()),
      );

      await source.writeAsString('class First {}\nclass Second {}\n');
      final changed = await index.index(root.path);
      expect(cache.writeCount, 2);
      expect(
        changed.graph.nodes.keys,
        contains('project:lib/cache_fixture.dart::Second'),
      );

      final changedKey = cache.values.keys.last;
      final typeCorrupt = jsonDecode(cache.values[changedKey]!) as Map;
      typeCorrupt['limitationDetails'] = [1];
      cache.values[changedKey] = jsonEncode(typeCorrupt);
      final eagerlyRepaired = await index.index(root.path);
      expect(cache.writeCount, 3);
      expect(eagerlyRepaired.limitationDetails, everyElement(isA<String>()));

      for (final key in cache.values.keys.toList()) {
        cache.values[key] = '{';
      }
      final repaired = await index.index(root.path);
      expect(cache.writeCount, 4);
      expect(
        repaired.graph.nodes.keys,
        contains('project:lib/cache_fixture.dart::Second'),
      );

      final uncached = await AnalyzerGraphIndex(
        cache: _FailingFactCache(),
      ).index(root.path);
      expect(
        GraphExporter.json(uncached.graph.snapshot()),
        GraphExporter.json(repaired.graph.snapshot()),
      );
    },
  );

  test('path dependency contents invalidate analyzer facts', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'dartograph-path-cache.',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final dependency = Directory('${workspace.path}/dependency');
    final application = Directory('${workspace.path}/application');
    await Directory('${dependency.path}/lib').create(recursive: true);
    await Directory('${application.path}/lib').create(recursive: true);
    await File('${dependency.path}/pubspec.yaml').writeAsString('''
name: dependency
environment:
  sdk: ^3.11.0
''');
    final dependencySource = File('${dependency.path}/lib/dependency.dart');
    await dependencySource.writeAsString('''
class Framework {
  void callback() {}
}
''');
    await File('${application.path}/pubspec.yaml').writeAsString('''
name: application
environment:
  sdk: ^3.11.0
dependencies:
  dependency:
    path: ../dependency
''');
    await File('${application.path}/lib/main.dart').writeAsString('''
import 'package:dependency/dependency.dart';
class Application extends Framework {
  void callback() {}
}
''');
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: application.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
    final cache = _MemoryFactCache();
    final index = AnalyzerGraphIndex(cache: cache);
    final callbackId = 'package:application/main.dart::Application.callback';

    final first = await index.index(application.path);
    expect(first.retentionRoots[callbackId], RetentionReason.overrideContract);
    await dependencySource.writeAsString('''
class Framework {
  void renamed() {}
}
''');
    final second = await index.index(application.path);

    expect(second.retentionRoots[callbackId], isNull);
    expect(cache.writeCount, 2);
  });

  test('nested example dependencies invalidate analyzer facts', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'dartograph-nested-package-cache.',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final dependency = Directory('${workspace.path}/dependency');
    final application = Directory('${workspace.path}/application');
    final example = Directory('${application.path}/example');
    await Directory('${dependency.path}/lib').create(recursive: true);
    await Directory('${application.path}/lib').create(recursive: true);
    await Directory('${example.path}/lib').create(recursive: true);
    await File('${dependency.path}/pubspec.yaml').writeAsString('''
name: nested_dependency
environment:
  sdk: ^3.11.0
''');
    final dependencySource = File(
      '${dependency.path}/lib/nested_dependency.dart',
    );
    await dependencySource.writeAsString('''
class Framework {
  void callback() {}
}
''');
    await File('${application.path}/pubspec.yaml').writeAsString('''
name: application
environment:
  sdk: ^3.11.0
''');
    await File(
      '${application.path}/lib/application.dart',
    ).writeAsString('class Application {}\n');
    await File('${example.path}/pubspec.yaml').writeAsString('''
name: nested_example
environment:
  sdk: ^3.11.0
dependencies:
  nested_dependency:
    path: ../../dependency
''');
    await File('${example.path}/lib/main.dart').writeAsString('''
import 'package:nested_dependency/nested_dependency.dart';
class ExampleApplication extends Framework {
  void callback() {}
}
''');
    for (final package in [application, example]) {
      final pubGet = await Process.run(Platform.resolvedExecutable, const [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: package.path);
      expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
    }
    final cache = _MemoryFactCache();
    final index = AnalyzerGraphIndex(cache: cache);
    const callbackId =
        'package:nested_example/main.dart::ExampleApplication.callback';

    final first = await index.index(application.path);
    expect(first.retentionRoots[callbackId], RetentionReason.overrideContract);
    await dependencySource.writeAsString('''
class Framework {
  void renamed() {}
}
''');
    final second = await index.index(application.path);

    expect(second.retentionRoots[callbackId], isNull);
    expect(cache.writeCount, 2);
  });
}

final class _FailingFactCache implements FactCache {
  @override
  Future<String?> read(String key) => throw FileSystemException('unreadable');

  @override
  Future<void> write(String key, String payload) =>
      throw FileSystemException('unwritable');
}

final class _MemoryFactCache implements FactCache {
  final values = <String, String>{};
  var readCount = 0;
  var writeCount = 0;

  @override
  Future<String?> read(String key) async {
    readCount++;
    return values[key];
  }

  @override
  Future<void> write(String key, String payload) async {
    writeCount++;
    values[key] = payload;
  }
}
