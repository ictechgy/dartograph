import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'the released package has no unreachable product declarations',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'dartograph',
        'dead',
        '--format',
        'json',
        '.',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final document =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(document['findings'], isEmpty);
    },
  );
}
