import 'dart:io';

import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

/// 대표 라이브러리 밖 공개 라이브러리를 한계로 세는지 실제 analyzer로 고정한다.
void main() {
  Future<List<String>> limitationsFor({required String publishTo}) async {
    final root = await Directory.systemTemp.createTemp('public-libraries.');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib/src').create(recursive: true);
    await File('${root.path}/pubspec.yaml').writeAsString('''
name: widgets
$publishTo
environment:
  sdk: ^3.11.0
''');
    final files = {
      'widgets.dart': "export 'reexported.dart'; class Widget {}",
      // 대표 라이브러리가 다시 export하므로 이미 공개 API로 보존된다.
      'reexported.dart': 'class Reexported {}',
      // 소비자가 `package:widgets/testing.dart`로만 쓰는 공개 라이브러리다.
      'testing.dart': 'class FakeWidget {} class _Private {}',
      'src/impl.dart': 'class Impl {}',
    };
    for (final entry in files.entries) {
      await File('${root.path}/lib/${entry.key}').writeAsString(entry.value);
    }
    final result = await AnalyzerGraphIndex(
      userCacheEnvironment: const {},
    ).index(root.path);
    return result.limitationDetails;
  }

  test(
    'a publishable package counts public libraries outside its entry',
    () async {
      final details = await limitationsFor(publishTo: '');
      final public = details.where(
        (line) => line.startsWith('public-libraries:'),
      );
      expect(public, hasLength(1));
      expect(public.single, contains('lib/testing.dart'));
      expect(public.single, isNot(contains('reexported.dart')));
      expect(public.single, isNot(contains('lib/src/impl.dart')));
      expect(public.single, contains('lib/widgets.dart'));
    },
  );

  test(
    'an application that is not published is not told about consumers',
    () async {
      final details = await limitationsFor(publishTo: "publish_to: 'none'");
      expect(
        details.where((line) => line.startsWith('public-libraries:')),
        isEmpty,
      );
    },
  );
}
