import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  setUpAll(() async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
      '--directory',
      'fixture',
    ], workingDirectory: Directory.current.path);
    expect(result.exitCode, 0, reason: result.stderr as String);
  });

  test(
    'reports declarations, references, part ownership, and generated files',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/probe.dart',
        'fixture',
      ], workingDirectory: Directory.current.path);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final report =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(report['files'], 8);
      expect(report['declarations'], 10);
      expect(report['references'], 6);
      expect(report['diagnostics'], 0);
      expect(report['declarationIds'], [
        'package:phase0_fixture/main.dart::<unnamed-extension@22>',
        'package:phase0_fixture/main.dart::<unnamed-extension@22>.markerOne',
        'package:phase0_fixture/main.dart::<unnamed-extension@69>',
        'package:phase0_fixture/main.dart::<unnamed-extension@69>.markerTwo',
        'package:phase0_fixture/main.dart::main',
        'package:phase0_fixture/part_host.dart::generatedHelper',
        'package:phase0_fixture/part_host.dart::greet',
        'package:phase0_fixture/platform_io.dart::platformName',
        'package:phase0_fixture/platform_stub.dart::platformName',
        'project:test/library_test.dart::testEntry',
      ]);
      expect(report['referenceIds'], [
        'package:phase0_fixture/main.dart::<unnamed-extension@22>.markerOne',
        'package:phase0_fixture/main.dart::<unnamed-extension@69>.markerTwo',
        'package:phase0_fixture/part_host.dart::generatedHelper',
        'package:phase0_fixture/part_host.dart::greet',
        'package:phase0_fixture/part_host.dart::greet',
        'package:phase0_fixture/platform_stub.dart::platformName',
      ]);
      expect(report['generatedFiles'], [
        {
          'path': 'lib/part_host.g.dart',
          'libraryUri': 'package:phase0_fixture/part_host.dart',
          'generated': true,
        },
      ]);
    },
  );

  test(
    'returns a tool failure without exposing paths for an unreadable root',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/probe.dart',
        'fixture/does-not-exist',
      ], workingDirectory: Directory.current.path);

      expect(result.exitCode, 2);
      expect(
        result.stderr,
        contains('Package root does not exist or cannot be read.'),
      );
      expect(result.stderr, isNot(contains('does-not-exist')));
    },
  );
}
