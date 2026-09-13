import 'dart:io';

import 'package:dartograph/src/core/config_source.dart';
import 'package:test/test.dart';

void main() {
  group('config size cap', () {
    late Directory temporary;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('dartograph-config-');
    });

    tearDown(() => temporary.delete(recursive: true));

    test('reads content under the limit via sync and async paths', () async {
      final file = File('${temporary.path}/pubspec.yaml')
        ..writeAsStringSync('name: sample\n');

      expect(readConfigurationSync(file), 'name: sample\n');
      expect(await readConfiguration(file), 'name: sample\n');
    });

    test('fails closed with a static message over the limit', () async {
      // 1 MiB를 넘는 문서를 만든다.
      final oversized = File('${temporary.path}/dartograph.yaml')
        ..writeAsStringSync('# ${'x' * configurationSizeLimit}\n');

      expect(
        () => readConfigurationSync(oversized),
        throwsA(
          isA<FormatException>().having(
            (exception) => exception.message,
            'message',
            isNot(contains(oversized.path)),
          ),
        ),
      );
      await expectLater(
        readConfiguration(oversized),
        throwsA(
          isA<FormatException>().having(
            (exception) => exception.message,
            'message',
            isNot(contains(oversized.path)),
          ),
        ),
      );
      // 파일은 그대로다 — 읽기를 포기할 뿐 수정하지 않는다.
      expect(oversized.existsSync(), isTrue);
    });

    test('exactly-at-limit file passes, one byte over fails', () async {
      final exact = File('${temporary.path}/exact.yaml')
        ..writeAsStringSync('x' * configurationSizeLimit);
      expect(readConfigurationSync(exact), hasLength(configurationSizeLimit));

      final over = File('${temporary.path}/over.yaml')
        ..writeAsStringSync('x' * (configurationSizeLimit + 1));
      expect(
        () => readConfigurationSync(over),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
