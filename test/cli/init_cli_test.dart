import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/core/retention_reason.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('init writes dartograph.yaml template and succeeds', () async {
    final temporary = await Directory.systemTemp.createTemp('dartograph-init-');
    addTearDown(() => temporary.delete(recursive: true));

    final output = StringBuffer();
    final status = await runDartograph([
      'init',
      temporary.path,
    ], output: output);

    expect(status, ExitStatus.success.code);
    expect(output.toString(), contains('Wrote '));
    expect(output.toString(), contains('dartograph.yaml'));

    final configFile = File('${temporary.path}/dartograph.yaml');
    expect(configFile.existsSync(), isTrue);

    final content = configFile.readAsStringSync();
    expect(content, contains('entry_points:'));
    expect(loadYaml(content), isNull);
  });

  test(
    'generated template with uncommented entry_points narrows retention roots',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dartograph-init-pkg-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      await File('${temporary.path}/pubspec.yaml').writeAsString('''
name: init_pkg
environment:
  sdk: '>=3.11.0 <4.0.0'
''');
      final libDir = Directory('${temporary.path}/lib')..createSync();
      await File('${libDir.path}/main.dart').writeAsString('void main() {}');
      final binDir = Directory('${temporary.path}/bin')..createSync();
      await File('${binDir.path}/tool.dart').writeAsString('void main() {}');

      final output = StringBuffer();
      final status = await runDartograph([
        'init',
        temporary.path,
      ], output: output);
      expect(status, ExitStatus.success.code);

      final configFile = File('${temporary.path}/dartograph.yaml');
      final content = configFile.readAsStringSync();
      final uncommented = content
          .replaceAll('# entry_points:', 'entry_points:')
          .replaceAll('#   - lib/main.dart', '  - lib/main.dart');
      await configFile.writeAsString(uncommented);

      final yamlDoc = loadYaml(uncommented);
      expect(yamlDoc, isA<YamlMap>());
      expect(yamlDoc['entry_points'], ['lib/main.dart']);

      final result = await AnalyzerGraphIndex().index(temporary.path);
      final mainRoots = result.retentionRoots.entries
          .where((entry) => entry.value == RetentionReason.mainEntryPoint)
          .map((entry) => entry.key)
          .toSet();

      expect(mainRoots, contains('project:lib/main.dart::main'));
      expect(mainRoots, isNot(contains('project:bin/tool.dart::main')));
      expect(
        result.limitationDetails,
        contains(
          'entry-points: main retention roots narrowed to 1 declared build target(s)',
        ),
      );
    },
  );

  test(
    'init fails with usage 64 when dartograph.yaml exists without --force',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dartograph-init-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      final configFile = File('${temporary.path}/dartograph.yaml');
      await configFile.writeAsString('existing content');

      final error = StringBuffer();
      final status = await runDartograph([
        'init',
        temporary.path,
      ], error: error);

      expect(status, ExitStatus.usage.code);
      expect(
        error.toString(),
        contains('already exists. Pass --force to overwrite it.'),
      );
      expect(configFile.readAsStringSync(), 'existing content');
    },
  );

  test(
    'init overwrites existing dartograph.yaml when --force is passed',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dartograph-init-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      final configFile = File('${temporary.path}/dartograph.yaml');
      await configFile.writeAsString('existing content');

      final output = StringBuffer();
      final status = await runDartograph([
        'init',
        '--force',
        temporary.path,
      ], output: output);

      expect(status, ExitStatus.success.code);
      expect(output.toString(), contains('Wrote '));
      expect(
        configFile.readAsStringSync(),
        contains('Dartograph configuration'),
      );
      expect(
        configFile.readAsStringSync(),
        isNot(contains('existing content')),
      );
    },
  );

  test('init reports failure 2 when directory does not exist', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'dartograph-init-missing-',
    );
    final missingPath = '${temporary.path}/missing';

    final error = StringBuffer();
    final status = await runDartograph(['init', missingPath], error: error);

    expect(status, ExitStatus.failure.code);
    expect(
      error.toString(),
      contains('Init failed: target directory does not exist: $missingPath'),
    );
  });

  test('init reports failure 2 when target path is a file', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'dartograph-init-file-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final filePath = '${temporary.path}/regular-file';
    await File(filePath).writeAsString('file content');

    final error = StringBuffer();
    final status = await runDartograph(['init', filePath], error: error);

    expect(status, ExitStatus.failure.code);
    expect(
      error.toString(),
      contains('Init failed: target path is not a directory: $filePath'),
    );
  });

  test('init reports usage 64 for invalid arguments', () async {
    final error1 = StringBuffer();
    final status1 = await runDartograph([
      'init',
      '--force',
      '--force',
    ], error: error1);
    expect(status1, ExitStatus.usage.code);
    expect(error1.toString(), contains('Usage: dartograph'));

    final error2 = StringBuffer();
    final status2 = await runDartograph(['init', '--unknown'], error: error2);
    expect(status2, ExitStatus.usage.code);
    expect(error2.toString(), contains('Usage: dartograph'));

    final error3 = StringBuffer();
    final status3 = await runDartograph([
      'init',
      'dir1',
      'dir2',
    ], error: error3);
    expect(status3, ExitStatus.usage.code);
    expect(error3.toString(), contains('Usage: dartograph'));
  });
}
