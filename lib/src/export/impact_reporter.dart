import 'dart:convert';

import '../analysis/impact_analyzer.dart';

/// `impact`가 지원하는 출력 형식이다.
enum ImpactFormat {
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

/// 영향 사전 점검 결과를 형식별로 손실 없이 직렬화한다.
///
/// 동적 값(text·markdown·github-actions)에는 dead와 같은 제어문자 정책을
/// 적용한다: C0·DEL은 가시 이스케이프로, GitHub property는 퍼센트 인코딩으로
/// 바꿔 진단줄 위조·ANSI 주입·러너 로그 오염을 막는다. 정상 입력은 바이트 불변이다.
abstract final class ImpactReporter {
  /// [format]에 맞춰 [report]를 렌더링한다.
  static String render(
    ImpactFormat format,
    ImpactReport report, {
    Iterable<String> limitations = const [],
    String? explainId,
    bool? known,
  }) {
    final limits = limitations.toSet().toList()..sort();
    return switch (format) {
      ImpactFormat.text => _text(report, limits),
      ImpactFormat.json => _json(
        report,
        limits,
        explainId: explainId,
        known: known,
      ),
      ImpactFormat.markdown => _markdown(report, limits),
      ImpactFormat.githubActions => _githubActions(report, limits),
      ImpactFormat.sarif => _sarif(report, limits),
    };
  }

  static Map<String, Object> _document(
    ImpactReport report,
    List<String> limits, {
    String? explainId,
    bool? known,
  }) => {
    'callSites': report.callSites.map((item) => item.toJson()).toList(),
    'changed': {
      // 라이브러리 · 심별은 그래프 정점 ID 그대로다(sources만 프로젝트 상대 경로).
      'libraries': report.changedLibraries,
      'sources': report.changedSources.map(_path).toList(),
      'symbols': report.changedSymbols,
      'unattributedSources': report.unattributedSources.map(_path).toList(),
    },
    'coverage': report.coverage.toJson(),
    'explain': ?(explainId == null ? null : 'impact'),
    'id': ?explainId,
    'impacted': report.impacted.map((item) => item.toJson()).toList(),
    'known': ?known,
    'limitations': limits,
    'missingSymbols': report.missingSymbols,
    'risk': report.risk.toJson(),
    'tests': report.tests.map((item) => item.toJson()).toList(),
    'truncated': report.truncatedImpacted,
    'version': 1,
  };

  static String _json(
    ImpactReport report,
    List<String> limits, {
    String? explainId,
    bool? known,
  }) =>
      '${jsonEncode(_document(report, limits, explainId: explainId, known: known))}\n';

  static String _text(ImpactReport report, List<String> limits) {
    final output = StringBuffer();
    output.writeln(
      'changed: ${report.changedSymbols.length} declaration(s), '
      '${report.changedLibraries.length} library(ies), '
      '${report.changedSources.length} source(s)',
    );
    output.writeln('risk: ${report.risk.level} (${report.risk.score}/100)');
    for (final factor in report.risk.factors) {
      output.writeln(
        '  factor ${factor.name} (weight ${factor.weight}): '
        '${_escapeText(factor.detail)}',
      );
    }
    output.writeln(
      'impacted: ${report.coverage.transitivelyImpacted} symbol(s)',
    );
    for (final item in report.impacted) {
      final location = item.source == null
          ? _escapeText(item.id)
          : '${_escapeText(item.source!)}:${item.line ?? 1}:${item.column ?? 1}';
      output.writeln(
        '  $location: ${item.kind} ${_escapeText(item.id)} '
        '— depth ${item.depth}, risk ${item.riskLevel} (${item.riskScore})',
      );
      output.writeln('    path: ${item.path.map(_escapeText).join(' -> ')}');
    }
    if (report.truncated) {
      output.writeln(
        '  ${report.truncatedImpacted} more impacted symbol(s) omitted by --limit',
      );
    }
    output.writeln('tests: ${report.tests.length} related test library(ies)');
    for (final test in report.tests) {
      output.writeln(
        '  ${_escapeText(test.source ?? test.id)}: depth ${test.depth}',
      );
    }
    output.writeln('callSites: ${report.callSites.length}');
    for (final call in report.callSites) {
      final location = call.fromSource == null
          ? _escapeText(call.fromId)
          : '${_escapeText(call.fromSource!)}:${call.fromLine ?? 1}:${call.fromColumn ?? 1}';
      output.writeln(
        '  $location: ${_escapeText(call.fromId)} -> '
        '${_escapeText(call.toId)} (${_escapeText(call.kind)})',
      );
    }
    if (report.missingSymbols.isNotEmpty) {
      output.writeln(
        'missing: ${report.missingSymbols.map(_escapeText).join(', ')}',
      );
    }
    output.writeln(
      'coverage: ${report.coverage.missedWithoutPrecheck.length} impacted '
      'symbol(s) would be missed by inspecting changed files only',
    );
    for (final limitation in limits) {
      output.writeln('limitation: ${_escapeText(limitation)}');
    }
    return output.toString();
  }

  static String _markdown(ImpactReport report, List<String> limits) {
    final output = StringBuffer();
    output.writeln('# dartograph impact report');
    output.writeln();
    output.writeln('## Summary');
    output.writeln();
    output.writeln('| Metric | Value |');
    output.writeln('|---|---:|');
    output.writeln(
      '| Changed declarations | ${report.changedSymbols.length} |',
    );
    output.writeln('| Changed libraries | ${report.changedLibraries.length} |');
    output.writeln(
      '| Impacted symbols | ${report.coverage.transitivelyImpacted} |',
    );
    output.writeln('| Related test libraries | ${report.tests.length} |');
    output.writeln(
      '| Risk | ${report.risk.level} (${report.risk.score}/100) |',
    );
    output.writeln();
    output.writeln('## Risk factors');
    output.writeln();
    output.writeln('| Factor | Weight | Detail |');
    output.writeln('|---|---:|---|');
    for (final factor in report.risk.factors) {
      output.writeln(
        '| ${_mdCell(factor.name)} | ${factor.weight} | '
        '${_mdCell(factor.detail)} |',
      );
    }
    output.writeln();
    output.writeln('## Impacted symbols');
    output.writeln();
    if (report.impacted.isEmpty) {
      output.writeln('_No dependent symbol uses the changed set._');
    } else {
      output.writeln('| Symbol | Kind | Depth | Risk | Location |');
      output.writeln('|---|---|---:|---|---|');
      for (final item in report.impacted) {
        final location = item.source == null
            ? ''
            : '`${_mdCell(item.source!)}:${item.line ?? 1}`';
        output.writeln(
          '| `${_mdCell(item.id)}` | ${item.kind} | ${item.depth} | '
          '${item.riskLevel} (${item.riskScore}) | $location |',
        );
        output.writeln(
          '| ↳ path |  |  |  | `${item.path.map(_mdCell).join(' → ')}` |',
        );
      }
    }
    if (report.truncated) {
      output.writeln();
      output.writeln(
        '_${report.truncatedImpacted} more impacted symbol(s) omitted by --limit._',
      );
    }
    output.writeln();
    output.writeln('## Related tests');
    output.writeln();
    if (report.tests.isEmpty) {
      output.writeln('_No test library depends on the changed set._');
    } else {
      for (final test in report.tests) {
        output.writeln(
          '- `${_mdCell(test.source ?? test.id)}` (depth ${test.depth})',
        );
      }
    }
    output.writeln();
    output.writeln('## Call sites into changed declarations');
    output.writeln();
    if (report.callSites.isEmpty) {
      output.writeln('_No external call site was observed._');
    } else {
      for (final call in report.callSites) {
        final location = call.fromSource == null
            ? ''
            : ' at `${_mdCell(call.fromSource!)}:${call.fromLine ?? 1}:${call.fromColumn ?? 1}`';
        output.writeln(
          '- `${_mdCell(call.fromId)}` → `${_mdCell(call.toId)}` '
          '(${_mdCell(call.kind)})$location',
        );
      }
    }
    output.writeln();
    output.writeln('## Precheck coverage');
    output.writeln();
    output.writeln(
      '${report.coverage.missedWithoutPrecheck.length} impacted symbol(s) would '
      'be missed by inspecting changed files only.',
    );
    if (report.missingSymbols.isNotEmpty) {
      output.writeln();
      output.writeln(
        'Requested symbols absent from the graph: '
        '${report.missingSymbols.map((id) => '`${_mdCell(id)}`').join(', ')}',
      );
    }
    if (limits.isNotEmpty) {
      output.writeln();
      output.writeln('## Limitations');
      output.writeln();
      for (final limitation in limits) {
        output.writeln('- ${_mdCell(limitation)}');
      }
    }
    output.writeln();
    output.writeln(
      '_Impact is an observed dependency reachability, not a deletion verdict. '
      'Dynamic dispatch and unmatched string routes can limit the evidence._',
    );
    return output.toString();
  }

  static String _githubActions(ImpactReport report, List<String> limits) {
    final output = StringBuffer();
    if (report.risk.level == 'high') {
      output.writeln(
        '::warning title=dartograph impact::risk ${report.risk.level} '
        '(${report.risk.score}/100): '
        '${report.coverage.transitivelyImpacted} impacted symbol(s), '
        '${report.tests.length} related test(s)',
      );
    } else {
      output.writeln(
        '::notice title=dartograph impact::risk ${report.risk.level} '
        '(${report.risk.score}/100): '
        '${report.coverage.transitivelyImpacted} impacted symbol(s), '
        '${report.tests.length} related test(s)',
      );
    }
    for (final item in report.impacted) {
      final properties = <String>[];
      if (item.source != null) {
        properties.add('file=${_property(item.source!)}');
      }
      if (item.line != null) {
        properties.add('line=${item.line}');
      }
      if (item.column != null) {
        properties.add('col=${item.column}');
      }
      final command = item.riskLevel == 'high' ? 'warning' : 'notice';
      final prefix = properties.isEmpty ? '' : '${properties.join(',')},';
      output.writeln(
        '::$command ${prefix}title=dartograph impact::'
        '${_message('${item.kind} ${item.id} — depth ${item.depth}, '
        'risk ${item.riskLevel}')}',
      );
    }
    for (final limitation in limits) {
      output.writeln(
        '::notice title=dartograph limitation::${_message(limitation)}',
      );
    }
    return output.toString();
  }

  static String _sarif(ImpactReport report, List<String> limits) {
    final results = <Map<String, Object>>[
      for (final item in report.impacted)
        {
          'level': item.riskLevel == 'high' ? 'warning' : 'note',
          'locations': [
            {
              'physicalLocation': {
                'artifactLocation': {
                  'uri': _sarifUri(
                    item.source == null ? item.id : 'project:${item.source!}',
                  ),
                },
                if (item.line != null)
                  'region': {
                    'startColumn': item.column ?? 1,
                    'startLine': item.line!,
                  },
              },
            },
          ],
          'message': {
            'text':
                '${item.kind} ${item.id} is ${item.depth} usage edge(s) '
                'from the changed set (risk ${item.riskLevel})',
          },
          'properties': {
            'depth': item.depth,
            'id': item.id,
            'kind': item.kind,
            'path': item.path,
            'riskScore': item.riskScore,
          },
          'ruleId': 'impact-${item.kind}',
        },
    ];
    return '${jsonEncode({
      r'$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
      'runs': [
        {
          'invocations': [
            {
              'executionSuccessful': true,
              'properties': {'coverage': report.coverage.toJson(), 'limitations': limits, 'risk': report.risk.toJson()},
            },
          ],
          'results': results,
          'tool': {
            'driver': {
              'name': 'dartograph',
              'rules': [
                {'id': 'impact-declaration'},
                {'id': 'impact-file'},
              ],
            },
          },
        },
      ],
      'version': '2.1.0',
    })}\n';
  }

  /// `project:` 센티널을 벗겨 프로젝트 상대 경로를 남긴다.
  static String _path(String source) => source.startsWith('project:')
      ? source.substring('project:'.length)
      : source;

  /// text·markdown의 C0·DEL 가시 이스케이프(정상 입력은 바이트 불변).
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

  /// Markdown 표 셀: 파이프와 개행을 이스케이프해 표 구조를 지킨다.
  static String _mdCell(String value) =>
      _escapeText(value).replaceAll('|', r'\|');

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
      rune == 0x25 ||
      rune < 0x20 ||
      rune == 0x7f ||
      (rune >= 0x80 && rune <= 0x9f) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      (rune >= 0x202a && rune <= 0x202e) ||
      (rune >= 0x2066 && rune <= 0x2069) ||
      (property && (rune == 0x3a || rune == 0x2c));

  /// SARIF artifact uri. `project:` 소스는 세그먼트 인코딩, 절대 URI는 그대로 둔다.
  static String _sarifUri(String source) => source.startsWith('project:')
      ? Uri(pathSegments: _path(source).split('/')).toString()
      : source;
}
