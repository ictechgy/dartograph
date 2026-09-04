import 'dart:convert';

import '../analysis/architecture_metrics.dart';
import '../analysis/cycle_detector.dart';
import '../analysis/layer_rules.dart';

/// Phase 5 그래프 질의 결과를 결정적인 JSON으로 직렬화한다.
abstract final class AnalysisReporter {
  /// 순환과 끊을 후보, 근거, 분석 한계를 보존한다.
  static String cycles(
    Iterable<DependencyCycle> cycles, {
    required Iterable<String> limitations,
  }) =>
      '${jsonEncode({'cycles': cycles.map((cycle) => cycle.toJson()).toList(), 'limitations': limitations.toSet().toList()..sort()})}\n';

  /// 레이어 위반 경로, 근거, 분석 한계를 보존한다.
  static String rules(
    Iterable<LayerViolation> violations, {
    required Iterable<String> limitations,
  }) =>
      '${jsonEncode({'limitations': limitations.toSet().toList()..sort(), 'violations': violations.map((violation) => violation.toJson()).toList()})}\n';

  /// Martin 지표와 엄격 모드가 사용하는 허용 오차를 보존한다.
  static String metrics(
    Iterable<ArchitectureMetrics> metrics, {
    required Iterable<String> limitations,
    required double tolerance,
  }) =>
      '${jsonEncode({'limitations': limitations.toSet().toList()..sort(), 'metrics': metrics.map((item) => item.toJson()).toList(), 'tolerance': tolerance})}\n';
}
