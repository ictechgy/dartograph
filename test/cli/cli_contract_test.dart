import 'dart:io';

import 'package:test/test.dart';

void main() {
  final dart = Platform.resolvedExecutable;

  test('help is successful', () async {
    final result = await Process.run(dart, ['run', 'dartograph', '--help']);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('Usage: dartograph'));
  });

  test('no arguments print help successfully', () async {
    final result = await Process.run(dart, ['run', 'dartograph']);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('Usage: dartograph'));
  });

  test('findings return exit code 1', () async {
    final result = await Process.run(dart, [
      'run',
      'dartograph',
      'dead',
      '--format',
      'json',
      'fixtures/false_positive_corpus',
    ]);

    expect(result.exitCode, 1);
  });

  test('analysis failure returns exit code 2', () async {
    final result = await Process.run(dart, [
      'run',
      'dartograph',
      'dead',
      '--format',
      'json',
      'fixtures/does-not-exist',
    ]);

    expect(result.exitCode, 2);
    expect(result.stderr, contains('Analysis failed:'));
  });

  test('invalid usage returns exit code 64', () async {
    final result = await Process.run(dart, ['run', 'dartograph', 'unknown']);

    expect(result.exitCode, 64);
    expect(result.stderr, contains('Usage: dartograph'));
  });
}
