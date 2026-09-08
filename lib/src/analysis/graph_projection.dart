import '../core/graph_edge.dart';
import '../core/graph_node.dart';
import '../core/graph_snapshot.dart';

/// 그래프를 그릴 해상도다.
///
/// cartograph `GraphLevel`(module·file·type·symbol)에 대응하되, dartograph는
/// 패키지 하나를 분석 단위(의존 패키지는 정점이 아님)로 삼으므로 module은
/// 접으면 단일 정점이 되어 정보가 없다 — file이 가장 거친 해상도다.
/// 값은 거친 순서다.
enum GraphLevel {
  /// 라이브러리(파일) 단위. 모든 선언이 소속 라이브러리로 접힌다.
  file,

  /// 최상위 선언 단위. 멤버가 컨테이너 선언으로 접힌다.
  type,

  /// 선언 단위(기본). 그래프를 있는 그대로 그린다.
  symbol,
}

/// 그래프를 낮은 해상도로 접는 결정적 사영이다.
abstract final class GraphProjection {
  /// [graph]를 [level] 해상도로 접는다.
  ///
  /// 각 정점은 요청 해상도의 가장 가까운 조상 정점으로 접힌다(type: 멤버 →
  /// 컨테이너 선언, file: 모든 선언 → 소속 라이브러리). 조상 정점이 그래프에
  /// 없으면(합성 입력) 정점을 그대로 두어 대표가 항상 실재하게 한다.
  /// 간선은 양끝을 대표로 바꾸고 중복을 제거하며, 접힘으로 생긴 자기 순환은
  /// 버린다(같은 라이브러리·컨테이너 내부 관계는 그 해상도의 사실이 아니다).
  /// 대표 정점은 실재 노드의 필드(sourceUri·line 등)를 보존하고, [GraphSnapshot]
  /// 생성자가 id 순서로 다시 정규화한다.
  static GraphSnapshot atLevel(GraphSnapshot graph, GraphLevel level) {
    if (level == GraphLevel.symbol) return graph;
    final nodeIds = <String>{for (final node in graph.nodes) node.id};
    final representative = <String, String>{
      for (final node in graph.nodes)
        node.id: switch (level) {
          GraphLevel.file => _libraryOf(node.id, nodeIds),
          GraphLevel.type => _containerOf(node.id, nodeIds),
          GraphLevel.symbol => node.id,
        },
    };
    return _project(graph, representative);
  }

  /// 라이브러리 수준 그래프를 경로 앞 [depth]세그먼트로 요약한다
  /// (dependency-cruiser `--collapse` 대응).
  ///
  /// `project:lib/src/a/x.dart`는 depth 2에서 `project:lib/src`로,
  /// `package:name/src/x.dart`는 depth 1에서 `package:name`으로 접힌다.
  /// 세그먼트가 depth 이하면 그대로다. 폴더 대표는 실재 노드가 아니므로
  /// id만 가진 집계 정점으로 만들어진다(폴더는 파일이 아니다 — sourceUri·
  /// line을 발명하지 않는다).
  static GraphSnapshot collapse(GraphSnapshot graph, int depth) {
    if (depth < 1) {
      throw ArgumentError.value(depth, 'depth', 'collapse depth must be >= 1');
    }
    final nodeIds = <String>{for (final node in graph.nodes) node.id};
    final representative = <String, String>{
      for (final node in graph.nodes)
        node.id: _collapsedId(_libraryOf(node.id, nodeIds), depth),
    };
    return _project(graph, representative);
  }

  static String _collapsedId(String id, int depth) {
    for (final scheme in const ['project:', 'package:']) {
      if (!id.startsWith(scheme)) continue;
      final segments = id.substring(scheme.length).split('/');
      if (segments.length <= depth) return id;
      return '$scheme${segments.take(depth).join('/')}';
    }
    return id;
  }

  /// 선언 ID의 소속 라이브러리 ID를 답한다. 라이브러리 노드가 없으면
  /// (합성 입력) 자기 자신을 대표로 둔다.
  static String _libraryOf(String id, Set<String> nodeIds) {
    final separator = id.indexOf('::');
    if (separator < 0) return id;
    final library = id.substring(0, separator);
    return nodeIds.contains(library) ? library : id;
  }

  /// 멤버 ID를 가장 가까운 컨테이너 선언으로 접는다. 컨테이너가 노드로
  /// 없으면 자기 자신을 대표로 둔다.
  static String _containerOf(String id, Set<String> nodeIds) {
    final symbolSeparator = id.indexOf('::');
    if (symbolSeparator < 0) return id;
    var memberSeparator = id.lastIndexOf('.');
    while (memberSeparator > symbolSeparator + 1) {
      final candidate = id.substring(0, memberSeparator);
      if (nodeIds.contains(candidate)) return candidate;
      memberSeparator = id.lastIndexOf('.', memberSeparator - 1);
    }
    return id;
  }

  static GraphSnapshot _project(
    GraphSnapshot graph,
    Map<String, String> representative,
  ) {
    final byId = <String, GraphNode>{
      for (final node in graph.nodes) node.id: node,
    };
    final projected = <String, GraphNode>{};
    for (final node in graph.nodes) {
      final id = representative[node.id]!;
      projected.putIfAbsent(id, () => byId[id] ?? GraphNode(id: id));
    }
    return GraphSnapshot(
      nodes: projected.values,
      edges: [
        for (final edge in graph.edges)
          if (representative[edge.sourceId] != representative[edge.targetId])
            GraphEdge(
              sourceId: representative[edge.sourceId]!,
              targetId: representative[edge.targetId]!,
              kind: edge.kind,
            ),
      ],
    );
  }
}
