import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

/// 감사(2026-09-08)가 분류한 CLI 커버리지 공백 4그룹의 회귀다:
/// 기본 인덱스 주입 분기, cycles/rules의 usage 거부 분기, 분석 실패 catch,
/// rules의 성공(0) 반환.
void main() {
  late Directory temporary;
  late File rules;
  late AnalyzerGraphResult indexed;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('dartograph-audit-cli.');
    rules = File('${temporary.path}/layers.yaml');
    await rules.writeAsString('''
layers:
  - name: first
    match: [a]
  - name: second
    match: [b]
rules:
  - name: first cannot reach second
    from: first
    deny: [second]
''');
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'b', sourceUri: 'project:lib/b.dart', line: 2))
      ..addNode(GraphNode(id: 'a', sourceUri: 'project:lib/a.dart', line: 1));
    indexed = AnalyzerGraphResult(graph: graph, limitations: const []);
  });

  tearDown(() => temporary.delete(recursive: true));

  test('cycles and rules reject malformed flags as usage errors', () async {
    var calls = 0;
    Future<int> run(List<String> arguments) => runDartograph(
      arguments,
      output: StringBuffer(),
      error: StringBuffer(),
      indexPackage: (_) async {
        calls++;
        return indexed;
      },
    );

    for (final invocation in [
      ['cycles', '--strict', '--strict', temporary.path],
      ['cycles', '--explain', 'a', '--explain', 'b', temporary.path],
      ['cycles', '--explain'],
      ['cycles', '--nope', temporary.path],
      ['rules', '--config', rules.path, '--strict', '--strict', temporary.path],
      ['rules', '--config', rules.path, '--explain'],
      ['rules', '--config', rules.path, '--nope', temporary.path],
    ]) {
      expect(
        await run(invocation),
        ExitStatus.usage.code,
        reason: invocation.join(' '),
      );
    }
    expect(calls, 0);
  });

  test('rules completes with status 0 when nothing violates', () async {
    // 간선 없는 그래프 — 규칙은 선언됐지만 위반 경로가 없으면 strict여도
    // 0으로 완주한다(실패 catch만이 아닌 성공 반환 분기 고정).
    final output = StringBuffer();
    expect(
      await runDartograph(
        ['rules', '--config', rules.path, '--strict', temporary.path],
        output: output,
        error: StringBuffer(),
        indexPackage: (_) async => indexed,
      ),
      ExitStatus.success.code,
    );
    expect(output.toString(), contains('"violations":[]'));
  });

  test('analysis failures in compare, cycles, and rules exit 2', () async {
    for (final invocation in [
      ['compare', temporary.path, temporary.path],
      ['cycles', temporary.path],
      ['rules', '--config', rules.path, temporary.path],
    ]) {
      final error = StringBuffer();
      expect(
        await runDartograph(
          invocation,
          output: StringBuffer(),
          error: error,
          indexPackage: (_) async => throw StateError('index failed'),
        ),
        ExitStatus.failure.code,
        reason: invocation.join(' '),
      );
      expect(error.toString(), contains('Analysis failed:'));
    }
  });

  test(
    'cycles, metrics, and affected dispatch through the default indexer',
    () async {
      // 프로덕션(bin)은 항상 기본 AnalyzerGraphIndex 배선을 탄다 — 주입 없이
      // 실제 fixture로 스모크한다.
      expect(
        await runDartograph(
          const ['cycles', 'fixtures/phase5_contract'],
          output: StringBuffer(),
          error: StringBuffer(),
        ),
        ExitStatus.success.code,
      );
      expect(
        await runDartograph(
          const ['metrics', 'fixtures/phase5_contract'],
          output: StringBuffer(),
          error: StringBuffer(),
        ),
        ExitStatus.success.code,
      );
      expect(
        await runDartograph(
          const ['affected', 'HEAD', 'fixtures/phase5_contract'],
          output: StringBuffer(),
          error: StringBuffer(),
        ),
        ExitStatus.success.code,
      );
    },
  );
}
