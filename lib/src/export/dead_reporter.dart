import 'dart:convert';

import '../analysis/reachability_analyzer.dart';

/// `dead`가 지원하는 사용자 및 CI 출력 형식이다.
enum ReportFormat {
  /// 사람이 읽고 IDE가 경로를 클릭할 수 있는 텍스트다.
  text,

  /// 자동화 소비자를 위한 결정적 JSON이다.
  json,

  /// GitHub Actions workflow command다.
  githubActions,

  /// 정적 분석 도구 교환 형식 SARIF 2.1.0이다.
  sarif,
}

/// `dead` 보고의 종류다. 심각도·라벨·CI 토큰을 함께 결정한다.
enum DeadReport {
  /// 보존 루트에서 미도달 — `warning`이고 finding이 빌드를 실패시킨다.
  dead,

  /// 테스트에서만 도달 — `info`라 빌드를 실패시키지 않는다. 죽은 코드가 아니라
  /// "테스트가 유일한 호출자"라는 관측이다.
  testOnly;

  /// 사람 텍스트의 심각도 단어다.
  String get severity => this == testOnly ? 'info' : 'warning';

  /// 요약줄과 CI 제목에 쓰는 라벨이다.
  String get label => this == testOnly ? 'test-only' : 'dead';

  /// GitHub Actions workflow command다(info는 `notice`).
  String get githubCommand => this == testOnly ? 'notice' : 'warning';

  /// SARIF result level이다(info는 `note`).
  String get sarifLevel => this == testOnly ? 'note' : 'warning';

  /// SARIF ruleId 접두어다.
  String get rulePrefix => this == testOnly ? 'test-only' : 'dead';
}

/// 같은 발견 사실을 형식별로 손실 없이 직렬화한다.
abstract final class DeadReporter {
  /// 발견, 근거, 분석 한계와 억제 수를 결정적으로 렌더링한다.
  ///
  /// [report]는 심각도·라벨·CI 토큰을 고른다. 기본값 [DeadReport.dead]는 기존
  /// 출력을 byte-for-byte 보존하고, [DeadReport.testOnly]는 info 수준으로 낸다.
  static String render(
    ReportFormat format,
    Iterable<DeadFinding> input, {
    Iterable<String> limitations = const [],
    int suppressedCount = 0,
    DeadReport report = DeadReport.dead,
  }) {
    final findings = input.toList()
      ..sort(
        (a, b) => '${a.kind}\u0000${a.id}'.compareTo('${b.kind}\u0000${b.id}'),
      );
    final limits = limitations.toSet().toList()..sort();
    return switch (format) {
      ReportFormat.text => _text(findings, limits, suppressedCount, report),
      ReportFormat.json =>
        '${jsonEncode({'findings': findings.map((finding) => finding.toJson()).toList(), 'limitations': limits, 'suppressedCount': suppressedCount})}\n',
      ReportFormat.githubActions => _githubActions(findings, limits, report),
      ReportFormat.sarif => _sarif(findings, limits, suppressedCount, report),
    };
  }

  static String _text(
    List<DeadFinding> findings,
    List<String> limits,
    int suppressed,
    DeadReport report,
  ) {
    final output = StringBuffer();
    for (final finding in findings) {
      final path = _path(finding.source);
      final position = finding.line == null
          ? path
          : '$path:${finding.line}:${finding.column ?? 1}';
      output.writeln(
        '$position: ${report.severity}: ${finding.kind} ${finding.id} — ${finding.reason}',
      );
      output.writeln('    evidence: retentionRootsChecked=${_roots(finding)}');
      for (final limitation in finding.limitations) {
        output.writeln('    limitation: $limitation');
      }
    }
    for (final limitation in limits) {
      output.writeln('limitation: $limitation');
    }
    output.writeln(
      '${report.label}: ${findings.length} finding(s), $suppressed suppressed by baseline',
    );
    return output.toString();
  }

  static String _githubActions(
    List<DeadFinding> findings,
    List<String> limits,
    DeadReport report,
  ) {
    final output = StringBuffer();
    for (final finding in findings) {
      final properties = <String>['file=${_property(_path(finding.source))}'];
      if (finding.line != null) properties.add('line=${finding.line}');
      if (finding.column != null) properties.add('col=${finding.column}');
      final message =
          '${finding.kind} ${finding.id}: ${finding.reason}; '
          'evidence: retentionRootsChecked='
          '${_roots(finding)}; limitations: '
          '${finding.limitations.join(',')}';
      output.writeln(
        '::${report.githubCommand} ${properties.join(',')},title=dartograph ${report.label}::${_message(message)}',
      );
    }
    for (final limitation in limits) {
      output.writeln(
        '::notice title=dartograph limitation::${_message(limitation)}',
      );
    }
    return output.toString();
  }

  static String _sarif(
    List<DeadFinding> findings,
    List<String> limits,
    int suppressed,
    DeadReport report,
  ) {
    final results = findings
        .map(
          (finding) => {
            'level': report.sarifLevel,
            'locations': [
              {
                'physicalLocation': {
                  'artifactLocation': {
                    'uri': Uri(path: _path(finding.source)).toString(),
                  },
                  'region': {
                    'startColumn': finding.column ?? 1,
                    'startLine': finding.line ?? 1,
                  },
                },
              },
            ],
            'message': {
              'text': '${finding.kind} ${finding.id}: ${finding.reason}',
            },
            'properties': {
              'evidence': {...finding.retentionEvidence},
              'id': finding.id,
              'kind': finding.kind,
              'limitations': finding.limitations,
            },
            'ruleId': '${report.rulePrefix}-${finding.kind}',
          },
        )
        .toList();
    return '${jsonEncode({
      r'$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
      'runs': [
        {
          'invocations': [
            {
              'executionSuccessful': true,
              'properties': {'limitations': limits, 'suppressedCount': suppressed},
            },
          ],
          'results': results,
          'tool': {
            'driver': {
              'name': 'dartograph',
              'rules': [
                {'id': '${report.rulePrefix}-declaration'},
                if (report == DeadReport.dead) {'id': '${report.rulePrefix}-file'},
              ],
            },
          },
        },
      ],
      'version': '2.1.0',
    })}\n';
  }

  static String _path(String source) => source.startsWith('project:')
      ? source.substring('project:'.length)
      : source;

  static String _property(String value) => value
      .replaceAll('%', '%25')
      .replaceAll('\r', '%0D')
      .replaceAll('\n', '%0A')
      .replaceAll(':', '%3A')
      .replaceAll(',', '%2C');

  static String _message(String value) => value
      .replaceAll('%', '%25')
      .replaceAll('\r', '%0D')
      .replaceAll('\n', '%0A');

  static String _roots(DeadFinding finding) {
    final roots = finding.retentionRootsChecked;
    if (roots.length <= 20) return roots.join(',');
    return '${roots.take(20).join(',')},… (${roots.length} total)';
  }
}
