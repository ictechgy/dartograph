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
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
