import 'dart:convert';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

/// `cycles`·`rules`·`metrics`의 `--format text|json|sarif` 계약을 고정한다.
/// 기본값(json)은 기존 출력과 같아야 하고, `--explain`은 json 전용이다.
void main() {
  const fixture = 'fixtures/phase5_contract';
  const layers = '$fixture/layers.yaml';

  Future<({int status, String out})> runCli(List<String> arguments) async {
    final output = StringBuffer();
    final status = await runDartograph(
      arguments,
      output: output,
      error: StringBuffer(),
    );
    return (status: status, out: output.toString());
  }

  test('cycles keeps the JSON default when --format is absent', () async {
    final result = await runCli(['cycles', fixture]);
    expect(result.status, ExitStatus.success.code);
    final document = jsonDecode(result.out) as Map<String, Object?>;
    expect(document.keys, containsAll(['cycles', 'limitations']));
  });

  test('cycles --format text renders deterministic lines', () async {
    final result = await runCli(['cycles', '--format', 'text', fixture]);
    expect(result.status, ExitStatus.success.code);
    expect(result.out, contains('cycle: '));
    expect(result.out, contains('    break: '));
    expect(
      result.out.trimRight().split('\n').last,
      matches(RegExp(r'^cycles: \d+$')),
    );
  });

  test('cycles --format sarif declares the rule and results', () async {
    final result = await runCli(['cycles', '--format', 'sarif', fixture]);
    expect(result.status, ExitStatus.success.code);
    final document = jsonDecode(result.out) as Map<String, Object?>;
    expect(document['version'], '2.1.0');
    final run = (document['runs'] as List).single as Map<String, Object?>;
    final driver =
        (run['tool'] as Map<String, Object?>)['driver'] as Map<String, Object?>;
    expect((driver['rules'] as List).single, {'id': 'dartograph-cycles'});
    final results = run['results'] as List;
    expect(results, isNotEmpty);
    expect(
      {for (final result in results) (result as Map)['ruleId']},
      {'dartograph-cycles'},
    );
  });

  test('cycles rejects an unknown format and explain with sarif', () async {
    expect(
      (await runCli(['cycles', '--format', 'xml', fixture])).status,
      ExitStatus.usage.code,
    );
    expect(
      (await runCli([
        'cycles',
        '--explain',
        'project:lib/a.dart::a',
        '--format',
        'sarif',
        fixture,
      ])).status,
      ExitStatus.usage.code,
    );
  });

  test('rules --format text and sarif render violations', () async {
    final text = await runCli([
      'rules',
      '--config',
      layers,
      '--format',
      'text',
      fixture,
    ]);
    expect(text.status, ExitStatus.success.code);
    expect(text.out, contains('violations: '));

    final sarif = await runCli([
      'rules',
      '--config',
      layers,
      '--format',
      'sarif',
      fixture,
    ]);
    expect(sarif.status, ExitStatus.success.code);
    final document = jsonDecode(sarif.out) as Map<String, Object?>;
    expect(document['version'], '2.1.0');
  });

  test('metrics --format sarif declares both metric rules', () async {
    final result = await runCli(['metrics', '--format', 'sarif', fixture]);
    expect(result.status, ExitStatus.success.code);
    final document = jsonDecode(result.out) as Map<String, Object?>;
    expect(document['version'], '2.1.0');
    final run = (document['runs'] as List).single as Map<String, Object?>;
    final driver =
        (run['tool'] as Map<String, Object?>)['driver'] as Map<String, Object?>;
    final ids = [
      for (final rule in driver['rules'] as List) (rule as Map)['id'],
    ];
    expect(ids, [
      'dartograph-metrics-distance',
      'dartograph-metrics-complexity',
    ]);
  });

  test('metrics rejects an unknown format', () async {
    expect(
      (await runCli(['metrics', '--format', 'yaml', fixture])).status,
      ExitStatus.usage.code,
    );
  });

  test('affected text and sarif keep the report contract', () async {
    final text = await runCli([
      'affected',
      'HEAD',
      '--format',
      'text',
      fixture,
    ]);
    expect(text.status, ExitStatus.success.code);
    expect(text.out, contains('affected: '));

    final sarif = await runCli([
      'affected',
      'HEAD',
      '--format',
      'sarif',
      fixture,
    ]);
    expect(sarif.status, ExitStatus.success.code);
    final document = jsonDecode(sarif.out) as Map<String, Object?>;
    expect(document['version'], '2.1.0');
  });

  test('compare text and sarif keep the comparison contract', () async {
    final text = await runCli([
      'compare',
      '--format',
      'text',
      fixture,
      fixture,
    ]);
    expect(text.status, ExitStatus.success.code);
    expect(text.out, contains('newlyUnreachable: '));

    final sarif = await runCli([
      'compare',
      '--format',
      'sarif',
      fixture,
      fixture,
    ]);
    expect(sarif.status, ExitStatus.success.code);
    final document = jsonDecode(sarif.out) as Map<String, Object?>;
    expect(document['version'], '2.1.0');
  });

  test('affected and compare reject unknown formats', () async {
    expect(
      (await runCli(['affected', 'HEAD', '--format', 'xml', fixture])).status,
      ExitStatus.usage.code,
    );
    expect(
      (await runCli(['compare', '--format', 'xml', fixture, fixture])).status,
      ExitStatus.usage.code,
    );
  });
}
