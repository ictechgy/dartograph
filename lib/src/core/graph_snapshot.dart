import 'graph_edge.dart';
import 'graph_node.dart';

/// 캐시와 직렬화 경계에서 쓰는 불변 그래프 값이다.
final class GraphSnapshot {
  /// 정점과 간선을 방어 복사하고 결정적인 순서로 고정한다.
  factory GraphSnapshot({
    required Iterable<GraphNode> nodes,
    required Iterable<GraphEdge> edges,
  }) {
    final sortedNodes = nodes.toList()..sort((a, b) => a.id.compareTo(b.id));
    final nodeIds = <String>{};
    for (final node in sortedNodes) {
      if (!nodeIds.add(node.id)) {
        throw ArgumentError.value(node.id, 'nodes', 'duplicate graph node');
      }
    }

    final sortedEdges = edges.toSet().toList()..sort(compareGraphEdges);
    for (final edge in sortedEdges) {
      if (!nodeIds.contains(edge.sourceId) ||
          !nodeIds.contains(edge.targetId)) {
        throw ArgumentError.value(edge, 'edges', 'unknown graph node');
      }
    }

    return GraphSnapshot._(
      List.unmodifiable(sortedNodes),
      List.unmodifiable(sortedEdges),
    );
  }

  const GraphSnapshot._(this.nodes, this.edges);

  /// 안정적인 ID 순서의 불변 정점 목록이다.
  final List<GraphNode> nodes;

  /// 출발점, 도착점, 관계 이름 순서의 불변 간선 목록이다.
  final List<GraphEdge> edges;
}
