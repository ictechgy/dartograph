import '../analysis/code_owners.dart';
import '../analysis/reachability_analyzer.dart';
import 'dead_reporter.dart';

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
      final ownerList = owners.ownersOf(_path(finding.source));
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
      output.writeln('${_escapeText(key)}: ${group.length} finding(s)');
      for (final finding in group) {
        final position = finding.line == null
            ? _escapeText(_path(finding.source))
            : '${_escapeText(_path(finding.source))}:${finding.line}:${finding.column ?? 1}';
        output.writeln(
          '  $position: ${report.severity}: ${_escapeText(finding.kind)} '
          '${_escapeText(finding.id)} — ${_escapeText(finding.reason)}',
        );
        for (final limitation in finding.limitations) {
          output.writeln('      limitation: ${_escapeText(limitation)}');
        }
      }
    }
    final limits = limitations.toSet().toList()..sort();
    for (final limitation in limits) {
      output.writeln('limitation: ${_escapeText(limitation)}');
    }
    output.writeln(
      '${report.label}: ${sorted.length} finding(s), $suppressedCount suppressed by baseline',
    );
    return output.toString();
  }

  /// `project:` 센티널을 벗겨 프로젝트 상대 경로를 남긴다.
  static String _path(String source) => source.startsWith('project:')
      ? source.substring('project:'.length)
      : source;

  /// text와 같은 C0·DEL 가시 이스케이프(정상 입력은 바이트 불변).
  static String _escapeText(String value) {
    if (!value.runes.any(_isControlRune)) return value;
    final output = StringBuffer();
    for (final rune in value.runes) {
      if (!_isControlRune(rune)) {
        output.writeCharCode(rune);
        continue;
      }
      switch (rune) {
        case 0x0a:
          output.write(r'\n');
        case 0x0d:
          output.write(r'\r');
        case 0x09:
          output.write(r'\t');
        default:
          output.write('\\x${rune.toRadixString(16).padLeft(2, '0')}');
      }
    }
    return output.toString();
  }

  static bool _isControlRune(int rune) => rune < 0x20 || rune == 0x7f;
}
