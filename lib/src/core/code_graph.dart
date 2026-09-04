import 'dart:collection';

import 'graph_edge.dart';
import 'graph_node.dart';
import 'graph_snapshot.dart';

/// 변경 가능한 빌더와 결정론적인 읽기 뷰를 제공하는 그래프다.
final class CodeGraph {
  final Map<String, GraphNode> _nodes = {};
  final Set<GraphEdge> _edges = {};

  /// 안정적인 ID 순서로 매번 만드는 읽기 전용 snapshot이다.
  Map<String, GraphNode> get nodes => UnmodifiableMapView(
    Map.fromEntries(
      _nodes.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
  );

  /// 출발점, 도착점, 관계 이름 순으로 정렬한 간선이다.
  List<GraphEdge> get edges => List.unmodifiable(_sortedEdges(_edges));

  /// 정점 존재 여부를 정렬 snapshot 생성 없이 확인한다.
  bool containsNode(String id) => _nodes.containsKey(id);

  /// 정렬 snapshot 생성 없이 [id]의 정점을 찾는다.
  GraphNode? node(String id) => _nodes[id];

  /// 현재 그래프를 캐시 가능한 불변 값으로 방어 복사한다.
  GraphSnapshot snapshot() =>
      GraphSnapshot(nodes: _nodes.values, edges: _edges);

  /// 모호한 중복 ID를 거부하면서 [node]를 추가한다.
  void addNode(GraphNode node) {
    if (_nodes.containsKey(node.id)) {
      throw ArgumentError.value(node.id, 'node.id', 'duplicate graph node');
    }
    _nodes[node.id] = node;
  }

  /// 양 끝 정점이 모두 있는지 확인한 뒤 [edge]를 추가한다.
  ///
  /// 동일한 간선을 여러 번 추가하면 한 번만 남는다.
  void addEdge(GraphEdge edge) {
    if (!_nodes.containsKey(edge.sourceId)) {
      throw ArgumentError.value(
        edge.sourceId,
        'edge.sourceId',
        'unknown graph node',
      );
    }
    if (!_nodes.containsKey(edge.targetId)) {
      throw ArgumentError.value(
        edge.targetId,
        'edge.targetId',
        'unknown graph node',
      );
    }
    _edges.add(edge);
  }

  /// 사용을 성립시키는 바깥 방향 간선을 결정론적인 순서로 돌려준다.
  ///
  /// [nodeId]가 그래프에 없으면 빈 목록을 돌려준다.
  List<GraphEdge> usageEdgesFrom(String nodeId) => List.unmodifiable(
    _sortedEdges(
      _edges.where((edge) => edge.sourceId == nodeId && edge.kind.impliesUsage),
    ),
  );

  static List<GraphEdge> _sortedEdges(Iterable<GraphEdge> edges) =>
      edges.toList()..sort((a, b) {
        final sourceOrder = a.sourceId.compareTo(b.sourceId);
        if (sourceOrder != 0) return sourceOrder;
        final targetOrder = a.targetId.compareTo(b.targetId);
        if (targetOrder != 0) return targetOrder;
        return a.kind.name.compareTo(b.kind.name);
      });
}
