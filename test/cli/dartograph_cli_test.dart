import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  test('no arguments print the exit contract and succeed', () {
    final output = StringBuffer();

    final status = runDartograph(const [], output: output);

    expect(status, ExitStatus.success.code);
    expect(output.toString(), contains('Exit codes:'));
  });

  test('short help prints the exit contract and succeeds', () {
    final output = StringBuffer();

    final status = runDartograph(const ['-h'], output: output);

    expect(status, ExitStatus.success.code);
    expect(output.toString(), contains('Exit codes:'));
  });

  test('version prints a version and succeeds', () {
    final output = StringBuffer();

    final status = runDartograph(const ['--version'], output: output);

    expect(status, ExitStatus.success.code);
    expect(output.toString(), 'dartograph 0.1.0-dev\n');
  });

  test('unknown command reports usage without claiming analysis results', () {
    final error = StringBuffer();

    final status = runDartograph(const ['unknown'], error: error);

    expect(status, ExitStatus.usage.code);
    expect(error.toString(), contains('Usage: dartograph'));
    expect(error.toString(), isNot(contains('delete')));
  });

  test('contract probes exercise findings and failure outcomes', () {
    final error = StringBuffer();

    expect(runDartograph(const ['_findings']), ExitStatus.findings.code);
    expect(
      runDartograph(const ['_failure'], error: error),
      ExitStatus.failure.code,
    );
    expect(error.toString(), contains('Analysis failed:'));
  });
}
