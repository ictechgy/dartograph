import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

void main() {
  test(
    'unselected conditional libraries retain their dependency closure only',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conditional-retention.',
      );
      addTearDown(() => directory.delete(recursive: true));
      await Directory('${directory.path}/lib').create();
      await File('${directory.path}/pubspec.yaml').writeAsString('''
name: conditional_fixture
environment:
  sdk: ^3.11.0
''');
      final files = {
        'main.dart': "import 'platform.dart'; void main() { platform(); }",
        'platform.dart':
            "export 'stub.dart' if (dart.library.io) 'package:conditional_fixture/io.dart' if (dart.library.html) 'web.dart';",
        'stub.dart': 'void platform() {} void selectedUnused() {}',
        'io.dart':
            "import 'helper.dart'; void platform() { help(); } void ioUnused() {}",
        'web.dart': "import 'helper.dart'; void platform() { help(); }",
        'helper.dart':
            "import 'cycle.dart'; void help() {} void helperUnused() {}",
        'cycle.dart': "import 'helper.dart'; void cycle() { help(); }",
        'unrelated.dart': 'void unrelatedUnused() {}',
      };
      for (final entry in files.entries) {
        await File(
          '${directory.path}/lib/${entry.key}',
        ).writeAsString(entry.value);
      }
      final pubGet = await Process.run(Platform.resolvedExecutable, [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: directory.path);
      expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
      final result = await AnalyzerGraphIndex().index(directory.path);
      final retained = result.retentionRoots.entries
          .where((entry) => entry.value.name == 'conditionalConfiguration')
          .map((entry) => entry.key);
      expect(
        retained,
        containsAll([
          'package:conditional_fixture/io.dart::platform',
          'package:conditional_fixture/web.dart::platform',
          'package:conditional_fixture/helper.dart::help',
          'package:conditional_fixture/helper.dart::helperUnused',
          'package:conditional_fixture/cycle.dart::cycle',
        ]),
      );
      expect(
        retained,
        isNot(
          contains('package:conditional_fixture/stub.dart::selectedUnused'),
        ),
      );
      expect(
        retained,
        isNot(
          contains(
            'package:conditional_fixture/unrelated.dart::unrelatedUnused',
          ),
        ),
      );
      expect(
        result.graph
            .snapshot()
            .edges
            .where(
              (edge) =>
                  edge.sourceId ==
                      'package:conditional_fixture/platform.dart' &&
                  edge.kind == EdgeKind.export,
            )
            .map((edge) => edge.targetId),
        ['package:conditional_fixture/stub.dart'],
      );
    },
  );
}
