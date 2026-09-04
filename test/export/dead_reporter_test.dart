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
}
