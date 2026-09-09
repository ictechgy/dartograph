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
      // `report`는 저장된 JSON 아티팩트 단독으로도 dead/test-only 분류를
      // 기계 판독하게 한다(4형식 무손실 대칭).
      ReportFormat.json =>
        '${jsonEncode({'findings': findings.map((finding) => finding.toJson()).toList(), 'limitations': limits, 'report': report.label, 'suppressedCount': suppressedCount})}\n',
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
      final path = _escapeText(_path(finding.source));
      final position = finding.line == null
          ? path
          : '$path:${finding.line}:${finding.column ?? 1}';
      output.writeln(
        '$position: ${report.severity}: ${_escapeText(finding.kind)} '
        '${_escapeText(finding.id)} — ${_escapeText(finding.reason)}',
      );
      output.writeln(
        '    evidence: retentionRootsChecked=${_escapeText(_roots(finding))}',
      );
      for (final limitation in finding.limitations) {
        output.writeln('    limitation: ${_escapeText(limitation)}');
      }
    }
    for (final limitation in limits) {
      output.writeln('limitation: ${_escapeText(limitation)}');
    }
    output.writeln(
      '${report.label}: ${findings.length} finding(s), $suppressed suppressed by baseline',
    );
    return output.toString();
  }

  /// text 형식은 `path:line:col: severity: ...` 행 프로토콜이다. 동적 값의
  /// 개행·제어문자는 두 번째 진단줄 위조나 ANSI 주입이 되므로 C0·DEL을 가시
  /// 이스케이프로 바꾼다(정상 경로는 바이트 불변). 정책 정본은 graph_exporter의
  /// 클래스 문서를 본다.
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
                  'artifactLocation': {'uri': _sarifUri(_path(finding.source))},
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
              // testOnly는 선언 finding만 생성한다(reachability의
              // testOnlyDeclarations — 파일은 보고하지 않음)라 'test-only-file'
              // ruleId는 CLI에서 도달 불가. 라이브러리 호출자가 file finding을
              // 넣는 조합만 rules 미선언이 되므로 그 불변식을 여기에 기록한다.
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

  /// SARIF artifact uri. `Uri(path:)` 조립은 `\`를 `/`로 치환하고 `%41`을 기존
  /// 이스케이프로 해석해 경로를 조용히 손상·오귀속한다. 구분자(`/` — project ID는
  /// 항상 URL 구분자를 쓴다)로 분리해 세그먼트별로 인코딩하면 손실이 없고 정상
  /// 경로는 바이트가 불변이다.
  static String _sarifUri(String path) =>
      Uri(pathSegments: path.split('/')).toString();

  /// GitHub workflow command 이스케이프. 스펙 최소집합(`%`, CR, LF + property의
  /// `:`·`,`)에 더해 C0·DEL·C1과 행 구조·시각 순서를 깨뜨릴 수 있는 문자
  /// (U+2028·2029 줄 분리, U+202A–202E·U+2066–2069 bidi 제어를 러너 로그·주석으로
  /// 흘리지 않는다. 기존 `%0D`·`%0A` 관례와 같은 대문자 hex 퍼센트 인코딩이고
  /// 정상 입력의 바이트는 불변이다.
  static String _property(String value) => _githubEncode(value, property: true);

  static String _message(String value) => _githubEncode(value, property: false);

  static String _githubEncode(String value, {required bool property}) {
    if (!value.runes.any((rune) => _githubNeedsEncoding(rune, property))) {
      return value;
    }
    final output = StringBuffer();
    for (final rune in value.runes) {
      if (!_githubNeedsEncoding(rune, property)) {
        output.writeCharCode(rune);
        continue;
      }
      for (final byte in utf8.encode(String.fromCharCode(rune))) {
        output.write(
          '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }
    }
    return output.toString();
  }

  static bool _githubNeedsEncoding(int rune, bool property) =>
      rune == 0x25 || // %
      rune < 0x20 || // C0 (CR·LF 포함)
      rune == 0x7f || // DEL
      (rune >= 0x80 && rune <= 0x9f) || // C1
      rune == 0x2028 ||
      rune == 0x2029 || // 줄 분리·단락 분리
      (rune >= 0x202a && rune <= 0x202e) || // bidi 제어
      (rune >= 0x2066 && rune <= 0x2069) || // bidi 격리
      (property && (rune == 0x3a || rune == 0x2c)); // : ,

  static String _roots(DeadFinding finding) {
    final roots = finding.retentionRootsChecked;
    if (roots.length <= 20) return roots.join(',');
    return '${roots.take(20).join(',')},… (${roots.length} total)';
  }
}
