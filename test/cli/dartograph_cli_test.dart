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
    addTearDown(() => package.delete(recursive: true));
    await File('${package.path}/pubspec.yaml').writeAsString('''
name: option_usage_fixture
environment:
  sdk: ^3.11.0
''');
    await Directory('${package.path}/lib').create();
    await File(
      '${package.path}/lib/main.dart',
    ).writeAsString('void main() {}\n');
    final root = package.path;

    for (final invocation in [
      ['baseline', '--write', '--force', root],
      ['baseline', '--write', '$root/baseline.json', '--force'],
      ['query', 'main', '--baseline'],
      ['query', 'main', '--baseline', '$root/baseline.json', '--format'],
      // 4인자 분기의 baseline 슬롯도 같은 기준이어야 한다.
      ['query', 'main', '--baseline', '-b.json', root],
      // 술자가 `--`로 되돌아가면 아래 단일 대시 케이스가 다시 통과한다.
      ['query', '-main', root],
      ['query', 'main', '-pkg'],
      ['baseline', '--write', '-b.json', root],
      ['bridges', '--format', 'json', '-pkg'],
      ['graph', '--format', 'json', '-pkg'],
      ['bridges', '--format', 'json', '--strict'],
      ['graph', '--format', 'json', '--strict'],
      // compare는 단일 대시도 거부해야 한다. `-h`는 실재하는 옵션이다.
      ['compare', '-h', root],
      ['rules', '--config', '--strict', root],
      ['dead', '--format', 'text', '--baseline', '--strict', root],
      ['dead', '--format', 'text', '--since', '--strict', root],
    ]) {
      expect(
        await runDartograph(
          invocation,
          output: StringBuffer(),
          error: StringBuffer(),
        ),
        ExitStatus.usage.code,
        reason: invocation.join(' '),
      );
    }

    // 정상 경로와 `--` 이스케이프는 그대로 동작해야 한다.
    for (final invocation in [
      ['graph', '--format', 'json', root],
      ['compare', root, root],
      ['query', 'main', root],
      ['bridges', '--format', 'json', root],
      ['bridges', '--format', 'json', '--', root],
      ['baseline', '--write', '$root/baseline.json', root],
    ]) {
      expect(
        await runDartograph(
          invocation,
          output: StringBuffer(),
          error: StringBuffer(),
        ),
        ExitStatus.success.code,
        reason: invocation.join(' '),
      );
    }
  });

  test(
    'baseline rejects an option-shaped destination before writing',
    () async {
      // 옵션 이름의 파일이 실제로 만들어지는지 보려면 상대 경로 해석 기준이
      // 필요하다. cwd는 프로세스 전역이라 다른 테스트 파일과 경합하므로 인덱싱
      // 없이 usage로 떨어지는 이 한 번만 감싼다.
      final package = await Directory.systemTemp.createTemp(
        'dartograph-baseline-usage.',
      );
      final previous = Directory.current;
      try {
        Directory.current = package;
        expect(
          await runDartograph(
            const ['baseline', '--write', '--force', '.'],
            output: StringBuffer(),
            error: StringBuffer(),
          ),
          ExitStatus.usage.code,
        );
        expect(File('${package.path}/--force').existsSync(), isFalse);
      } finally {
        Directory.current = previous;
        await package.delete(recursive: true);
      }
    },
  );

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
