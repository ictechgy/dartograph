import 'dart:collection';
import 'dart:convert';

import '../core/graph_edge.dart';
import '../core/graph_node.dart';
import '../core/graph_snapshot.dart';
import 'reachability_analyzer.dart';

/// 한 그래프의 도달성과 이름·이웃 색인을 여러 질의가 공유한다.
final class SymbolQuerySession {
  /// 입력을 고정해 일괄 질의 중 결과가 바뀌지 않게 한다.
  SymbolQuerySession({
    required this.graph,
    required Map<String, RetentionReason> roots,
    required List<String> limitations,
  }) : roots = Map.unmodifiable(roots),
       limitations = List.unmodifiable(limitations) {
    _analysis = ReachabilityAnalyzer().analyze(
      graph,
      roots: this.roots,
      limitations: this.limitations,
    );
    for (final node in graph.nodes) {
      _nodes[node.id] = node;
      for (final name in {
        node.id,
        node.id.split('::').last,
        _simpleName(node.id),
      }) {
        _names.putIfAbsent(name, () => []).add(node);
      }
    }
    for (final edge in graph.edges) {
      _outgoing.putIfAbsent(edge.sourceId, () => []).add(edge);
      _incoming.putIfAbsent(edge.targetId, () => []).add(edge);
    }
  }

  /// 분석에 사용한 불변 그래프다.
  final GraphSnapshot graph;

  /// 질의 사이에 공유하는 보존 루트다.
  final Map<String, RetentionReason> roots;

  /// 모든 응답이 함께 전달하는 분석 한계다.
  final List<String> limitations;

  /// 질의 사이에 공유하는 도달성 결과다. 내부 타입이라 공개 필드로 노출하지
  /// 않고 deadDeclarations로 필요한 발견만 드러내 공개 표면을 좁힌다.
  late final ReachabilityResult _analysis;
  final Map<String, GraphNode> _nodes = {};
  final Map<String, List<GraphNode>> _names = {};
  final Map<String, List<GraphEdge>> _outgoing = {};
  final Map<String, List<GraphEdge>> _incoming = {};

  /// 공유된 도달성 분석이 산출한 미도달 선언 발견의 불변 목록이다.
  ///
  /// 도달성 결과 모델(ReachabilityResult)은 내부 타입으로 남고 이 getter가
  /// 공개 표면을 DeadFinding 목록으로 좁힌다(배럴은 DeadFinding만 export한다).
  /// roots·limitations와 같이 불변으로 감싸 소비자가 결과를 바꾸지 못하게 한다.
  List<DeadFinding> get deadDeclarations =>
      List.unmodifiable(_analysis.deadDeclarations);

  /// 기존 단일 질의와 같은 문서 계약으로 한 요청을 처리한다.
  ///
  /// [depth]는 사용 관계(usedBy·dependsOn)를 따라가는 단계 수이며 최소 1이다.
  /// 포함 관계(members·declaredIn)는 cartograph와 같이 항상 한 단계다.
  /// [limit]은 방향별 이웃 최대 개수며 null이면 제한하지 않는다. 제한으로
  /// 생략하면 `truncated`를 세워 잘린 사실을 숨기지 않는다.
  Map<String, Object?> query(
    String requested, {
    Set<String> suppressedIds = const {},
    int depth = 1,
    int? limit,
  }) {
    final matches = _names[requested] ?? const <GraphNode>[];
    if (matches.isEmpty) {
      return _document('notFound', requested, limitations);
    }
    if (matches.length > 1) {
      return _document(
        'ambiguous',
        requested,
        limitations,
        candidates: [
          for (final node in matches)
            {'qualifiedName': node.id, 'usr': node.id},
        ],
      );
    }
    final node = matches.single;
    final explanation = _analysis.explain(node.id);
    final reachableMember = _analysis.reachableMemberOf(node.id);
    // 직접 도달을 먼저 가른다. explain은 멤버로 보존된 컨테이너도 reachable로
    // 답하므로, reachable만 보면 witness가 있는 보존을 직접 도달과 섞게 된다.
    // 라이브러리는 선언이 `::`로 붙어 reachableMember가 null이므로 마지막
    // explanation.reachable 분기로 떨어져 기존 판정을 유지한다.
    final state = roots.containsKey(node.id)
        ? 'retained'
        : _analysis.isReachable(node.id)
        ? 'reachable'
        : reachableMember != null
        ? 'retainedByMember'
        : explanation.reachable
        ? 'reachable'
        : 'unreachable';
    final path = switch (state) {
      'retained' => [node.id],
      'reachable' => explanation.path,
      'retainedByMember' => _analysis.explain(reachableMember!).path,
      _ => null,
    };
    final usedBy = _usage(node.id, incoming: true, depth: depth, limit: limit);
    final dependsOn = _usage(
      node.id,
      incoming: false,
      depth: depth,
      limit: limit,
    );
    final members = _containment(node.id, incoming: false, limit: limit);
    final declaredIn = _containment(
      node.id,
      incoming: true,
      limit: limit,
    ).neighbors.firstOrNull;
    return _document(
      'found',
      requested,
      limitations,
      result: {
        'subject': _subject(node),
        'reachability': {
          if (state == 'retainedByMember') 'witness': reachableMember,
          'state': state,
          'reason': roots[node.id]?.name,
          'path': path,
          'suppressedByBaseline':
              state == 'unreachable' && suppressedIds.contains(node.id),
        },
        'usedBy': usedBy.neighbors,
        'dependsOn': dependsOn.neighbors,
        'members': members.neighbors,
        'declaredIn': declaredIn,
        'truncated': {
          'usedBy': usedBy.truncated,
          'dependsOn': dependsOn.truncated,
          'members': members.truncated,
        },
      },
    );
  }

  /// 사용 관계(`impliesUsage`) 간선만 따라 BFS로 이웃을 모은다.
  ///
  /// cartograph `GraphNeighborhood.usage`와 같다. `visited`로 최단 깊이만 남기고,
  /// 같은 이웃에 닿는 여러 간선 종류를 모아 id로 정렬하며, [limit]으로 생략하면
  /// `truncated`를 세우고 그 이웃은 더 확장하지 않는다. 요청 깊이 밖은 원래
  /// 조회 범위가 아니므로 truncated로 세지 않는다.
  ({List<Map<String, Object?>> neighbors, bool truncated}) _usage(
    String start, {
    required bool incoming,
    required int depth,
    int? limit,
  }) {
    final cap = limit == null ? null : (limit < 1 ? 1 : limit);
    final collected = <Map<String, Object?>>[];
    final visited = <String>{start};
    var frontier = <String>[start];
    var truncated = false;
    final maxDepth = depth < 1 ? 1 : depth;
    for (var level = 1; level <= maxDepth; level++) {
      final kindsByNeighbor = <String, Set<EdgeKind>>{};
      for (final current in frontier) {
        final edges =
            (incoming ? _incoming : _outgoing)[current] ?? const <GraphEdge>[];
        for (final edge in edges) {
          if (!edge.kind.impliesUsage) continue;
          final other = incoming ? edge.sourceId : edge.targetId;
          if (visited.contains(other)) continue;
          kindsByNeighbor.putIfAbsent(other, () => <EdgeKind>{}).add(edge.kind);
        }
      }
      final next = <String>[];
      for (final other in kindsByNeighbor.keys.toList()..sort()) {
        visited.add(other);
        final node = _nodes[other];
        if (node == null) continue;
        if (cap != null && collected.length >= cap) {
          truncated = true;
          continue;
        }
        collected.add(_neighborMap(node, kindsByNeighbor[other]!, level));
        next.add(other);
      }
      frontier = next;
      if (frontier.isEmpty) break;
    }
    return (neighbors: collected, truncated: truncated);
  }

  /// 포함(`member`) 관계만 한 단계 따라간다. cartograph `containment`와 같다.
  ///
  /// 타입의 멤버가 의존자로 오인되지 않게 사용 관계와 분리하고, [limit]으로
  /// 생략하면 `truncated`를 세운다.
  ({List<Map<String, Object?>> neighbors, bool truncated}) _containment(
    String start, {
    required bool incoming,
    int? limit,
  }) {
    final cap = limit == null ? null : (limit < 1 ? 1 : limit);
    final others = <String>{};
    final edges =
        (incoming ? _incoming : _outgoing)[start] ?? const <GraphEdge>[];
    for (final edge in edges) {
      if (edge.kind != EdgeKind.member) continue;
      others.add(incoming ? edge.sourceId : edge.targetId);
    }
    final collected = <Map<String, Object?>>[];
    var truncated = false;
    for (final other in others.toList()..sort()) {
      final node = _nodes[other];
      if (node == null) continue;
      if (cap != null && collected.length >= cap) {
        truncated = true;
        break;
      }
      collected.add(_neighborMap(node, const {EdgeKind.member}, 1));
    }
    return (neighbors: collected, truncated: truncated);
  }

  Map<String, Object?> _neighborMap(
    GraphNode node,
    Set<EdgeKind> kinds,
    int depth,
  ) => {
    ..._subject(node),
    'edges': kinds.map((kind) => kind.name).toList()..sort(),
    'depth': depth,
  }..remove('accessibility');
}

Map<String, Object?> _document(
  String status,
  String requested,
  List<String> limitations, {
  Object? result,
  Object? candidates,
}) => {
  'status': status,
  'requested': requested,
  'level': 'symbol',
  'limitations': [...limitations]..sort(),
  'result': result,
  'candidates': candidates,
};

/// 질의 문서를 cartograph처럼 재귀 키 정렬 JSON으로 인코딩한다.
String encodeSymbolQueryDocument(Map<String, Object?> document) =>
    '${const JsonEncoder.withIndent('  ').convert(_sortJson(document))}\n';

Object? _sortJson(Object? value) {
  if (value is Map<String, Object?>) {
    return SplayTreeMap<String, Object?>.from(
      value.map((key, item) => MapEntry(key, _sortJson(item))),
    );
  }
  if (value is List) return value.map(_sortJson).toList();
  return value;
}

Map<String, Object?> _subject(GraphNode node) => {
  'name': _simpleName(node.id),
  'qualifiedName': node.id,
  'kind': node.id.contains('::') ? 'declaration' : 'library',
  'module': node.id.split('/').first,
  'usr': node.id,
  'accessibility': 'unknown',
  'location': _location(node),
};

Map<String, Object?>? _location(GraphNode node) => node.sourceUri == null
    ? null
    : {'path': node.sourceUri, 'line': node.line, 'column': node.column};

String _simpleName(String id) => id.split('::').last.split('.').last;
