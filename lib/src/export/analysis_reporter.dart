import 'dart:convert';

import '../analysis/affected_analyzer.dart';
import '../analysis/architecture_metrics.dart';
import '../analysis/cycle_detector.dart';
import '../analysis/layer_rules.dart';
import '../core/graph_node.dart';

/// Phase 5 그래프 질의 결과를 결정적인 JSON으로 직렬화한다.
abstract final class AnalysisReporter {
  /// 변경 라이브러리, 전이적 종속자, 분석 한계를 보존한다.
  static String affected(
    AffectedResult result, {
    required Iterable<String> limitations,
  }) =>
      '${jsonEncode({'affected': result.affected.map((item) => item.toJson()).toList(), 'changed': result.changed, 'limitations': limitations.toSet().toList()..sort()})}\n';

  /// 순환과 끊을 후보, 근거, 분석 한계를 보존한다.
  static String cycles(
    Iterable<DependencyCycle> cycles, {
    required Iterable<String> limitations,
  }) =>
      '${jsonEncode({'cycles': cycles.map((cycle) => cycle.toJson()).toList(), 'limitations': limitations.toSet().toList()..sort()})}\n';

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
  }) =>
      '${jsonEncode({'limitations': limitations.toSet().toList()..sort(), 'violations': violations.map((violation) => violation.toJson()).toList()})}\n';

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
  /// 라이브러리 10개다(수정 시 전이 영향이 큰 정점).
  static String metrics(
    Iterable<ArchitectureMetrics> metrics, {
    required Iterable<String> limitations,
    required double tolerance,
    Map<String, int> complexity = const {},
    Map<String, GraphNode> nodeSources = const {},
  }) {
    final items = metrics.toList();
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
      'limitations': limitations.toSet().toList()..sort(),
      'metrics': items.map((item) => {...item.toJson(), 'zone': item.zone(tolerance).value}).toList(),
      'tolerance': tolerance,
    })}\n';
  }
}
