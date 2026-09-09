/// 그래프 간선이 나타내는 관계다.
enum EdgeKind {
  /// 호출 가능 선언이 다른 호출 가능 선언을 호출한다.
  call,

  /// 선언이 다른 선언을 참조한다.
  reference,

  /// 타입이 다른 타입을 상속한다.
  inheritance,

  /// 타입이 다른 타입을 구현한다.
  implements,

  /// 타입이 믹스인을 적용한다.
  mixin,

  /// 멤버가 기반 멤버를 재정의한다.
  override,

  /// 선언이 멤버를 포함하지만 그 자체로 사용하지는 않는다.
  member,

  /// 라이브러리가 다른 라이브러리를 import한다.
  import,

  /// 라이브러리가 다른 라이브러리를 export한다.
  export;

  /// 이 관계가 사용 도달성에 기여하는지 나타낸다.
  bool get impliesUsage => this != EdgeKind.member;
}

/// 출발점, 도착점, 관계 이름 순의 총순서다.
///
/// CodeGraph의 읽기 뷰와 GraphSnapshot 정규화가 공유하는 유일한 비교자다 —
/// 결정성 계약이 두 구현으로 갈라지지 않는다.
int compareGraphEdges(GraphEdge a, GraphEdge b) {
  final sourceOrder = a.sourceId.compareTo(b.sourceId);
  if (sourceOrder != 0) return sourceOrder;
  final targetOrder = a.targetId.compareTo(b.targetId);
  if (targetOrder != 0) return targetOrder;
  return a.kind.name.compareTo(b.kind.name);
}

/// 두 그래프 정점 사이의 방향과 종류가 있는 관계다.
final class GraphEdge {
  /// [sourceId]에서 [targetId]로 향하는 간선을 만든다.
  const GraphEdge({
    required this.sourceId,
    required this.targetId,
    required this.kind,
  });

  /// 참조하는 정점의 ID다.
  final String sourceId;

  /// 참조되는 정점의 ID다.
  final String targetId;

  /// 공유 그래프 질의가 사용하는 의미 관계다.
  final EdgeKind kind;

  @override
  bool operator ==(Object other) =>
      other is GraphEdge &&
      sourceId == other.sourceId &&
      targetId == other.targetId &&
      kind == other.kind;

  @override
  int get hashCode => Object.hash(sourceId, targetId, kind);
}
