import 'dart:convert';

import 'package:dartograph/src/analysis/reachability_analyzer.dart';
import 'package:dartograph/src/export/dead_reporter.dart';
import 'package:test/test.dart';

void main() {
  final finding = DeadFinding(
    id: 'package:app/a.dart::dead',
    kind: 'declaration',
    source: 'project:lib/a file.dart',
    line: 7,
    column: 3,
    reason: 'unreachable from all retention roots',
    retentionRootsChecked: const ['package:app/main.dart::main'],
    limitations: const ['single configuration'],
  );

  test('all dead reporters preserve evidence and limitations', () {
    for (final format in ReportFormat.values) {
      final report = DeadReporter.render(
        format,
        [finding],
        limitations: finding.limitations,
        suppressedCount: 2,
      );
      expect(report, contains('unreachable from all retention roots'));
      expect(report, contains('package:app/main.dart::main'));
      expect(report, contains('single configuration'));
    }
  });

  test('the default dead report renders at warning severity', () {
    expect(
      DeadReporter.render(ReportFormat.text, [finding]),
      contains(': warning: declaration'),
    );
    expect(
      DeadReporter.render(ReportFormat.text, [finding]),
      contains('dead: 1 finding(s)'),
    );
    expect(
      DeadReporter.render(ReportFormat.githubActions, [finding]),
      contains('::warning '),
    );
    final sarif =
        jsonDecode(DeadReporter.render(ReportFormat.sarif, [finding]))
            as Map<String, Object?>;
    final result = ((sarif['runs'] as List).single as Map)['results'] as List;
    expect((result.single as Map)['level'], 'warning');
    expect((result.single as Map)['ruleId'], 'dead-declaration');
  });

  test('the test-only report renders at info severity and never warns', () {
    final testOnly = DeadFinding(
      id: 'package:app/a.dart::onlyTested',
      kind: 'declaration',
      source: 'project:lib/a.dart',
      line: 3,
      column: 1,
      reason: 'reached only from test code',
      retentionRootsChecked: const ['package:app/a_test.dart::main'],
    );
    final text = DeadReporter.render(ReportFormat.text, [
      testOnly,
    ], report: DeadReport.testOnly);
    expect(text, contains(': info: declaration'));
    expect(text, contains('test-only: 1 finding(s)'));
    expect(text, isNot(contains('warning')));

    final actions = DeadReporter.render(ReportFormat.githubActions, [
      testOnly,
    ], report: DeadReport.testOnly);
    expect(actions, contains('::notice '));
    expect(actions, isNot(contains('::warning')));
    expect(actions, contains('title=dartograph test-only'));

    final sarif =
        jsonDecode(
              DeadReporter.render(ReportFormat.sarif, [
                testOnly,
              ], report: DeadReport.testOnly),
            )
            as Map<String, Object?>;
    final run = (sarif['runs'] as List).single as Map;
    final result = (run['results'] as List).single as Map;
    expect(result['level'], 'note');
    expect(result['ruleId'], 'test-only-declaration');
    final rules = ((run['tool'] as Map)['driver'] as Map)['rules'] as List;
    expect(rules, [
      {'id': 'test-only-declaration'},
    ]);
  });

  test(
    'machine reporters emit deterministic valid documents and locations',
    () {
      final json = DeadReporter.render(ReportFormat.json, [
        finding,
      ], limitations: finding.limitations);
      expect(
        DeadReporter.render(ReportFormat.json, [
          finding,
        ], limitations: finding.limitations),
        json,
      );
      expect(jsonDecode(json), containsPair('findings', isNotEmpty));
      expect(
        finding.toJson().keys,
        orderedEquals([
          'column',
          'evidence',
          'id',
          'kind',
          'limitations',
          'line',
          'reason',
          'source',
        ]),
      );

      final actions = DeadReporter.render(ReportFormat.githubActions, [
        finding,
      ], limitations: finding.limitations);
      expect(actions, contains('::warning file=lib/a file.dart,line=7,col=3'));
      expect(actions, contains(finding.id));

      final sarifText = DeadReporter.render(ReportFormat.sarif, [
        finding,
      ], limitations: finding.limitations);
      final sarif = jsonDecode(sarifText) as Map<String, Object?>;
      expect(sarif['version'], '2.1.0');
      expect(sarifText, contains('lib/a%20file.dart'));
      expect(sarifText, contains('"startLine":7'));
      expect(sarifText, contains('"executionSuccessful":true'));
      expect(sarifText, contains(finding.id));
    },
  );

  test('large retention-root evidence is bounded without hiding its count', () {
    final large = DeadFinding(
      id: finding.id,
      kind: finding.kind,
      source: finding.source,
      reason: finding.reason,
      retentionRootsChecked: [
        for (var index = 0; index < 10000; index++)
          'package:app/root.dart::root$index',
      ],
    );

    for (final format in ReportFormat.values) {
      expect(
        DeadReporter.render(format, [large]).length,
        lessThan(20000),
        reason: format.name,
      );
    }
    final document =
        jsonDecode(DeadReporter.render(ReportFormat.json, [large]))
            as Map<String, Object?>;
    final findingJson = (document['findings']! as List).single as Map;
    final evidence = findingJson['evidence'] as Map;
    expect(evidence['retentionRootCount'], 10000);
    expect(evidence['retentionRootsChecked'], hasLength(20));
    expect(evidence['retentionRootsTruncated'], isTrue);
  });

  test('control characters cannot forge text lines or GH commands', () {
    final hostile = DeadFinding(
      id: 'package:app/evil.dart::Foo\nlib/innocent.dart:1:1: warning: fake',
      kind: 'declaration',
      source: 'project:lib/ev\x1bil.dart',
      line: 3,
      column: 1,
      reason: 'unreachable from all retention roots',
      retentionRootsChecked: const [],
      limitations: const [],
    );

    final text = DeadReporter.render(ReportFormat.text, [hostile]);
    // 진단줄은 정확히 1개 + evidence + 요약뿐 — 개행이 가시 escape로 남아
    // 두 번째 `lib/innocent.dart:1:1: warning:` 줄을 위조하지 못한다.
    final lines = text.split('\n').where((l) => l.isNotEmpty).toList();
    expect(lines, hasLength(3));
    expect(lines[0], contains(r'::Foo\nlib/innocent.dart'));
    expect(lines[0], contains(r'lib/ev\x1bil.dart:3:1'));
    expect(text, isNot(contains('\x1b')));

    final actions = DeadReporter.render(ReportFormat.githubActions, [hostile]);
    // 한 물리 명령줄만 남고 ESC·개행은 퍼센트 인코딩된다.
    expect(actions.split('\n').where((l) => l.isNotEmpty), hasLength(1));
    expect(actions, contains('%1B'));
    expect(actions, contains('%0A'));
  });

  test('sarif uri keeps backslashes and literal percent sequences', () {
    final backslash = DeadFinding(
      id: r'package:app/back\slash.dart::x',
      kind: 'declaration',
      source: r'project:lib/back\slash.dart',
      reason: 'unreachable from all retention roots',
      retentionRootsChecked: const [],
    );
    final percent = DeadFinding(
      id: 'package:app/%41.dart::x',
      kind: 'declaration',
      source: 'project:lib/%41.dart',
      reason: 'unreachable from all retention roots',
      retentionRootsChecked: const [],
    );
    final sarif = DeadReporter.render(ReportFormat.sarif, [backslash, percent]);
    // Uri(path:)였으면 back\slash → back/slash 손상, %41 → A 오귀속이었다.
    expect(sarif, contains(r'lib/back%5Cslash.dart'));
    expect(sarif, contains('lib/%2541.dart'));
  });
}
