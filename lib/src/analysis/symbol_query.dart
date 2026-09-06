import 'dart:collection';
import 'dart:convert';

import '../core/graph_edge.dart';
import '../core/graph_node.dart';
import '../core/graph_snapshot.dart';
import 'reachability_analyzer.dart';

/// cartograph의 SymbolQueryDocument 필드 계약으로 그래프 하나를 질의한다.
Map<String, Object?> querySymbol({
  required GraphSnapshot graph,
  required Map<String, RetentionReason> roots,
  required String requested,
  required List<String> limitations,
  Set<String> suppressedIds = const {},
}) => SymbolQuerySession(
  graph: graph,
  roots: roots,
  limitations: limitations,
).query(requested, suppressedIds: suppressedIds);

/// 한 그래프의 도달성과 이름·이웃 색인을 여러 질의가 공유한다.
final class SymbolQuerySession {
  /// 입력을 고정해 일괄 질의 중 결과가 바뀌지 않게 한다.
  SymbolQuerySession({
    required this.graph,
    required Map<String, RetentionReason> roots,
    required List<String> limitations,
  }) : roots = Map.unmodifiable(roots),
       limitations = List.unmodifiable(limitations) {
    analysis = ReachabilityAnalyzer().analyze(
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

  /// 일괄 baseline 처리에도 재사용하는 도달성 결과다.
  late final ReachabilityResult analysis;
  final Map<String, GraphNode> _nodes = {};
  final Map<String, List<GraphNode>> _names = {};
  final Map<String, List<GraphEdge>> _outgoing = {};
  final Map<String, List<GraphEdge>> _incoming = {};

  /// 기존 단일 질의와 같은 문서 계약으로 한 요청을 처리한다.
  Map<String, Object?> query(
    String requested, {
    Set<String> suppressedIds = const {},
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
    final explanation = analysis.explain(node.id);
    final reachableMember = analysis.reachableIds
        .where((id) => id.startsWith('${node.id}.'))
        .firstOrNull;
    // 직접 도달을 먼저 가른다. explain은 멤버로 보존된 컨테이너도 reachable로
    // 답하므로, reachable만 보면 witness가 있는 보존을 직접 도달과 섞게 된다.
    final state = roots.containsKey(node.id)
        ? 'retained'
        : analysis.reachableIds.contains(node.id)
        ? 'reachable'
        : reachableMember != null
        ? 'retainedByMember'
        : explanation.reachable
        ? 'reachable'
        : 'unreachable';
    final path = switch (state) {
      'retained' => [node.id],
      'reachable' => explanation.path,
      'retainedByMember' => analysis.explain(reachableMember!).path,
      _ => null,
    };
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
        'usedBy': _neighbors(node.id, reverse: true),
        'dependsOn': _neighbors(node.id),
        'members': _neighbors(node.id, members: true),
        'declaredIn': _neighbors(
          node.id,
          reverse: true,
          members: true,
        ).firstOrNull,
        'truncated': {'usedBy': false, 'dependsOn': false, 'members': false},
      },
    );
  }

  List<Map<String, Object?>> _neighbors(
    String id, {
    bool reverse = false,
    bool members = false,
  }) {
    final grouped = <String, List<GraphEdge>>{};
    for (final edge
        in (reverse ? _incoming : _outgoing)[id] ?? const <GraphEdge>[]) {
      if ((edge.kind == EdgeKind.member) != members) continue;
      grouped
          .putIfAbsent(reverse ? edge.sourceId : edge.targetId, () => [])
          .add(edge);
    }
    return _describeNeighbors(_nodes, grouped);
  }
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

List<Map<String, Object?>> _describeNeighbors(
  Map<String, GraphNode> nodes,
  Map<String, List<GraphEdge>> grouped,
) {
  final result = <Map<String, Object?>>[];
  for (final id in grouped.keys.toList()..sort()) {
    final node = nodes[id]!;
    result.add(
      {
        ..._subject(node),
        'edges': grouped[id]!.map((edge) => edge.kind.name).toSet().toList()
          ..sort(),
        'depth': 1,
      }..remove('accessibility'),
    );
  }
  return result;
}

String _simpleName(String id) => id.split('::').last.split('.').last;
