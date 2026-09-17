import '../analysis/code_owners.dart';
import '../analysis/reachability_analyzer.dart';
import 'dead_reporter.dart';
import 'report_escapes.dart';

/// `dead --format codeowners`가 쓰는 CODEOWNERS 그룹 리포터다.
///
/// 각 finding의 소스 경로를 [CodeOwners]로 조회해 소유자별로 묶는다. 소유자가
/// 없는 finding은 `(unowned)` 그룹에 모은다. 형식은 사람이 읽는 텍스트이며,
/// 머신 소비는 기존 `--format json`/`sarif`에 소유자 정보가 없으므로 이 리포터를
/// 쓰지 않는다(필요하면 소유자 조회 결과를 별도로 조인한다).
abstract final class CodeownersReporter {
  /// `(unowned)` 그룹 키다. 소유자를 찾지 못한 finding이 여기에 모인다.
  static const unowned = '(unowned)';

  /// finding을 소유자별로 묶어 결정적으로 렌더링한다.
  ///
  /// [report]는 라벨·심각도를 고른다. [limitations]는 finding별 한계와 함께
  /// 출력 끝에 모은다. 소유자 그룹은 사전순이고 `(unowned)`가 마지막이다.
  static String render(
    List<DeadFinding> findings,
    CodeOwners owners, {
    DeadReport report = DeadReport.dead,
    Iterable<String> limitations = const [],
    int suppressedCount = 0,
  }) {
    final sorted = findings.toList()
      ..sort(
        (a, b) => '${a.kind}\u0000${a.id}'.compareTo('${b.kind}\u0000${b.id}'),
      );
    final groups = <String, List<DeadFinding>>{};
    for (final finding in sorted) {
      final ownerList = owners.ownersOf(
        ReportEscapes.sourcePath(finding.source),
      );
      final key = ownerList.isEmpty ? unowned : ownerList.join(', ');
      groups.putIfAbsent(key, () => []).add(finding);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a == unowned) return 1;
        if (b == unowned) return -1;
        return a.compareTo(b);
      });
    final output = StringBuffer();
    for (final key in keys) {
      final group = groups[key]!;
      output.writeln(
        '${ReportEscapes.escapeText(key)}: ${group.length} finding(s)',
      );
      for (final finding in group) {
        final position = finding.line == null
            ? ReportEscapes.escapeText(ReportEscapes.sourcePath(finding.source))
            : '${ReportEscapes.escapeText(ReportEscapes.sourcePath(finding.source))}:${finding.line}:${finding.column ?? 1}';
        output.writeln(
          '  $position: ${report.severity}: ${ReportEscapes.escapeText(finding.kind)} '
          '${ReportEscapes.escapeText(finding.id)} — ${ReportEscapes.escapeText(finding.reason)}',
        );
        for (final limitation in finding.limitations) {
          output.writeln(
            '      limitation: ${ReportEscapes.escapeText(limitation)}',
          );
        }
      }
    }
    final limits = limitations.toSet().toList()..sort();
    for (final limitation in limits) {
      output.writeln('limitation: ${ReportEscapes.escapeText(limitation)}');
    }
    output.writeln(
      '${report.label}: ${sorted.length} finding(s), $suppressedCount suppressed by baseline',
    );
    return output.toString();
  }
}
