import 'dart:convert';
import 'report_escapes.dart';

import '../runtime/runtime_facts.dart';
import '../runtime/runtime_verifier.dart';

/// `runtime`이 지원하는 출력 형식이다.
enum RuntimeFormat {
  /// 사람이 읽고 IDE가 경로를 클릭할 수 있는 텍스트다.
  text,

  /// 자동화 소비자를 위한 결정적 JSON이다.
  json,

  /// 사람과 AI가 모두 읽는 Markdown 리포트다.
  markdown,

  /// GitHub Actions workflow command다.
  githubActions,

  /// 정적 분석 도구 교환 형식 SARIF 2.1.0이다.
  sarif,
}

/// 런타임 의존성 검증 결과를 형식별로 직렬화한다.
///
/// 동적 값(text·markdown·github-actions)에는 dead·impact와 같은 제어문자 정책을
/// 적용한다: C0·DEL은 가시 이스케이프로, GitHub property는 퍼센트 인코딩으로
/// 바꿔 진단줄 위조·ANSI 주입·러너 로그 오염을 막는다. 정상 입력은 바이트
/// 불변이다. 형식별 escaping 구현은 dead_reporter·impact_reporter와 같은
/// 규약을 각자 들고 있다(공유 정책, 독립 구현).
abstract final class RuntimeReporter {
  /// [format]에 맞춰 [report]를 렌더링한다.
  static String render(RuntimeFormat format, RuntimeReport report) =>
      switch (format) {
        RuntimeFormat.text => _text(report),
        RuntimeFormat.json => _json(report),
        RuntimeFormat.markdown => _markdown(report),
        RuntimeFormat.githubActions => _githubActions(report),
        RuntimeFormat.sarif => _sarif(report),
      };

  static Map<String, Object?> _document(RuntimeReport report) => {
    'detected': {
      for (final kind in RuntimeFactKind.values)
        kind.key: [
          for (final fact in report.detected[kind] ?? const <RuntimeFact>[])
            fact.toJson(),
        ],
    },
    'verified': {
      'present': [for (final item in report.present) item.toJson()],
      'defaulted': [for (final item in report.defaulted) item.toJson()],
      'missing': [for (final item in report.missing) item.toJson()],
    },
    'unverified': [for (final item in report.unverified) item.toJson()],
    'risk': report.risk.toJson(),
    'execution': report.execution?.toJson(),
    'limitations': report.limitations,
    'truncated': report.truncated.toJson(),
    'version': 1,
  };

  static String _json(RuntimeReport report) =>
      '${jsonEncode(_document(report))}\n';

  static String _text(RuntimeReport report) {
    final output = StringBuffer();
    final counts = [
      for (final kind in RuntimeFactKind.values)
        '${kind.key} ${report.detected[kind]?.length ?? 0}',
    ];
    output.writeln(
      'detected: ${_detectedCount(report)} fact(s) — ${counts.join(', ')}',
    );
    for (final kind in RuntimeFactKind.values) {
      for (final fact in report.detected[kind] ?? const <RuntimeFact>[]) {
        output.writeln(
          '  ${fact.kind.key} ${ReportEscapes.escapeText(fact.name)} at '
          '${_location(fact)} — ${ReportEscapes.escapeText(fact.detail)}',
        );
      }
    }
    if (report.verified) {
      output.writeln(
        'verified: present ${report.present.length}, '
        'defaulted ${report.defaulted.length}, '
        'missing ${report.missing.length}',
      );
      for (final item in report.present) {
        output.writeln(
          '  present ${ReportEscapes.escapeText(item.fact.name)} at '
          '${_location(item.fact)} — ${ReportEscapes.escapeText(item.evidence)}',
        );
      }
      for (final item in report.defaulted) {
        output.writeln(
          '  defaulted ${ReportEscapes.escapeText(item.fact.name)} at '
          '${_location(item.fact)} — ${ReportEscapes.escapeText(item.evidence)}',
        );
      }
      for (final item in report.missing) {
        output.writeln(
          '  missing ${ReportEscapes.escapeText(item.fact.name)} at '
          '${_location(item.fact)} — ${ReportEscapes.escapeText(item.evidence)}',
        );
      }
      output.writeln('unverified: ${report.unverified.length}');
      for (final item in report.unverified) {
        output.writeln(
          '  ${ReportEscapes.escapeText(item.fact.name)} at ${_location(item.fact)} '
          '(${item.fact.channel.key}) — ${ReportEscapes.escapeText(item.reason)}',
        );
      }
      output.writeln('risk: ${report.risk.level} (${report.risk.score}/100)');
      for (final factor in report.risk.factors) {
        output.writeln(
          '  factor ${factor.name} (weight ${factor.weight}): '
          '${ReportEscapes.escapeText(factor.detail)}',
        );
      }
    } else {
      // 판정하지 않았는데 0으로 적으면 "미판정 없음"으로 읽힌다. 건너뛴 사실을
      // 명시한다.
      output.writeln(
        'verification: skipped (--no-verify) — ${_detectedCount(report)} '
        'fact(s) detected without judgement',
      );
    }
    final execution = report.execution;
    if (execution != null) {
      final reason = execution.unresolvedReason;
      if (reason != null) {
        // 실행 파일을 못 찾아 아무것도 실행하지 않았다. "exitCode 0"처럼
        // 읽히는 문장을 내지 않는다.
        output.writeln(
          'execution: dart run ${ReportEscapes.escapeText(execution.entrypoint)} '
          'not run — ${ReportEscapes.escapeText(reason)}',
        );
      } else {
        output.writeln(
          'execution: dart run ${ReportEscapes.escapeText(execution.entrypoint)} '
          'exited ${execution.exitCode}'
          '${execution.timedOut ? ' (timed out)' : ''}',
        );
        final summary = execution.stderrSummary.trim();
        if (summary.isNotEmpty) {
          output.writeln('  stderr: ${ReportEscapes.escapeText(summary)}');
        }
      }
    }
    if (!report.truncated.isEmpty) {
      output.writeln(
        'truncated: ${report.truncated.detected + report.truncated.verified + report.truncated.unverified} '
        'item(s) omitted by --limit',
      );
    }
    for (final limitation in report.limitations) {
      output.writeln('limitation: ${ReportEscapes.escapeText(limitation)}');
    }
    return output.toString();
  }

  static String _markdown(RuntimeReport report) {
    final output = StringBuffer();
    output.writeln('# dartograph runtime report');
    output.writeln();
    output.writeln('## Summary');
    output.writeln();
    output.writeln('| Metric | Value |');
    output.writeln('|---|---:|');
    output.writeln('| Detected facts | ${_detectedCount(report)} |');
    for (final kind in RuntimeFactKind.values) {
      output.writeln(
        '| Detected ${kind.key} | ${report.detected[kind]?.length ?? 0} |',
      );
    }
    output.writeln('| Present | ${report.present.length} |');
    output.writeln('| Defaulted | ${report.defaulted.length} |');
    output.writeln('| Missing | ${report.missing.length} |');
    output.writeln('| Unverified | ${report.unverified.length} |');
    output.writeln(
      '| Risk | ${report.risk.level} (${report.risk.score}/100) |',
    );
    output.writeln();
    output.writeln('## Detected runtime dependencies');
    output.writeln();
    for (final kind in RuntimeFactKind.values) {
      final facts = report.detected[kind] ?? const <RuntimeFact>[];
      output.writeln('### ${kind.key}');
      output.writeln();
      if (facts.isEmpty) {
        output.writeln('_None detected._');
        output.writeln();
        continue;
      }
      output.writeln('| Name | Location | Detail |');
      output.writeln('|---|---|---|');
      for (final fact in facts) {
        output.writeln(
          '| `${ReportEscapes.mdCell(fact.name)}` | `${ReportEscapes.mdCell(_location(fact))}` | '
          '${ReportEscapes.mdCell(fact.detail)} |',
        );
      }
      output.writeln();
    }
    if (report.verified) {
      output.writeln('## Verification');
      output.writeln();
      output.writeln('| Verdict | Name | Location | Evidence |');
      output.writeln('|---|---|---|---|');
      for (final item in [
        ...report.present,
        ...report.defaulted,
        ...report.missing,
      ]) {
        output.writeln(
          '| ${item.verdict.name} | `${ReportEscapes.mdCell(item.fact.name)}` | '
          '`${ReportEscapes.mdCell(_location(item.fact))}` | ${ReportEscapes.mdCell(item.evidence)} |',
        );
      }
      output.writeln();
    }
    output.writeln('## Unverified');
    output.writeln();
    if (report.unverified.isEmpty) {
      output.writeln('_Nothing was left unjudged._');
    } else {
      output.writeln('| Name | Location | Reason |');
      output.writeln('|---|---|---|');
      for (final item in report.unverified) {
        output.writeln(
          '| `${ReportEscapes.mdCell(item.fact.name)}` | '
          '`${ReportEscapes.mdCell(_location(item.fact))}` | ${ReportEscapes.mdCell(item.reason)} |',
        );
      }
    }
    output.writeln();
    output.writeln('## Risk factors');
    output.writeln();
    if (report.risk.factors.isEmpty) {
      output.writeln('_No risk factor contributed to the score._');
    } else {
      output.writeln('| Factor | Weight | Detail |');
      output.writeln('|---|---:|---|');
      for (final factor in report.risk.factors) {
        output.writeln(
          '| ${ReportEscapes.mdCell(factor.name)} | ${factor.weight} | '
          '${ReportEscapes.mdCell(factor.detail)} |',
        );
      }
    }
    final execution = report.execution;
    if (execution != null) {
      output.writeln();
      output.writeln('## Execution');
      output.writeln();
      final reason = execution.unresolvedReason;
      if (reason != null) {
        output.writeln(
          '`dart run ${ReportEscapes.mdCell(execution.entrypoint)}` was not run — '
          '${ReportEscapes.mdCell(reason)}.',
        );
      } else {
        output.writeln(
          '`dart run ${ReportEscapes.mdCell(execution.entrypoint)}` exited '
          '${execution.exitCode}${execution.timedOut ? ' (timed out)' : ''}.',
        );
        if (execution.stderrSummary.trim().isNotEmpty) {
          output.writeln();
          output.writeln('```text');
          output.writeln(execution.stderrSummary.trim());
          output.writeln('```');
        }
      }
    }
    if (!report.truncated.isEmpty) {
      output.writeln();
      output.writeln(
        '_${report.truncated.detected + report.truncated.verified + report.truncated.unverified} '
        'item(s) omitted by --limit._',
      );
    }
    output.writeln();
    output.writeln('## Limitations');
    output.writeln();
    for (final limitation in report.limitations) {
      output.writeln('- ${ReportEscapes.mdCell(limitation)}');
    }
    output.writeln();
    output.writeln(
      '_Detection is a static observation of literals and call patterns. '
      'A missing entry is not proof that the program cannot run, and a present '
      'entry is not proof that it runs._',
    );
    return output.toString();
  }

  static String _githubActions(RuntimeReport report) {
    final output = StringBuffer();
    final command = report.risk.level == 'high' ? 'error' : 'warning';
    output.writeln(
      '::$command title=dartograph runtime::risk ${report.risk.level} '
      '(${report.risk.score}/100): ${report.missing.length} missing, '
      '${report.unverified.length} unverified of ${_detectedCount(report)} '
      'detected runtime dependenc(ies)',
    );
    for (final item in report.missing) {
      final properties = <String>[
        if (item.fact.source.startsWith('project:'))
          'file=${ReportEscapes.githubProperty(ReportEscapes.sourcePath(item.fact.source))}',
        'line=${item.fact.line}',
        'col=${item.fact.column}',
      ];
      output.writeln(
        '::warning ${properties.join(',')},title=dartograph runtime::'
        '${ReportEscapes.githubMessage('missing ${item.fact.kind.key} ${item.fact.name} — '
        '${item.evidence}')}',
      );
    }
    final execution = report.execution;
    if (execution != null && execution.unresolved) {
      output.writeln(
        '::warning title=dartograph runtime::dart run '
        '${ReportEscapes.githubMessage(execution.entrypoint)} was not run — '
        '${ReportEscapes.githubMessage(execution.unresolvedReason!)}',
      );
    } else if (execution != null && !execution.ok) {
      output.writeln(
        '::error title=dartograph runtime::dart run '
        '${ReportEscapes.githubMessage(execution.entrypoint)} exited ${execution.exitCode}',
      );
    }
    for (final limitation in report.limitations) {
      output.writeln(
        '::notice title=dartograph limitation::${ReportEscapes.githubMessage(limitation)}',
      );
    }
    return output.toString();
  }

  static String _sarif(RuntimeReport report) {
    final results = <Map<String, Object?>>[
      for (final item in report.missing)
        _sarifResult(
          item.fact,
          level: report.risk.level == 'high' ? 'error' : 'warning',
          message:
              'runtime ${item.fact.kind.key} ${item.fact.name} is not '
              'satisfied: ${item.evidence}',
          ruleId: 'runtime-missing-${item.fact.kind.key}',
        ),
      for (final item in report.unverified)
        _sarifResult(
          item.fact,
          level: 'note',
          message:
              'runtime ${item.fact.kind.key} ${item.fact.name} could not be '
              'judged: ${item.reason}',
          ruleId: 'runtime-unverified-${item.fact.kind.key}',
        ),
    ];
    final execution = report.execution;
    return '${jsonEncode({
      r'$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
      'runs': [
        {
          'invocations': [
            {
              'executionSuccessful': true,
              'properties': {'execution': execution?.toJson(), 'limitations': report.limitations, 'risk': report.risk.toJson(), 'truncated': report.truncated.toJson()},
            },
          ],
          'results': results,
          'tool': {
            'driver': {
              'name': 'dartograph',
              'rules': [
                for (final kind in RuntimeFactKind.values) ...[
                  {'id': 'runtime-missing-${kind.key}'},
                  {'id': 'runtime-unverified-${kind.key}'},
                ],
              ],
            },
          },
        },
      ],
      'version': '2.1.0',
    })}\n';
  }

  static Map<String, Object?> _sarifResult(
    RuntimeFact fact, {
    required String level,
    required String message,
    required String ruleId,
  }) => {
    'level': level,
    'locations': [
      {
        'physicalLocation': {
          'artifactLocation': {'uri': ReportEscapes.sarifUri(fact.source)},
          'region': {'startColumn': fact.column, 'startLine': fact.line},
        },
      },
    ],
    'message': {'text': message},
    'properties': {
      'channel': fact.channel.key,
      'id': fact.id,
      'kind': fact.kind.key,
      'name': fact.name,
    },
    'ruleId': ruleId,
  };

  static int _detectedCount(RuntimeReport report) =>
      report.detected.values.fold<int>(0, (sum, facts) => sum + facts.length);

  static String _location(RuntimeFact fact) =>
      '${ReportEscapes.escapeText(ReportEscapes.sourcePath(fact.source))}:${fact.line}:${fact.column}';
}
