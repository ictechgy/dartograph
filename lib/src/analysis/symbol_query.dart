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
}) {
  final matches = graph.nodes
      .where(
        (node) =>
            node.id == requested ||
            node.id.split('::').last == requested ||
            _simpleName(node.id) == requested,
      )
      .toList();
  if (matches.isEmpty) {
    return _document('notFound', requested, limitations);
  }
  if (matches.length > 1) {
    return _document(
      'ambiguous',
      requested,
      limitations,
      candidates: [
        for (final node in matches) {'qualifiedName': node.id, 'usr': node.id},
      ],
    );
  }
  final node = matches.single;
  final analysis = ReachabilityAnalyzer().analyze(
    graph,
    roots: roots,
    limitations: limitations,
  );
  final explanation = analysis.explain(node.id);
  final reachableMember = analysis.reachableIds
      .where((id) => id.startsWith('${node.id}.'))
      .firstOrNull;
  final state = roots.containsKey(node.id)
      ? 'retained'
      : explanation.reachable
      ? 'reachable'
      : reachableMember != null
      ? 'retainedByMember'
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
        'state': state,
        'reason': roots[node.id]?.name,
        'path': path,
        'suppressedByBaseline':
            state == 'unreachable' && suppressedIds.contains(node.id),
      },
      'usedBy': _neighbors(graph, node.id, incoming: true),
      'dependsOn': _neighbors(graph, node.id, incoming: false),
      'members': _members(graph, node.id, incoming: false),
      'declaredIn': _members(graph, node.id, incoming: true).firstOrNull,
      'truncated': {'usedBy': false, 'dependsOn': false, 'members': false},
    },
  );
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

List<Map<String, Object?>> _neighbors(
  GraphSnapshot graph,
  String id, {
  required bool incoming,
}) {
  final grouped = <String, List<GraphEdge>>{};
  for (final edge in graph.edges.where(
    (edge) => edge.kind != EdgeKind.member,
  )) {
    if ((incoming ? edge.targetId : edge.sourceId) != id) continue;
    grouped
        .putIfAbsent(incoming ? edge.sourceId : edge.targetId, () => [])
        .add(edge);
  }
  return _describeNeighbors(graph, grouped);
}

List<Map<String, Object?>> _members(
  GraphSnapshot graph,
  String id, {
  required bool incoming,
}) {
  final grouped = <String, List<GraphEdge>>{};
  for (final edge in graph.edges.where(
    (edge) => edge.kind == EdgeKind.member,
  )) {
    if ((incoming ? edge.targetId : edge.sourceId) != id) continue;
    grouped
        .putIfAbsent(incoming ? edge.sourceId : edge.targetId, () => [])
        .add(edge);
  }
  return _describeNeighbors(graph, grouped);
}

List<Map<String, Object?>> _describeNeighbors(
  GraphSnapshot graph,
  Map<String, List<GraphEdge>> grouped,
) {
  final nodes = {for (final node in graph.nodes) node.id: node};
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
