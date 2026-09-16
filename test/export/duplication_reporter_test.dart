import 'dart:convert';

import 'package:dartograph/src/analysis/duplication_analyzer.dart';
import 'package:dartograph/src/export/dead_reporter.dart';
import 'package:dartograph/src/export/duplication_reporter.dart';
import 'package:test/test.dart';

void main() {
  const finding = DuplicationFinding(
    tokenCount: 77,
    instances: [
      DuplicateInstance(
        source: 'project:lib/alpha.dart',
        startLine: 3,
        endLine: 12,
      ),
      DuplicateInstance(
        source: 'project:lib/beta.dart',
        startLine: 8,
        endLine: 17,
      ),
    ],
  );
  const limitation = 'duplication-scope: only analyzed sources are compared';

  test('all dup formats render instances and limitations', () {
    for (final format in ReportFormat.values) {
      final report = DuplicationReporter.render(
        format,
        [finding],
        limitations: [limitation],
        minTokens: 40,
      );
      expect(report, contains('alpha.dart'), reason: format.name);
      expect(report, contains('beta.dart'), reason: format.name);
      expect(report, contains('77'), reason: format.name);
      expect(report, contains('duplication-scope'), reason: format.name);
    }
  });

  test('json and sarif documents stay parseable', () {
    final json =
        jsonDecode(
              DuplicationReporter.render(
                ReportFormat.json,
                [finding],
                limitations: [limitation],
                minTokens: 40,
              ),
            )
            as Map<String, Object?>;
    expect(json['report'], 'dup');
    expect(json['minTokens'], 40);
    final first = (json['findings']! as List).single as Map<String, Object?>;
    expect(first['kind'], 'duplicate-block');

    final sarif =
        jsonDecode(
              DuplicationReporter.render(
                ReportFormat.sarif,
                [finding],
                limitations: [limitation],
                minTokens: 40,
              ),
            )
            as Map<String, Object?>;
    expect(sarif['version'], '2.1.0');
    final results =
        ((sarif['runs']! as List).single as Map<String, Object?>)['results']!
            as List;
    expect(results, hasLength(1));
    expect((results.single as Map)['ruleId'], 'dup-duplicate-block');
  });

  test('github-actions escapes workflow syntax in messages', () {
    final hostile = DuplicationFinding(
      tokenCount: 10,
      instances: [
        const DuplicateInstance(
          source: 'project:lib/a,b.dart',
          startLine: 1,
          endLine: 2,
        ),
        const DuplicateInstance(
          source: 'project:lib/c.dart',
          startLine: 3,
          endLine: 4,
        ),
      ],
    );
    final report = DuplicationReporter.render(
      ReportFormat.githubActions,
      [hostile],
      limitations: const ['limit with\nnewline'],
      minTokens: 5,
    );
    expect(report, contains('a%2Cb.dart'));
    expect(report, isNot(contains('\nnewline')));
    expect(report, contains('%0A'));
  });
}
