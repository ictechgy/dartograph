import 'dart:convert';

import '../analysis/affected_analyzer.dart';
import '../analysis/architecture_metrics.dart';
import '../analysis/cycle_detector.dart';
import '../analysis/layer_rules.dart';

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

  /// Martin 지표와 엄격 모드가 사용하는 허용 오차를 보존한다.
  static String metrics(
    Iterable<ArchitectureMetrics> metrics, {
    required Iterable<String> limitations,
    required double tolerance,
  }) =>
      '${jsonEncode({'limitations': limitations.toSet().toList()..sort(), 'metrics': metrics.map((item) => item.toJson()).toList(), 'tolerance': tolerance})}\n';
}
