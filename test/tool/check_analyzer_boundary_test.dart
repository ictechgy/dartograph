import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('analyzer boundary check fails when its scanner fails', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'dartograph-boundary-test.',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final fakeRipgrep = File('${temporaryDirectory.path}/rg');
    await fakeRipgrep.writeAsString('#!/usr/bin/env bash\nexit 2\n');
    final chmod = await Process.run('chmod', ['+x', fakeRipgrep.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr as String);

    final result = await Process.run(
      'bash',
      ['tool/check-analyzer-boundary.sh'],
      environment: {
        ...Platform.environment,
        'PATH': '${temporaryDirectory.path}:/usr/bin:/bin',
      },
    );

    expect(result.exitCode, 2);
    expect(result.stderr, contains('Analyzer boundary scan failed'));
  });
}
