import 'dart:convert';

import '../analysis/dependency_audit.dart';
import 'dead_reporter.dart';
import 'report_escapes.dart';

/// `deps`의 의존 위생 발견을 형식별로 직렬화한다.
///
/// 발견은 검토 후보다 — 도구 인지가 잡지 못하는 사용 채널(런타임 로딩·생성
/// 코드 경유 참조)은 여전히 남을 수 있으므로 삭제 지시로 읽지 않는다.
abstract final class DependencyReporter {
  /// 발견과 한계를 결정적으로 렌더링한다.
  static String render(
    ReportFormat format,
    Iterable<DependencyFinding> input, {
    Iterable<String> limitations = const [],
  }) {
    final findings = input.toList()
      ..sort(
        (a, b) => '${a.kind} ${a.name} ${a.manifest ?? ''}'.compareTo(
          '${b.kind} ${b.name} ${b.manifest ?? ''}',
        ),
      );
    final limits = limitations.toSet().toList()..sort();
    return switch (format) {
      ReportFormat.text => _text(findings, limits),
      ReportFormat.json =>
        '${jsonEncode({'findings': findings.map((finding) => finding.toJson()).toList(), 'limitations': limits, 'report': 'deps'})}\n',
      ReportFormat.markdown => _markdown(findings, limits),
      ReportFormat.githubActions => _githubActions(findings, limits),
      ReportFormat.sarif => _sarif(findings, limits),
    };
  }

  static String _text(List<DependencyFinding> findings, List<String> limits) {
    final output = StringBuffer();
    for (final finding in findings) {
      output.writeln(
        '${ReportEscapes.escapeText(finding.manifest ?? 'pubspec.yaml')}: '
        'warning: ${ReportEscapes.escapeText(finding.kind)} '
        '${ReportEscapes.escapeText(finding.name)} — '
        '${ReportEscapes.escapeText(finding.reason)}',
      );
      if (finding.sources.isNotEmpty) {
        output.writeln(
          '    evidence: sources=${finding.sources.map(ReportEscapes.sourcePath).map(ReportEscapes.escapeText).join(',')}',
        );
      }
    }
    for (final limitation in limits) {
      output.writeln('limitation: ${ReportEscapes.escapeText(limitation)}');
    }
    output.writeln('deps: ${findings.length} finding(s)');
    return output.toString();
  }

  static String _markdown(
    List<DependencyFinding> findings,
    List<String> limits,
  ) {
    final output = StringBuffer();
    output.writeln('# dartograph deps report');
    output.writeln();
    output.writeln('| Metric | Value |');
    output.writeln('|---|---:|');
    output.writeln('| Report | deps |');
    output.writeln('| Findings | ${findings.length} |');
    output.writeln();
    // 워크스페이스 집계만 Manifest 열을 연다 — 단일 패키지 출력은 그대로다.
    final manifests = findings.any((finding) => finding.manifest != null);
    output.writeln(
      manifests
          ? '| Severity | Kind | Package | Manifest | Reason | Evidence |'
          : '| Severity | Kind | Package | Reason | Evidence |',
    );
    output.writeln(
      manifests ? '|---|---|---|---|---|---|' : '|---|---|---|---|---|',
    );
    for (final finding in findings) {
      final evidence = finding.sources.isEmpty
          ? '—'
          : finding.sources
                .map(ReportEscapes.sourcePath)
                .map(ReportEscapes.mdCode)
                .join(', ');
      final manifestCell = manifests
          ? '${ReportEscapes.mdCode(finding.manifest ?? 'pubspec.yaml')} | '
          : '';
      output.writeln(
        '| warning | ${ReportEscapes.mdCell(finding.kind)} | '
        '${ReportEscapes.mdCode(finding.name)} | $manifestCell'
        '${ReportEscapes.mdCell(finding.reason)} | $evidence |',
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
    List<DependencyFinding> findings,
    List<String> limits,
  ) {
    final output = StringBuffer();
    for (final finding in findings) {
      final message =
          '${finding.kind} ${finding.name}: ${finding.reason}'
          '${finding.sources.isEmpty ? '' : '; evidence: sources=${finding.sources.map(ReportEscapes.sourcePath).join(',')}'}';
      output.writeln(
        '::warning file=${ReportEscapes.githubProperty(finding.manifest ?? 'pubspec.yaml')},'
        'title=dartograph deps::${ReportEscapes.githubMessage(message)}',
      );
    }
    for (final limitation in limits) {
      output.writeln(
        '::notice title=dartograph limitation::${ReportEscapes.githubMessage(limitation)}',
      );
    }
    return output.toString();
  }

  static String _sarif(List<DependencyFinding> findings, List<String> limits) {
    final rules = findings.map((finding) => finding.kind).toSet().toList()
      ..sort();
    final results = findings
        .map(
          (finding) => {
            'level': 'warning',
            'locations': [
              {
                'physicalLocation': {
                  'artifactLocation': {
                    'uri': ReportEscapes.sarifUri(
                      'project:${finding.manifest ?? 'pubspec.yaml'}',
                    ),
                  },
                },
              },
            ],
            'message': {
              'text': '${finding.kind} ${finding.name}: ${finding.reason}',
            },
            'properties': {
              'kind': finding.kind,
              'name': finding.name,
              'sources': finding.sources,
              if (finding.manifest != null) 'manifest': finding.manifest,
            },
            'ruleId': 'deps-${finding.kind}',
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
                for (final rule in rules) {'id': 'deps-$rule'},
              ],
            },
          },
        },
      ],
      'version': '2.1.0',
    })}\n';
  }
}
