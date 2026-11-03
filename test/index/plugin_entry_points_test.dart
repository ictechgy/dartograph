import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

/// pubspec `flutter.plugin` 진입점을 YAML로 읽는지 실제 analyzer로 고정한다.
void main() {
  Future<AnalyzerGraphResult> index(String plugin, String source) async {
    final root = await Directory.systemTemp.createTemp('plugin-entries.');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File('${root.path}/pubspec.yaml').writeAsString('''
name: plugin_fixture
environment:
  sdk: ^3.11.0
flutter:
  plugin:
$plugin
''');
    await File('${root.path}/lib/plugin.dart').writeAsString(source);
    return AnalyzerGraphIndex(userCacheEnvironment: const {}).index(root.path);
  }

  const library = 'project:lib/plugin.dart';

  test(
    'quoted values and trailing comments still name the Dart class',
    () async {
      final result = await index(
        '''
    platforms:
      web:
        pluginClass: "FooWeb" # web implementation
        fileName: plugin.dart
      windows:
        dartPluginClass: 'FooWindows'
        pluginClass: none
''',
        '''
class FooWeb { static void registerWith(Object registrar) {} }
class FooWindows { static void registerWith() {} }
class Unrelated {}
''',
      );
      RetentionReason? rootOf(String name) =>
          result.retentionRoots['$library::$name'];
      expect(rootOf('FooWeb'), RetentionReason.pluginEntryPoint);
      expect(rootOf('FooWeb.registerWith'), RetentionReason.pluginEntryPoint);
      expect(rootOf('FooWindows'), RetentionReason.pluginEntryPoint);
      expect(rootOf('Unrelated'), isNull);
      expect(
        result.limitations,
        isNot(contains(AnalyzerLimitation.unresolvedPluginEntryPoint)),
      );
    },
  );

  test(
    'only a missing Dart-side entry point is an unresolved limitation',
    () async {
      final native = await index('''
    platforms:
      android:
        package: example.plugin
        pluginClass: NativeOnlyPlugin
''', 'class Unrelated {}');
      expect(
        native.limitations,
        isNot(contains(AnalyzerLimitation.unresolvedPluginEntryPoint)),
      );
      final dart = await index('''
    platforms:
      linux:
        dartPluginClass: MissingLinux
''', 'class Unrelated {}');
      expect(
        dart.limitations,
        contains(AnalyzerLimitation.unresolvedPluginEntryPoint),
      );
    },
  );

  test(
    'a native pluginClass that matches a Dart class is still retained',
    () async {
      final result = await index('''
    platforms:
      android:
        package: example.plugin
        pluginClass: SharedName
''', 'class SharedName {}');
      expect(
        result.retentionRoots['$library::SharedName'],
        RetentionReason.pluginEntryPoint,
      );
    },
  );
}
