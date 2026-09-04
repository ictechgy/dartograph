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

/// 같은 발견 사실을 형식별로 손실 없이 직렬화한다.
abstract final class DeadReporter {
  /// 발견, 근거, 분석 한계와 억제 수를 결정적으로 렌더링한다.
  static String render(
    ReportFormat format,
    Iterable<DeadFinding> input, {
    Iterable<String> limitations = const [],
    int suppressedCount = 0,
  }) {
    final findings = input.toList()
      ..sort(
        (a, b) => '${a.kind}\u0000${a.id}'.compareTo('${b.kind}\u0000${b.id}'),
      );
    final limits = limitations.toSet().toList()..sort();
    return switch (format) {
      ReportFormat.text => _text(findings, limits, suppressedCount),
      ReportFormat.json =>
        '${jsonEncode({'findings': findings.map((finding) => finding.toJson()).toList(), 'limitations': limits, 'suppressedCount': suppressedCount})}\n',
      ReportFormat.githubActions => _githubActions(findings, limits),
      ReportFormat.sarif => _sarif(findings, limits, suppressedCount),
    };
  }

  static String _text(
    List<DeadFinding> findings,
    List<String> limits,
    int suppressed,
  ) {
    final output = StringBuffer();
    for (final finding in findings) {
      final path = _path(finding.source);
      final position = finding.line == null
          ? path
          : '$path:${finding.line}:${finding.column ?? 1}';
      output.writeln(
        '$position: warning: ${finding.kind} ${finding.id} — ${finding.reason}',
      );
      output.writeln(
        '    evidence: retentionRootsChecked=${finding.retentionRootsChecked.join(',')}',
      );
      for (final limitation in finding.limitations) {
        output.writeln('    limitation: $limitation');
      }
    }
    for (final limitation in limits) {
      output.writeln('limitation: $limitation');
    }
    output.writeln(
      'dead: ${findings.length} finding(s), $suppressed suppressed by baseline',
    );
    return output.toString();
  }

  static String _githubActions(
    List<DeadFinding> findings,
    List<String> limits,
  ) {
    final output = StringBuffer();
    for (final finding in findings) {
      final properties = <String>['file=${_property(_path(finding.source))}'];
      if (finding.line != null) properties.add('line=${finding.line}');
      if (finding.column != null) properties.add('col=${finding.column}');
      final message =
          '${finding.kind} ${finding.id}: ${finding.reason}; '
          'evidence: retentionRootsChecked='
          '${finding.retentionRootsChecked.join(',')}; limitations: '
          '${finding.limitations.join(',')}';
      output.writeln(
        '::warning ${properties.join(',')},title=dartograph dead::${_message(message)}',
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
  ) {
    final results = findings
        .map(
          (finding) => {
            'level': 'warning',
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
              'evidence': {
                'retentionRootsChecked': finding.retentionRootsChecked,
              },
              'id': finding.id,
              'kind': finding.kind,
              'limitations': finding.limitations,
            },
            'ruleId': 'dead-${finding.kind}',
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
                {'id': 'dead-declaration'},
                {'id': 'dead-file'},
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
}
