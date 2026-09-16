import 'dart:io';

import 'package:dartograph/src/index/dependency_tools.dart';
import 'package:test/test.dart';

void main() {
  test(
    'analysis_options include lists mark lint packages as tool-like',
    () async {
      final package = await Directory.systemTemp.createTemp(
        'dartograph-options-include.',
      );
      addTearDown(() => package.delete(recursive: true));
      await File('${package.path}/pubspec.yaml').writeAsString('''
name: include_fixture
environment:
  sdk: ^3.11.0
dev_dependencies:
  lints: ^6.0.0
''');
      await Directory('${package.path}/lib').create();
      await File('${package.path}/lib/main.dart').writeAsString('''
void entry() {}
''');
      // include는 스칼라뿐 아니라 목록 형태도 허용된다 — lint 세트 패키지가
      // import 없이 tool-like으로 인식되어야 unused-dev-dependency 오탐이
      // 없다.
      await File('${package.path}/analysis_options.yaml').writeAsString('''
include:
  - package:lints/recommended.yaml
''');
      final pubGet = await Process.run(Platform.resolvedExecutable, const [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: package.path);
      expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);

      final detected = detectToolLikeDependencies(package.path, {'lints'});

      expect(detected.toolLike, contains('lints'));
      expect(detected.limitations, isEmpty);
    },
  );
}
