import 'dart:convert';

import '../analysis/affected_analyzer.dart';
import '../analysis/architecture_metrics.dart';
import '../analysis/cycle_detector.dart';
import '../analysis/layer_rules.dart';
import '../analysis/symbol_query.dart';
import '../core/graph_node.dart';
import 'report_escapes.dart';

/// `cycles`·`rules`·`metrics`가 받는 출력 형식이다.
///
/// 기본값은 기존 JSON 계약이라 플래그가 없는 호출의 출력은 바이트 동일하다.
/// SARIF는 아키텍처 게이트를 GitHub code scanning에 올리기 위한 것이고, text는
/// 사람이 읽는 결정적 요약이다.
enum AnalysisFormat {
  /// 사람이 읽는 결정적 요약이다.
  text,

  /// 기존 JSON 계약이다(기본값).
  json,

  /// GitHub code scanning용 SARIF 2.1.0 문서다.
  sarif,
}

/// Phase 5 그래프 질의 결과를 결정적인 JSON·text·SARIF로 직렬화한다.
abstract final class AnalysisReporter {
  /// 변경 라이브러리, 전이적 종속자, 분석 한계를 보존한다.
  static String affected(
    AffectedResult result, {
    required Iterable<String> limitations,
    AnalysisFormat format = AnalysisFormat.json,
    Map<String, GraphNode> nodeSources = const {},
  }) {
    final limits = limitations.toSet().toList()..sort();
    return switch (format) {
      AnalysisFormat.json =>
        '${jsonEncode({'affected': result.affected.map((item) => item.toJson()).toList(), 'changed': result.changed, 'limitations': limits})}\n',
      AnalysisFormat.text => _affectedText(result, limits),
      AnalysisFormat.sarif => _sarif(
        limitations: limits,
        results: [
          for (final item in result.affected)
            _affectedResult(item, nodeSources),
        ],
        rules: const ['dartograph-affected'],
      ),
    };
  }

  /// 두 그래프 비교 문서(`compareGraphs`)를 text·SARIF로도 낸다.
  ///
  /// JSON은 기존 `encodeSymbolQueryDocument(document)`를 그대로 써 바이트를
  /// 보존한다. text·SARIF는 `newlyUnreachable`(관측된 도달성 손실)만 finding으로
  /// 내고, added/removed 집계는 text에만 요약한다 — 비교는 인과 증명이 아니다.
  static String compare(
    Map<String, Object?> document, {
    AnalysisFormat format = AnalysisFormat.json,
    Map<String, GraphNode> nodeSources = const {},
  }) {
    if (format == AnalysisFormat.json) {
      return encodeSymbolQueryDocument(document);
    }
    final limits = [...?(document['limitations'] as List?)?.cast<String>()]
      ..sort();
    final losses = (document['newlyUnreachable'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    if (format == AnalysisFormat.text) {
      return _compareText(document, losses, limits);
    }
    return _sarif(
      limitations: limits,
      results: [
        for (final loss in losses) _comparisonResult(loss, nodeSources),
      ],
      rules: const ['dartograph-comparison'],
    );
  }

  /// 순환과 끊을 후보, 근거, 분석 한계를 보존한다.
  static String cycles(
    Iterable<DependencyCycle> cycles, {
    required Iterable<String> limitations,
    AnalysisFormat format = AnalysisFormat.json,
    Map<String, GraphNode> nodeSources = const {},
  }) {
    final limits = limitations.toSet().toList()..sort();
    final items = cycles.toList();
    return switch (format) {
      AnalysisFormat.json =>
        '${jsonEncode({'cycles': items.map((cycle) => cycle.toJson()).toList(), 'limitations': limits})}\n',
      AnalysisFormat.text => _cyclesText(items, limits),
      AnalysisFormat.sarif => _sarif(
        limitations: limits,
        results: [for (final cycle in items) _cycleResult(cycle, nodeSources)],
        rules: const ['dartograph-cycles'],
      ),
    };
  }

  /// 한 정점이 참여하는 순환과 그래프 존재 여부를 근거와 함께 보존한다.
  static String cyclesExplain(
    CycleExplanation explanation, {
    required Iterable<String> limitations,
  }) =>
      '${jsonEncode({'cycles': explanation.cycles.map((cycle) => cycle.toJson()).toList(), 'explain': 'cycles', 'id': explanation.id, 'known': explanation.known, 'limitations': limitations.toSet().toList()..sort()})}\n';

  /// 레이어 위반 경로, 근거, 분석 한계를 보존한다.
  static String rules(
    Iterable<LayerViolation> violations, {
    required Iterable<String> limitations,
    AnalysisFormat format = AnalysisFormat.json,
  }) {
    final limits = limitations.toSet().toList()..sort();
    final items = violations.toList();
    return switch (format) {
      AnalysisFormat.json =>
        '${jsonEncode({'limitations': limits, 'violations': items.map((violation) => violation.toJson()).toList()})}\n',
      AnalysisFormat.text => _rulesText(items, limits),
      AnalysisFormat.sarif => _sarif(
        limitations: limits,
        results: [for (final violation in items) _ruleResult(violation)],
        rules: [
          for (final name in {for (final item in items) item.ruleName})
            'dartograph-rules-$name',
        ]..sort(),
      ),
    };
  }

  /// 한 정점의 레이어 배치·매치 근거와 그 레이어 출발 규칙을 보존한다.
  static String rulesExplain(
    LayerExplanation explanation, {
    required Iterable<String> limitations,
  }) =>
      '${jsonEncode({'explain': 'rules', 'id': explanation.id, 'known': explanation.known, 'layer': explanation.layer, 'limitations': limitations.toSet().toList()..sort(), 'matchedCandidate': explanation.matchedCandidate, 'matchedPattern': explanation.matchedPattern, 'rules': explanation.rules.map((rule) => rule.toJson()).toList()})}\n';

  /// Martin 지표·주계열 영역(zone)과 엄격 모드가 사용하는 허용 오차를 보존한다.
  ///
  /// zone은 관측 시점의 허용 오차에 의존하는 표현 값이라 항목 toJson이 아니라
  /// 여기서 합친다(정렬된 키 순서도 유지된다). [complexity]는 선언 ID → 순환
  /// 복잡도 맵이고 [nodeSources]는 그 정점의 `sourceUri`·행이다 — 상위 10개를
  /// 점수 내림·ID 오름차순으로 낸다. `hotSpots`는 afferent 결합도가 가장 큰
  /// 라이브러리 10개다(수정 시 전이 영향이 큰 정점). [complexityLimit]이 있으면
  /// 초과 선언이 text·SARIF finding이 된다(`--strict` 판정과 같은 경계).
  static String metrics(
    Iterable<ArchitectureMetrics> metrics, {
    required Iterable<String> limitations,
    required double tolerance,
    Map<String, int> complexity = const {},
    Map<String, GraphNode> nodeSources = const {},
    int? complexityLimit,
    AnalysisFormat format = AnalysisFormat.json,
  }) {
    final items = metrics.toList();
    final limits = limitations.toSet().toList()..sort();
    final topComplexity = complexity.entries.toList()
      ..sort((a, b) {
        final order = b.value.compareTo(a.value);
        return order != 0 ? order : a.key.compareTo(b.key);
      });
    final hotSpots =
        [
          for (final item in items)
            if (item.afferentCoupling > 0) item,
        ]..sort((a, b) {
          final order = b.afferentCoupling.compareTo(a.afferentCoupling);
          return order != 0 ? order : a.id.compareTo(b.id);
        });
    if (format != AnalysisFormat.json) {
      final distanceFindings =
          [
            for (final item in items)
              if (!item.isolated && item.distance > tolerance) item,
          ]..sort((a, b) {
            final order = b.distance.compareTo(a.distance);
            return order != 0 ? order : a.id.compareTo(b.id);
          });
      final complexityFindings = [
        if (complexityLimit != null)
          for (final entry in topComplexity)
            if (entry.value > complexityLimit) entry,
      ];
      return format == AnalysisFormat.text
          ? _metricsText(
              distanceFindings,
              complexityFindings,
              tolerance,
              complexityLimit,
              limits,
            )
          : _sarif(
              limitations: limits,
              results: [
                for (final item in distanceFindings)
                  _metricDistanceResult(item, tolerance, nodeSources),
                for (final entry in complexityFindings)
                  _metricComplexityResult(
                    entry.key,
                    entry.value,
                    complexityLimit!,
                    nodeSources,
                  ),
              ],
              rules: const [
                'dartograph-metrics-distance',
                'dartograph-metrics-complexity',
              ],
            );
    }
    return '${jsonEncode({
      'complexity': {
        'maximum': topComplexity.isEmpty ? 0 : topComplexity.first.value,
        'top': [
          for (final entry in topComplexity.take(10)) {'complexity': entry.value, 'id': entry.key, 'source': ?nodeSources[entry.key]?.sourceUri, 'line': ?nodeSources[entry.key]?.line},
        ],
      },
      'hotSpots': [
        for (final item in hotSpots.take(10)) {'afferentCoupling': item.afferentCoupling, 'id': item.id},
      ],
      'limitations': limits,
      'metrics': items.map((item) => {...item.toJson(), 'zone': item.zone(tolerance).value}).toList(),
      'tolerance': tolerance,
    })}\n';
  }

  static String _cyclesText(List<DependencyCycle> cycles, List<String> limits) {
    final output = StringBuffer();
    for (final cycle in cycles) {
      output.writeln(
        'cycle: ${ReportEscapes.escapeText(cycle.path.join(' -> '))}',
      );
      output.writeln(
        '    break: ${ReportEscapes.escapeText(cycle.breakCandidate.from)} -> '
        '${ReportEscapes.escapeText(cycle.breakCandidate.to)} '
        '(${cycle.breakCandidate.kind.name})',
      );
    }
    for (final limitation in limits) {
      output.writeln('limitation: ${ReportEscapes.escapeText(limitation)}');
    }
    output.writeln('cycles: ${cycles.length}');
    return output.toString();
  }

  static String _rulesText(
    List<LayerViolation> violations,
    List<String> limits,
  ) {
    final output = StringBuffer();
    for (final violation in violations) {
      final path = ReportEscapes.escapeText(
        ReportEscapes.sourcePath(violation.source.sourceUri ?? ''),
      );
      final position = violation.source.line == null
          ? path
          : '$path:${violation.source.line}:${violation.source.column ?? 1}';
      output.writeln(
        '$position: warning: ${ReportEscapes.escapeText(violation.ruleName)} '
        '${ReportEscapes.escapeText(violation.fromLayer)} -> '
        '${ReportEscapes.escapeText(violation.toLayer)} '
        '(${ReportEscapes.escapeText(violation.edge.sourceId)} -> '
        '${ReportEscapes.escapeText(violation.edge.targetId)})',
      );
    }
    for (final limitation in limits) {
      output.writeln('limitation: ${ReportEscapes.escapeText(limitation)}');
    }
    output.writeln('violations: ${violations.length}');
    return output.toString();
  }

  static String _metricsText(
    List<ArchitectureMetrics> distanceFindings,
    List<MapEntry<String, int>> complexityFindings,
    double tolerance,
    int? complexityLimit,
    List<String> limits,
  ) {
    final output = StringBuffer();
    for (final item in distanceFindings) {
      output.writeln(
        '${ReportEscapes.escapeText(item.id)}: warning: '
        'main-sequence-distance D=${item.distance} > $tolerance '
        'zone=${item.zone(tolerance).value}',
      );
    }
    for (final entry in complexityFindings) {
      output.writeln(
        '${ReportEscapes.escapeText(entry.key)}: warning: '
        'cyclomatic-complexity ${entry.value} > $complexityLimit',
      );
    }
    for (final limitation in limits) {
      output.writeln('limitation: ${ReportEscapes.escapeText(limitation)}');
    }
    output.writeln(
      'metrics findings: ${distanceFindings.length + complexityFindings.length}',
    );
    return output.toString();
  }

  static Map<String, Object?> _cycleResult(
    DependencyCycle cycle,
    Map<String, GraphNode> nodeSources,
  ) {
    final location =
        _sarifLocation(nodeSources[cycle.breakCandidate.to]) ??
        _sarifLocation(nodeSources[cycle.breakCandidate.from]);
    return {
      'level': 'warning',
      'message': {
        'text':
            'dependency cycle: ${cycle.path.join(' -> ')} '
            '(break ${cycle.breakCandidate.from} -> ${cycle.breakCandidate.to})',
      },
      if (location != null) 'locations': [location],
      'properties': {
        'breakCandidate': {
          'from': cycle.breakCandidate.from,
          'kind': cycle.breakCandidate.kind.name,
          'to': cycle.breakCandidate.to,
        },
        'cycle': cycle.path,
      },
      'ruleId': 'dartograph-cycles',
    };
  }

  static Map<String, Object?> _ruleResult(LayerViolation violation) {
    final location = _sarifLocation(violation.source);
    return {
      'level': 'warning',
      'message': {
        'text':
            'layer rule ${violation.ruleName}: ${violation.fromLayer} -> '
            '${violation.toLayer}',
      },
      if (location != null) 'locations': [location],
      'properties': {
        'edge': {
          'from': violation.edge.sourceId,
          'kind': violation.edge.kind.name,
          'to': violation.edge.targetId,
        },
        'fromLayer': violation.fromLayer,
        'path': violation.path,
        'rule': violation.ruleName,
        'toLayer': violation.toLayer,
      },
      'ruleId': 'dartograph-rules-${violation.ruleName}',
    };
  }

  static Map<String, Object?> _metricDistanceResult(
    ArchitectureMetrics item,
    double tolerance,
    Map<String, GraphNode> nodeSources,
  ) {
    final location = _sarifLocation(nodeSources[item.id]);
    return {
      'level': 'warning',
      'message': {
        'text':
            'main-sequence distance ${item.distance} exceeds tolerance '
            '$tolerance (zone ${item.zone(tolerance).value})',
      },
      if (location != null) 'locations': [location],
      'properties': {
        'abstractness': item.abstractness,
        'afferentCoupling': item.afferentCoupling,
        'distance': item.distance,
        'efferentCoupling': item.efferentCoupling,
        'instability': item.instability,
        'tolerance': tolerance,
        'zone': item.zone(tolerance).value,
      },
      'ruleId': 'dartograph-metrics-distance',
    };
  }

  static Map<String, Object?> _metricComplexityResult(
    String id,
    int value,
    int limit,
    Map<String, GraphNode> nodeSources,
  ) {
    final location = _sarifLocation(nodeSources[id]);
    return {
      'level': 'warning',
      'message': {'text': 'cyclomatic complexity $value exceeds limit $limit'},
      if (location != null) 'locations': [location],
      'properties': {'complexity': value, 'limit': limit},
      'ruleId': 'dartograph-metrics-complexity',
    };
  }

  static String _affectedText(AffectedResult result, List<String> limits) {
    final output = StringBuffer();
    for (final item in result.affected) {
      output.writeln(
        '${ReportEscapes.escapeText(item.id)} (depth ${item.depth}): '
        '${ReportEscapes.escapeText(item.path.join(' -> '))}',
      );
    }
    for (final limitation in limits) {
      output.writeln('limitation: ${ReportEscapes.escapeText(limitation)}');
    }
    output.writeln(
      'affected: ${result.affected.length} library(ies), '
      'changed: ${result.changed.length}',
    );
    return output.toString();
  }

  static Map<String, Object?> _affectedResult(
    AffectedLibrary item,
    Map<String, GraphNode> nodeSources,
  ) {
    final location = _sarifLocation(nodeSources[item.id]);
    return {
      'level': 'warning',
      'message': {'text': 'affected library (depth ${item.depth}): ${item.id}'},
      if (location != null) 'locations': [location],
      'properties': {'depth': item.depth, 'id': item.id, 'path': item.path},
      'ruleId': 'dartograph-affected',
    };
  }

  static String _compareText(
    Map<String, Object?> document,
    List<Map<String, Object?>> losses,
    List<String> limits,
  ) {
    final output = StringBuffer();
    for (final loss in losses) {
      final id = loss['id'] as String? ?? '';
      final removedEdges =
          (loss['removedEdgesOnBeforePath'] as List? ?? const []).length;
      final removedRoots =
          (loss['removedRootsOnBeforePath'] as List? ?? const []).length;
      output.writeln(
        '${ReportEscapes.escapeText(id)}: newly unreachable '
        '(removedEdgesOnBeforePath: $removedEdges, '
        'removedRootsOnBeforePath: $removedRoots)',
      );
    }
    output.writeln(
      'removedNodes: ${(document['removedNodes'] as List? ?? const []).length}  '
      'addedNodes: ${(document['addedNodes'] as List? ?? const []).length}  '
      'removedEdges: ${(document['removedEdges'] as List? ?? const []).length}  '
      'addedEdges: ${(document['addedEdges'] as List? ?? const []).length}',
    );
    for (final limitation in limits) {
      output.writeln('limitation: ${ReportEscapes.escapeText(limitation)}');
    }
    output.writeln('newlyUnreachable: ${losses.length}');
    return output.toString();
  }

  static Map<String, Object?> _comparisonResult(
    Map<String, Object?> loss,
    Map<String, GraphNode> nodeSources,
  ) {
    final id = loss['id'] as String? ?? '';
    final location = _sarifLocation(nodeSources[id]);
    return {
      'level': 'warning',
      'message': {'text': 'newly unreachable: $id'},
      if (location != null) 'locations': [location],
      'properties': loss,
      'ruleId': 'dartograph-comparison',
    };
  }

  static Map<String, Object?>? _sarifLocation(GraphNode? node) {
    if (node == null) return null;
    final source = node.sourceUri;
    if (source == null) return null;
    return {
      'physicalLocation': {
        'artifactLocation': {'uri': ReportEscapes.sarifUri(source)},
        // line이 없으면 1:1 region을 발명하지 않는다(dead SARIF와 같은 규약).
        if (node.line != null)
          'region': {'startColumn': node.column ?? 1, 'startLine': node.line},
      },
    };
  }

  static String _sarif({
    required List<Map<String, Object?>> results,
    required List<String> rules,
    required List<String> limitations,
  }) =>
      '${jsonEncode({
        r'$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
        'runs': [
          {
            'invocations': [
              {
                'executionSuccessful': true,
                'properties': {'limitations': limitations},
              },
            ],
            'results': results,
            'tool': {
              'driver': {
                'name': 'dartograph',
                'rules': [
                  for (final rule in rules) {'id': rule},
                ],
              },
            },
          },
        ],
        'version': '2.1.0',
      })}\n';
}
