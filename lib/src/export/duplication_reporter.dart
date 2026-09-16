import 'dart:convert';

import '../analysis/duplication_analyzer.dart';
import 'dead_reporter.dart';
import 'report_escapes.dart';

/// `dup`의 중복 블록 발견을 형식별로 직렬화한다.
///
/// 발견은 같은 토큰 구조의 반복 위치 쌍이다 — 병합·삭제 지시가 아니라 검토
/// 근거다. 같은 정규화 토큰 열이 만들어진 경로(템플릿 보일러플레이트 등)는
/// 이 검사가 구별하지 않는다.
abstract final class DuplicationReporter {
  /// 발견과 한계를 결정적으로 렌더링한다.
  static String render(
    ReportFormat format,
    Iterable<DuplicationFinding> findings, {
    Iterable<String> limitations = const [],
    required int minTokens,
  }) {
    final items = findings.toList();
    final limits = limitations.toSet().toList()..sort();
    return switch (format) {
      ReportFormat.text => _text(items, limits),
      ReportFormat.json =>
        '${jsonEncode({'findings': items.map((finding) => finding.toJson()).toList(), 'limitations': limits, 'minTokens': minTokens, 'report': 'dup'})}\n',
      ReportFormat.markdown => _markdown(items, limits),
      ReportFormat.githubActions => _githubActions(items, limits),
      ReportFormat.sarif => _sarif(items, limits),
    };
  }

  static String _text(List<DuplicationFinding> findings, List<String> limits) {
    final output = StringBuffer();
    for (final finding in findings) {
      output.writeln(
        'warning: duplicate-block ${finding.tokenCount} tokens — '
        '${finding.instances.map(_describe).map(ReportEscapes.escapeText).join(' == ')}',
      );
    }
    for (final limitation in limits) {
      output.writeln('limitation: ${ReportEscapes.escapeText(limitation)}');
    }
    output.writeln('dup: ${findings.length} finding(s)');
    return output.toString();
  }

  static String _describe(DuplicateInstance instance) =>
      '${ReportEscapes.sourcePath(instance.source)}:${instance.startLine}'
      '-${instance.endLine}';

  static String _markdown(
    List<DuplicationFinding> findings,
    List<String> limits,
  ) {
    final output = StringBuffer();
    output.writeln('# dartograph dup report');
    output.writeln();
    output.writeln('| Metric | Value |');
    output.writeln('|---|---:|');
    output.writeln('| Report | dup |');
    output.writeln('| Findings | ${findings.length} |');
    output.writeln();
    output.writeln('| Severity | Kind | Tokens | Locations |');
    output.writeln('|---|---|---:|---|');
    for (final finding in findings) {
      final locations = finding.instances
          .map((instance) => ReportEscapes.mdCode(_describe(instance)))
          .join('<br>');
      output.writeln(
        '| warning | duplicate-block | ${finding.tokenCount} | $locations |',
      );
    }
    output.writeln();
    output.writeln('## Limitations');
    output.writeln();
    for (final limitation in limits) {
      output.writeln('- ${ReportEscapes.mdCell(limitation)}');
    }
    return output.toString();
  }

  static String _githubActions(
    List<DuplicationFinding> findings,
    List<String> limits,
  ) {
    final output = StringBuffer();
    for (final finding in findings) {
      final first = finding.instances.first;
      final message =
          'duplicate-block ${finding.tokenCount} tokens: '
          '${finding.instances.map(_describe).join(' == ')}';
      output.writeln(
        '::warning file=${ReportEscapes.githubProperty(ReportEscapes.sourcePath(first.source))},line=${first.startLine},endLine=${first.endLine},title=dartograph dup::${ReportEscapes.githubMessage(message)}',
      );
    }
    for (final limitation in limits) {
      output.writeln(
        '::notice title=dartograph limitation::${ReportEscapes.githubMessage(limitation)}',
      );
    }
    return output.toString();
  }

  static String _sarif(List<DuplicationFinding> findings, List<String> limits) {
    final results = findings
        .map(
          (finding) => {
            'level': 'warning',
            'locations': [
              for (final instance in finding.instances)
                {
                  'physicalLocation': {
                    'artifactLocation': {
                      'uri': ReportEscapes.sarifUri(instance.source),
                    },
                    'region': {
                      'endLine': instance.endLine,
                      'startLine': instance.startLine,
                    },
                  },
                },
            ],
            'message': {
              'text':
                  'duplicate-block: ${finding.tokenCount} tokens repeated at '
                  '${finding.instances.map(_describe).join(' and ')}',
            },
            'properties': {'tokenCount': finding.tokenCount},
            'ruleId': 'dup-duplicate-block',
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
              'properties': {'limitations': limits},
            },
          ],
          'results': results,
          'tool': {
            'driver': {
              'name': 'dartograph',
              'rules': [
                {'id': 'dup-duplicate-block'},
              ],
            },
          },
        },
      ],
      'version': '2.1.0',
    })}\n';
  }
}
