import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

/// [path]에 FIFO를 만들고, 쓰는 쪽이 1초씩 열었다 닫기를 되풀이하게 한다.
///
/// 쓰는 쪽이 없는 FIFO는 여는 순간 영구 대기한다. analyzer처럼 동기로 읽는
/// 코드가 그렇게 막히면 isolate가 멈춰 테스트 timeout도 발동하지 않는다. 쓰는
/// 쪽을 붙여 두면 거부하지 않는(회귀한) 코드도 1초 안에 빈 내용을 읽고 끝나므로,
/// 회귀가 멈춤이 아니라 시간 안의 실패로 드러난다. FIFO를 열지 않는 코드에서는
/// 쓰는 쪽이 열기에서 기다리다 테스트 정리 때 끝난다.
///
/// 열기는 셸 자신이 `exec 3>`로 한다. `cmd > fifo`처럼 쓰면 fork한 자식이 열기에서
/// 막혀, 정리 때 부모 셸만 끝나고 그 자식이 고아로 남는다.
Future<String> fifoWithRepeatingWriter(String path) async {
  final mkfifo = await Process.run('mkfifo', [path]);
  expect(mkfifo.exitCode, 0, reason: mkfifo.stderr as String);
  final writer = await Process.start('sh', [
    '-c',
    r'while :; do exec 3>"$1"; sleep 1; exec 3>&-; done',
    'sh',
    path,
  ]);
  addTearDown(() => writer.kill());
  return path;
}

/// [path]에 [limit]바이트를 1바이트 넘는 공백 Dart 소스를 쓴다(끝은 개행).
///
/// 읽기 상한 회귀 테스트의 입력이다. 희소 파일로 길이만 키우지 않는 이유가
/// 있다. 비어 있는 영역은 NUL로 읽히고, Dart 스캐너는 NUL마다 오류 토큰을 만든다.
/// 그래서 상한 없이 읽는(회귀한) 코드는 수천만 개의 오류를 쌓으며 몇 분 동안
/// 멈춘다. 공백은 토큰이 없어 회귀한 코드도 몇 초 안에 끝나고, 테스트는 멈춤이
/// 아니라 기대한 거부가 없다는 실패로 드러난다.
Future<void> writeOversizedSource(String path, int limit) async {
  const chunkSize = 1024 * 1024;
  final spaces = Uint8List(chunkSize)..fillRange(0, chunkSize, 0x20);
  final handle = await File(path).open(mode: FileMode.write);
  try {
    for (var written = 0; written < limit; written += chunkSize) {
      final remaining = limit - written;
      await handle.writeFrom(
        spaces,
        0,
        remaining < chunkSize ? remaining : null,
      );
    }
    await handle.writeByte(0x0a);
  } finally {
    await handle.close();
  }
}
