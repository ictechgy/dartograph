import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  test('no arguments print the exit contract and succeed', () async {
    final output = StringBuffer();

    final status = await runDartograph(const [], output: output);

    expect(status, ExitStatus.success.code);
    expect(output.toString(), contains('Exit codes:'));
    expect(
      output.toString(),
      contains(
        '1   dead findings, or cycles/rules/metrics findings with --strict',
      ),
    );
  });

  test('short help prints the exit contract and succeeds', () async {
    final output = StringBuffer();

    final status = await runDartograph(const ['-h'], output: output);

    expect(status, ExitStatus.success.code);
    expect(output.toString(), contains('Exit codes:'));
  });

  test('version prints a version and succeeds', () async {
    final output = StringBuffer();

    final status = await runDartograph(const ['--version'], output: output);

    expect(status, ExitStatus.success.code);
    expect(output.toString(), 'dartograph 0.2.0\n');
  });

  test(
    'unknown command reports usage without claiming analysis results',
    () async {
      final error = StringBuffer();

      final status = await runDartograph(const ['unknown'], error: error);

      expect(status, ExitStatus.usage.code);
      expect(error.toString(), contains('Usage: dartograph'));
      expect(error.toString(), isNot(contains('delete')));
    },
  );

  test('internal contract probes are not public commands', () async {
    expect(
      await runDartograph(const ['_findings'], error: StringBuffer()),
      ExitStatus.usage.code,
    );
    expect(
      await runDartograph(const ['_failure'], error: StringBuffer()),
      ExitStatus.usage.code,
    );
  });

  test('skill install rejects an option-shaped destination', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'dartograph-skill-usage.',
    );
    final previous = Directory.current;
    try {
      Directory.current = temporary;
      expect(
        await runDartograph(const [
          'skill',
          '--install',
          '--force',
        ], error: StringBuffer()),
        ExitStatus.usage.code,
      );
      expect(Directory('${temporary.path}/--force').existsSync(), isFalse);
    } finally {
      Directory.current = previous;
      await temporary.delete(recursive: true);
    }
  });

  test('option-shaped positional paths are usage errors', () async {
    final package = await Directory.systemTemp.createTemp(
      'dartograph-option-usage.',
    );
    final previous = Directory.current;
    try {
      await File('${package.path}/pubspec.yaml').writeAsString('''
name: option_usage_fixture
environment:
  sdk: ^3.11.0
''');
      await Directory('${package.path}/lib').create();
      await File(
        '${package.path}/lib/main.dart',
      ).writeAsString('void main() {}\n');
      Directory.current = package;

      // baseline은 인덱싱 전에 거부해야 한다. 통과하면 옵션 이름의 파일을
      // 실제로 만들고 성공을 보고한다.
      expect(
        await runDartograph(
          const ['baseline', '--write', '--force', '.'],
          output: StringBuffer(),
          error: StringBuffer(),
        ),
        ExitStatus.usage.code,
      );
      expect(File('${package.path}/--force').existsSync(), isFalse);

      expect(
        await runDartograph(const [
          'baseline',
          '--write',
          'baseline.json',
          '--force',
        ], error: StringBuffer()),
        ExitStatus.usage.code,
      );
      expect(
        await runDartograph(const [
          'query',
          'main',
          '--baseline',
        ], error: StringBuffer()),
        ExitStatus.usage.code,
      );
      expect(
        await runDartograph(const [
          'query',
          'main',
          '--baseline',
          'baseline.json',
          '--format',
        ], error: StringBuffer()),
        ExitStatus.usage.code,
      );
      expect(
        await runDartograph(const [
          'bridges',
          '--format',
          'json',
          '--strict',
        ], error: StringBuffer()),
        ExitStatus.usage.code,
      );
      // `--` 이스케이프는 그대로 동작해야 한다.
      expect(
        await runDartograph(const [
          'bridges',
          '--format',
          'json',
          '--',
          '.',
        ], output: StringBuffer()),
        ExitStatus.success.code,
      );
    } finally {
      Directory.current = previous;
      await package.delete(recursive: true);
    }
  });

  test('skill describes the implemented multiple-main policy', () async {
    final output = StringBuffer();

    expect(
      await runDartograph(const ['skill'], output: output),
      ExitStatus.success.code,
    );
    expect(output.toString(), contains('Confirm the actual build target'));
    expect(output.toString(), isNot(contains('entry_points')));
  });

  test('graph emits the selected format for a package', () async {
    final output = StringBuffer();
    final error = StringBuffer();

    final status = await runDartograph(
      const ['graph', '--format', 'dot', 'test/index/fixture'],
      output: output,
      error: error,
    );

    expect(status, ExitStatus.success.code);
    expect(output.toString(), startsWith('digraph dartograph {'));
    expect(output.toString(), contains('label="call"'));
    expect(error.toString(), isEmpty);
  });

  test('graph rejects invalid arguments as usage errors', () async {
    final error = StringBuffer();

    expect(
      await runDartograph(const [
        'graph',
        '--format',
        'yaml',
        'test/index/fixture',
      ], error: error),
      ExitStatus.usage.code,
    );
    expect(error.toString(), contains('Unknown graph format'));
    expect(
      await runDartograph(const ['graph'], error: StringBuffer()),
      ExitStatus.usage.code,
    );
  });

  test('graph failures do not expose the supplied local path', () async {
    const privatePath = 'test/index/private-project-name';
    final error = StringBuffer();

    final status = await runDartograph(const [
      'graph',
      '--format',
      'dot',
      privatePath,
    ], error: error);

    expect(status, ExitStatus.failure.code);
    expect(error.toString(), contains('Analysis failed:'));
    expect(error.toString(), isNot(contains(privatePath)));
  });

  test('graph index failures return 2 without exposing local paths', () async {
    const privatePath = 'private-project-name';
    for (final failure in <Object>[
      ArgumentError.value(privatePath, 'root'),
      StateError(privatePath),
    ]) {
      final error = StringBuffer();

      final status = await runDartograph(
        const ['graph', '--format', 'dot', privatePath],
        error: error,
        indexPackage: (_) async => throw failure,
      );

      expect(status, ExitStatus.failure.code);
      expect(error.toString(), contains('Analysis failed:'));
      expect(error.toString(), isNot(contains(privatePath)));
    }
  });
}
