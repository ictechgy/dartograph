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
      expect(await readConfiguration(exact), hasLength(configurationSizeLimit));

      final over = File('${temporary.path}/over.yaml')
        ..writeAsStringSync('x' * (configurationSizeLimit + 1));
      expect(
        () => readConfigurationSync(over),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        readConfiguration(over),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'device and FIFO links fail closed before any read',
      () async {
        // 문자 장치는 길이를 0으로 보고해 길이 상한을 통과한다. /dev/null은
        // 곧바로 EOF라 안전한 대역이다(/dev/zero라면 EOF 없이 메모리를 채운다).
        final device = Link('${temporary.path}/dartograph.yaml')
          ..createSync('/dev/null');
        Matcher staticFailure(String path) => throwsA(
          isA<FormatException>().having(
            (exception) => exception.message,
            'message',
            isNot(contains(path)),
          ),
        );
        expect(
          () => readConfigurationSync(File(device.path)),
          staticFailure(device.path),
        );
        await expectLater(
          readConfiguration(File(device.path)),
          staticFailure(device.path),
        );

        // FIFO는 쓰는 쪽이 없으면 열기에서 영구 대기한다. 비동기 경로를 먼저
        // 확인해, 수정 전 코드라면 동기 호출이 isolate를 막기 전에 테스트
        // timeout으로 실패하게 한다.
        final fifo = '${temporary.path}/pipe';
        final mkfifo = await Process.run('mkfifo', [fifo]);
        expect(mkfifo.exitCode, 0, reason: mkfifo.stderr as String);
        final link = Link('${temporary.path}/layers.yaml')..createSync(fifo);
        await expectLater(
          readConfiguration(File(link.path)),
          staticFailure(link.path),
        );
        expect(
          () => readConfigurationSync(File(link.path)),
          staticFailure(link.path),
        );
        expect(() => readConfigurationSync(File(fifo)), staticFailure(fifo));
      },
      skip: Platform.isWindows,
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'missing, directory and undecodable inputs keep their failures',
      () async {
        // 호출자는 FileSystemException을 읽기 실패로, FormatException을 설정
        // 오류로 나눠 진단한다. 경계 읽기로 바꿔도 그 분류는 그대로다.
        final missing = File('${temporary.path}/missing.yaml');
        final directory = Directory('${temporary.path}/folder.yaml')
          ..createSync();
        final undecodable = File('${temporary.path}/latin1.yaml')
          ..writeAsBytesSync([0xFF, 0xFE, 0x41]);
        for (final file in [missing, File(directory.path), undecodable]) {
          expect(
            () => readConfigurationSync(file),
            throwsA(isA<FileSystemException>()),
            reason: file.path,
          );
          await expectLater(
            readConfiguration(file),
            throwsA(isA<FileSystemException>()),
            reason: file.path,
          );
        }
      },
    );
  });
}
