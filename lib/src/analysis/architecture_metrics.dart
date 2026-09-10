import '../core/graph_snapshot.dart';

/// 주계열(main sequence) 기준으로 본 정점의 위치(cartograph `MetricsZone` 패리티).
enum MetricsZone {
  /// 추상도와 불안정도가 균형을 이루는 영역(거리 D ≤ 허용 오차).
  mainSequence('main-sequence'),

  /// 구체적인데 많은 곳이 의존한다. 바꾸기 어렵고 바꿔야 할 일은 많다.
  zoneOfPain('zone-of-pain'),

  /// 추상적인데 아무도 의존하지 않는다. 대개 죽은 추상화다.
  zoneOfUselessness('zone-of-uselessness'),

  /// 들어오는 의존도 나가는 의존도 없다. 결합도 지표가 정의되지 않는다.
  ///
  /// 별도 영역으로 두지 않으면 고립 정점이 D=1로 계산되어 "고통의 영역" 1위를
  /// 차지한다. 실제로는 아무와도 얽혀 있지 않은 정점이라 정반대 상황이다.
  isolated('isolated');

  const MetricsZone(this.value);

  /// JSON·표기에 쓰는 값이다.
  final String value;
}

/// 정점 하나의 Robert C. Martin 결합도·추상도 지표다.
final class ArchitectureMetrics {
  /// 손으로 계산하거나 그래프 계산기에서 얻은 지표를 만든다.
  const ArchitectureMetrics({
    required this.id,
    required this.afferentCoupling,
    required this.efferentCoupling,
    required this.abstractness,
  });

  /// 분석 대상 정점 ID다.
  final String id;

  /// Ca: 이 정점에 의존하는 서로 다른 정점 수다.
  final int afferentCoupling;

  /// Ce: 이 정점이 의존하는 서로 다른 정점 수다.
  final int efferentCoupling;

  /// A: 이 대상의 추상 타입 비율이다.
  final double abstractness;

  /// I = Ce / (Ca + Ce). 고립 정점의 0분모는 0으로 정의한다.
  double get instability {
    final denominator = afferentCoupling + efferentCoupling;
    return denominator == 0 ? 0 : efferentCoupling / denominator;
  }

  /// D = |A + I - 1|이다.
  double get distance => (abstractness + instability - 1).abs();

  /// 들어오고 나가는 사용 의존이 모두 없는지 나타낸다.
  bool get isolated => afferentCoupling == 0 && efferentCoupling == 0;

  /// 주어진 허용 오차 기준으로 어느 영역에 있는지 판단한다.
  ///
  /// 고립 정점은 결합도 이야기가 없으므로 별도 영역으로 둔다. 그 외는 주계열
  /// 거리가 [tolerance] 이하면 main-sequence, 넘으면 주계열 아래(A+I < 1,
  /// 구체·안정 = 고통)냐 위(A+I > 1, 추상·무의존 = 무용)냐로 가른다.
  /// `--strict`의 위반 판정(`distance > tolerance`)과 같은 경계다.
  MetricsZone zone(double tolerance) {
    if (isolated) return MetricsZone.isolated;
    if (distance <= tolerance) return MetricsZone.mainSequence;
    return abstractness + instability < 1
        ? MetricsZone.zoneOfPain
        : MetricsZone.zoneOfUselessness;
  }

  /// 결정적인 리포트 값으로 변환한다.
  Map<String, Object> toJson() => {
    'abstractness': abstractness,
    'afferentCoupling': afferentCoupling,
    'distance': distance,
    'efferentCoupling': efferentCoupling,
    'id': id,
    'instability': instability,
    'isolated': isolated,
  };
}

/// 불변 그래프에서 Martin 계열 지표를 계산한다.
final class ArchitectureMetricsCalculator {
  /// 사용 의미의 서로 다른 이웃과 타입 표식을 사용해 지표를 계산한다.
  List<ArchitectureMetrics> calculate(GraphSnapshot graph) {
    final incoming = <String, Set<String>>{};
    final outgoing = <String, Set<String>>{};
    final typeTotals = <String, int>{};
    final abstractTotals = <String, int>{};
    for (final node in graph.nodes) {
      final library = _libraryId(node.id);
      incoming.putIfAbsent(library, () => <String>{});
      outgoing.putIfAbsent(library, () => <String>{});
      if (node.isTypeDeclaration) {
        typeTotals[library] = (typeTotals[library] ?? 0) + 1;
        if (node.isAbstract) {
          abstractTotals[library] = (abstractTotals[library] ?? 0) + 1;
        }
      }
    }
    for (final edge in graph.edges.where((edge) => edge.kind.impliesUsage)) {
      final source = _libraryId(edge.sourceId);
      final target = _libraryId(edge.targetId);
      if (source == target) continue;
      outgoing[source]!.add(target);
      incoming[target]!.add(source);
    }
    final result = incoming.keys.map((library) {
      final total = typeTotals[library] ?? 0;
      final abstractness = total == 0
          ? 0.0
          : (abstractTotals[library] ?? 0) / total;
      return ArchitectureMetrics(
        id: library,
        afferentCoupling: incoming[library]!.length,
        efferentCoupling: outgoing[library]!.length,
        abstractness: abstractness,
      );
    }).toList();
    result.sort((a, b) {
      if (a.isolated != b.isolated) return a.isolated ? 1 : -1;
      final distanceOrder = b.distance.compareTo(a.distance);
      return distanceOrder != 0 ? distanceOrder : a.id.compareTo(b.id);
    });
    return result;
  }
}

String _libraryId(String id) => id.split('::').first;
