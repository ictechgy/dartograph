import 'dart:collection';

import 'graph_edge.dart';
import 'graph_node.dart';
import 'graph_snapshot.dart';

/// 변경 가능한 빌더와 결정론적인 읽기 뷰를 제공하는 그래프다.
final class CodeGraph {
  final Map<String, GraphNode> _nodes = {};
  final Set<GraphEdge> _edges = {};

  // 읽기 뷰는 캐시되고 변경 시 무효화된다. 매 접근마다 전체 재정렬하면
  // export 루프처럼 뷰를 반복적으로 읽는 호출자가 O(접근수 × V log V)를
  // 낸다(감사 P2). 무효화는 addNode/addEdge에서만 일어나므로 뷰 내용은
  // "마지막 변경 시점의 결정적 정렬"로 동일하다.
  Map<String, GraphNode>? _nodesView;
  List<GraphEdge>? _edgesView;

  /// 안정적인 ID 순서의 읽기 전용 snapshot이다. 다음 변경까지 재사용된다.
  Map<String, GraphNode> get nodes => _nodesView ??= UnmodifiableMapView(
    Map.fromEntries(
      _nodes.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
  );

  /// 출발점, 도착점, 관계 이름 순으로 정렬한 간선이다. 다음 변경까지 재사용된다.
  List<GraphEdge> get edges =>
      _edgesView ??= List.unmodifiable(_sortedEdges(_edges));

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
    _nodesView = null;
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
    if (_edges.add(edge)) _edgesView = null;
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
      edges.toList()..sort(compareGraphEdges);
}
