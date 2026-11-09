import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/core/generated_files.dart';
import 'package:test/test.dart';

void main() {
  test('generator outputs are generated and look-alike names are not', () {
    for (final path in [
      'lib/router.gr.dart',
      'test/api_test.mocks.dart',
      'lib/model.mapper.dart',
      'lib/gen/assets.gen.dart',
      'lib/api.chopper.dart',
      'lib/user.g.dart',
      'lib/proto/user.pbgrpc.dart',
    ]) {
      expect(isGeneratedDartPath(path), isTrue, reason: path);
    }
    // 사람이 쓴 파일과 이름이 겹치기 쉬운 접미사는 생성 파일로 추측하지 않는다.
    for (final path in [
      'lib/app.config.dart',
      'lib/gr.dart',
      'lib/mocks.dart',
      'lib/regen.dart',
    ]) {
      expect(isGeneratedDartPath(path), isFalse, reason: path);
    }
  });

  test(
    'declarations in shared generator outputs are retention roots',
    () async {
      final root = await Directory.systemTemp.createTemp('generated-files.');
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/lib').create();
      final files = {
        'router.gr.dart': 'class RouterOutput {}',
        'model.mapper.dart': 'class MapperOutput {}',
        'app.config.dart': 'class HandWrittenConfig {}',
      };
      for (final entry in files.entries) {
        await File('${root.path}/lib/${entry.key}').writeAsString(entry.value);
      }
      final result = await AnalyzerGraphIndex(
        userCacheEnvironment: const {},
      ).index(root.path);
      RetentionReason? rootOf(String file, String name) =>
          result.retentionRoots['project:lib/$file::$name'];
      expect(rootOf('router.gr.dart', 'RouterOutput'), isNotNull);
      expect(
        rootOf('router.gr.dart', 'RouterOutput'),
        RetentionReason.generatedCode,
      );
      expect(
        rootOf('model.mapper.dart', 'MapperOutput'),
        RetentionReason.generatedCode,
      );
      expect(rootOf('app.config.dart', 'HandWrittenConfig'), isNull);
    },
  );
}
