import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

void main() {
  test(
    'source_packages opt-in connects a local package declaration and caller',
    () async {
      final package = await _makePackage();
      addTearDown(() => package.delete(recursive: true));

      final defaultResult = await AnalyzerGraphIndex().index(package.path);
      expect(
        defaultResult.graph.nodes.keys,
        isNot(contains('package:local_bridge/bridge.dart::BridgeApi.getBool')),
      );

      await File('${package.path}/dartograph.yaml').writeAsString('''
source_packages:
  - vendor/local_bridge
''');
      final configured = await AnalyzerGraphIndex().index(package.path);
      const target = 'package:local_bridge/bridge.dart::BridgeApi.getBool';
      expect(configured.graph.nodes.keys, contains(target));
      expect(
        configured.graph.edges.any(
          (edge) => edge.targetId == target && edge.sourceId.endsWith('::main'),
        ),
        isTrue,
        reason: 'the app caller must retain the local package element identity',
      );
    },
  );

  test(
    'source package configuration rejects malformed or unsafe roots',
    () async {
      for (final config in const [
        'source_packages: []\n',
        'source_packages:\n  - /tmp/outside\n',
        'source_packages:\n  - ../outside\n',
        'source_packages:\n  - build/generated\n',
        'source_packages:\n  - vendor/no_pubspec\n',
        'source_packages:\n  - 42\n',
      ]) {
        final package = await _makePackage();
        addTearDown(() => package.delete(recursive: true));
        await Directory(
          '${package.path}/vendor/no_pubspec',
        ).create(recursive: true);
        await File('${package.path}/dartograph.yaml').writeAsString(config);
        await expectLater(
          AnalyzerGraphIndex().index(package.path),
          throwsA(isA<FormatException>()),
          reason: config,
        );
      }
    },
  );

  test(
    'source package configuration rejects symlinks and duplicates',
    () async {
      final package = await _makePackage();
      addTearDown(() => package.delete(recursive: true));
      await Link(
        '${package.path}/vendor/link',
      ).create('${package.path}/vendor/local_bridge');
      await File('${package.path}/dartograph.yaml').writeAsString('''
source_packages:
  - vendor/local_bridge
  - vendor/link
''');
      await expectLater(
        AnalyzerGraphIndex().index(package.path),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('source package configuration invalidates the analysis cache', () async {
    final package = await _makePackage();
    addTearDown(() => package.delete(recursive: true));
    final cache = _MemoryCache();
    final index = AnalyzerGraphIndex(cache: cache);
    final before = await index.index(package.path);
    expect(
      before.graph.nodes.keys,
      isNot(contains('package:local_bridge/bridge.dart::BridgeApi.getBool')),
    );
    await File('${package.path}/dartograph.yaml').writeAsString('''
source_packages:
  - vendor/local_bridge
''');
    final after = await index.index(package.path);
    expect(
      after.graph.nodes.keys,
      contains('package:local_bridge/bridge.dart::BridgeApi.getBool'),
    );
    expect(cache.reads, greaterThanOrEqualTo(2));
    expect(cache.writes, greaterThanOrEqualTo(2));
  });

  test(
    'source_packages retains a generated Pigeon-style package caller',
    () async {
      final package = await _makePigeonPackage();
      addTearDown(() => package.delete(recursive: true));
      await File('${package.path}/dartograph.yaml').writeAsString('''
source_packages:
  - vendor/shared_preferences_android
''');
      final result = await AnalyzerGraphIndex().index(package.path);
      const target =
          'package:shared_preferences_android/src/messages_async.dart::SharedPreferencesAsyncApi.getBool';
      expect(result.graph.nodes.keys, contains(target));
      expect(
        result.graph.edges.any(
          (edge) => edge.targetId == target && edge.sourceId.endsWith('::main'),
        ),
        isTrue,
      );
    },
  );
}

Future<Directory> _makePackage() async {
  final package = await Directory.systemTemp.createTemp(
    'dartograph-source-packages.',
  );
  await File('${package.path}/pubspec.yaml').writeAsString('''
name: source_package_fixture
environment:
  sdk: ^3.11.0
dependencies:
  local_bridge:
    path: vendor/local_bridge
''');
  await Directory('${package.path}/lib').create(recursive: true);
  await File('${package.path}/lib/main.dart').writeAsString('''
import 'package:local_bridge/bridge.dart';

void main() => BridgeApi().getBool('fixture');
''');
  await Directory(
    '${package.path}/vendor/local_bridge/lib',
  ).create(recursive: true);
  await File('${package.path}/vendor/local_bridge/pubspec.yaml').writeAsString(
    '''
name: local_bridge
environment:
  sdk: ^3.11.0
''',
  );
  await File(
    '${package.path}/vendor/local_bridge/lib/bridge.dart',
  ).writeAsString('''
class BridgeApi {
  bool getBool(String key) => key == 'fixture';
}
''');
  final result = await Process.run(Platform.resolvedExecutable, const [
    'pub',
    'get',
    '--offline',
  ], workingDirectory: package.path);
  expect(result.exitCode, 0, reason: result.stderr as String);
  return package;
}

Future<Directory> _makePigeonPackage() async {
  final package = await Directory.systemTemp.createTemp(
    'dartograph-pigeon-source-package.',
  );
  await File('${package.path}/pubspec.yaml').writeAsString('''
name: pigeon_app_fixture
environment:
  sdk: ^3.11.0
dependencies:
  shared_preferences_android:
    path: vendor/shared_preferences_android
''');
  await Directory('${package.path}/lib').create(recursive: true);
  await File('${package.path}/lib/main.dart').writeAsString('''
import 'package:shared_preferences_android/src/messages_async.dart';

void main() => SharedPreferencesAsyncApi().getBool('missing');
''');
  await Directory(
    '${package.path}/vendor/shared_preferences_android/lib/src',
  ).create(recursive: true);
  await File(
    '${package.path}/vendor/shared_preferences_android/pubspec.yaml',
  ).writeAsString('''
name: shared_preferences_android
environment:
  sdk: ^3.11.0
''');
  await File(
    '${package.path}/vendor/shared_preferences_android/lib/src/messages_async.dart',
  ).writeAsString('''
class SharedPreferencesAsyncApi {
  bool? getBool(String key) => null;
}
''');
  final result = await Process.run(Platform.resolvedExecutable, const [
    'pub',
    'get',
    '--offline',
  ], workingDirectory: package.path);
  expect(result.exitCode, 0, reason: result.stderr as String);
  return package;
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
