import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'path activation installs a binary that passes the CLI contract',
    () async {
      final packageConfiguration = File('.dart_tool/package_config.json');
      final configurationBefore = await packageConfiguration.readAsBytes();
      final result = await Process.run('bash', [
        'tool/verify-global-activation.sh',
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('Global activation contract passed'));
      expect(await packageConfiguration.readAsBytes(), configurationBefore);
    },
    tags: 'global_activation',
    // 100개 이상의 설치 CLI 호출은 공유 CI에서 각각 SDK 시작 비용을 낸다.
    // 기능·종료 코드 검사는 모두 유지하고 전체 설치 계약에 별도 예산을 둔다.
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
