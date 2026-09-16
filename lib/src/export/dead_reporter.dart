import 'dart:convert';

import '../analysis/reachability_analyzer.dart';
import 'report_escapes.dart';

/// `dead`가 지원하는 사용자 및 CI 출력 형식이다.
enum ReportFormat {
  /// 사람이 읽고 IDE가 경로를 클릭할 수 있는 텍스트다.
  text,

  /// 자동화 소비자를 위한 결정적 JSON이다.
  json,

  /// 사람과 AI가 함께 읽는 Markdown 리포트다(`impact`·`runtime`과 같은 형식).
  markdown,

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
  testOnly,

  /// 공개 접근성이 남아도 — `info`라 빌드를 실패시키지 않는다. 죽은 코드가
  /// 아니라 "지금 관측으로는 라이브러리 비공개로 좁혀도 되는 공개 선언"이라는
  /// 관측이다(Periphery `redundant public accessibility` 패리티).
  redundantPublic;

  /// 사람 텍스트의 심각도 단어다.
  String get severity => this == DeadReport.dead ? 'warning' : 'info';

  /// 요약줄과 CI 제목에 쓰는 라벨이다(json `report` 필드이기도 하다).
  String get label => switch (this) {
    DeadReport.dead => 'dead',
    DeadReport.testOnly => 'test-only',
    DeadReport.redundantPublic => 'redundant-public',
  };

  /// GitHub Actions workflow command다(info는 `notice`).
  String get githubCommand => this == DeadReport.dead ? 'warning' : 'notice';

  /// SARIF result level이다(info는 `note`).
  String get sarifLevel => this == DeadReport.dead ? 'warning' : 'note';

  /// SARIF ruleId 접두어다.
  String get rulePrefix => label;
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
      // `report`는 저장된 JSON 아티팩트 단독으로도 dead/test-only 분류를
      // 기계 판독하게 한다(4형식 무손실 대칭).
      ReportFormat.json =>
        '${jsonEncode({'findings': findings.map((finding) => finding.toJson()).toList(), 'limitations': limits, 'report': report.label, 'suppressedCount': suppressedCount})}\n',
      ReportFormat.markdown => _markdown(
        findings,
        limits,
        suppressedCount,
        report,
      ),
      ReportFormat.githubActions => _githubActions(
        findings,
        limits,
        suppressedCount,
        report,
      ),
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
      final path = ReportEscapes.escapeText(
        ReportEscapes.sourcePath(finding.source),
      );
      final position = finding.line == null
          ? path
          : '$path:${finding.line}:${finding.column ?? 1}';
      output.writeln(
        '$position: ${report.severity}: ${ReportEscapes.escapeText(finding.kind)} '
        '${ReportEscapes.escapeText(finding.id)} — ${ReportEscapes.escapeText(finding.reason)}',
      );
      output.writeln(
        '    evidence: retentionRootsChecked=${ReportEscapes.escapeText(_roots(finding))}',
      );
      for (final limitation in finding.limitations) {
        output.writeln(
          '    limitation: ${ReportEscapes.escapeText(limitation)}',
        );
      }
    }
    for (final limitation in limits) {
      output.writeln('limitation: ${ReportEscapes.escapeText(limitation)}');
    }
    output.writeln(
      '${report.label}: ${findings.length} finding(s), $suppressed suppressed by baseline',
    );
    return output.toString();
  }

  /// 사람과 AI가 함께 읽는 Markdown 리포트다.
  ///
  /// 표 셀에는 text와 같은 제어문자 정책을 적용하고 파이프를 이스케이프해 표
  /// 구조를 지킨다. 전역 limitation과 finding별 limitation을 구분해 적는다
  /// (finding별 것은 어느 finding의 것인지 ID로 귀속한다).
  static String _markdown(
    List<DeadFinding> findings,
    List<String> limits,
    int suppressed,
    DeadReport report,
  ) {
    final output = StringBuffer();
    output.writeln('# dartograph ${report.label} report');
    output.writeln();
    output.writeln('| Metric | Value |');
    output.writeln('|---|---:|');
    output.writeln('| Report | ${report.label} |');
    output.writeln('| Findings | ${findings.length} |');
    output.writeln('| Suppressed by baseline | $suppressed |');
    output.writeln();
    output.writeln(
      '| Severity | Kind | Symbol | Location | Reason | Evidence |',
    );
    output.writeln('|---|---|---|---|---|---|');
    for (final finding in findings) {
      final location = finding.line == null
          ? '`${ReportEscapes.mdCell(ReportEscapes.sourcePath(finding.source))}`'
          : '`${ReportEscapes.mdCell(ReportEscapes.sourcePath(finding.source))}:${finding.line}:${finding.column ?? 1}`';
      output.writeln(
        '| ${report.severity} | ${ReportEscapes.mdCell(finding.kind)} | '
        '`${ReportEscapes.mdCell(finding.id)}` | $location | ${ReportEscapes.mdCell(finding.reason)} | '
        '`retentionRootsChecked=${ReportEscapes.mdCell(_roots(finding))}` |',
      );
    }
    output.writeln();
    output.writeln('## Limitations');
    output.writeln();
    for (final finding in findings) {
      for (final limitation in finding.limitations) {
        output.writeln(
          '- `${ReportEscapes.mdCell(finding.id)}`: ${ReportEscapes.mdCell(limitation)}',
        );
      }
    }
    for (final limitation in limits) {
      output.writeln('- ${ReportEscapes.mdCell(limitation)}');
    }
    return output.toString();
  }

  static String _githubActions(
    List<DeadFinding> findings,
    List<String> limits,
    int suppressed,
    DeadReport report,
  ) {
    final output = StringBuffer();
    // baseline이 finding 전부를 억제해도 GH 로그에 흔적을 남긴다(다른 3형식과
    // 대칭). 0이면 기존 출력과 byte-for-byte 동일하다.
    if (suppressed > 0) {
      output.writeln(
        '::notice title=dartograph ${report.label}::$suppressed finding(s) suppressed by baseline',
      );
    }
    for (final finding in findings) {
      final properties = <String>[
        'file=${ReportEscapes.githubProperty(ReportEscapes.sourcePath(finding.source))}',
      ];
      if (finding.line != null) properties.add('line=${finding.line}');
      if (finding.column != null) properties.add('col=${finding.column}');
      final message =
          '${finding.kind} ${finding.id}: ${finding.reason}; '
          'evidence: retentionRootsChecked='
          '${_roots(finding)}; limitations: '
          '${finding.limitations.join(',')}';
      output.writeln(
        '::${report.githubCommand} ${properties.join(',')},title=dartograph ${report.label}::${ReportEscapes.githubMessage(message)}',
      );
    }
    for (final limitation in limits) {
      output.writeln(
        '::notice title=dartograph limitation::${ReportEscapes.githubMessage(limitation)}',
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
                    'uri': ReportEscapes.sarifUri(finding.source),
                  },
                  // 파일 finding(line 없음)에 1:1 region을 발명하지 않는다 —
                  // SARIF에서 region은 선택이며 위치 증거 날조는 근거 규약 위반이다.
                  if (finding.line != null)
                    'region': {
                      'startColumn': finding.column ?? 1,
                      'startLine': finding.line,
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
              // testOnly·redundantPublic은 선언 finding만 생성한다(reachability의
              // testOnlyDeclarations·redundantPublicDeclarations — 파일은 보고하지
              // 않음)라 '<label>-file' ruleId는 CLI에서 도달 불가. 라이브러리
              // 호출자가 file finding을 넣는 조합만 rules 미선언이 되므로 그
              // 불변식을 여기에 기록한다.
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

  static String _roots(DeadFinding finding) {
    final roots = finding.retentionRootsChecked;
    if (roots.length <= 20) return roots.join(',');
    return '${roots.take(20).join(',')},… (${roots.length} total)';
  }
}
