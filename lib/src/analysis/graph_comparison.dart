import '../core/graph_edge.dart';
import '../core/graph_snapshot.dart';
import 'reachability_analyzer.dart';

/// 동일 프로젝트의 두 그래프에서 관측된 도달성 변화를 근거와 함께 비교한다.
Map<String, Object?> compareGraphs({
  required GraphSnapshot before,
  required GraphSnapshot after,
  required Map<String, RetentionReason> beforeRoots,
  required Map<String, RetentionReason> afterRoots,
  List<String> beforeLimitations = const [],
  List<String> afterLimitations = const [],
}) {
  final oldAnalysis = ReachabilityAnalyzer().analyze(
    before,
    roots: beforeRoots,
    limitations: beforeLimitations,
  );
  final newAnalysis = ReachabilityAnalyzer().analyze(
    after,
    roots: afterRoots,
    limitations: afterLimitations,
  );
  final oldIds = before.nodes.map((n) => n.id).toSet();
  final newIds = after.nodes.map((n) => n.id).toSet();
  final oldDead = oldAnalysis.deadDeclarations.map((f) => f.id).toSet();
  final newDead = newAnalysis.deadDeclarations.map((f) => f.id).toSet();
  final oldEdges = before.edges.toSet();
  final newEdges = after.edges.toSet();
  final removed = before.edges
      .where((edge) => !newEdges.contains(edge))
      .toList();
  final removedRoots = beforeRoots.keys
      .where((id) => !afterRoots.containsKey(id))
      .toSet();
  final losses = newDead.difference(oldDead).intersection(oldIds).toList()
    ..sort();
  final gains = oldDead.difference(newDead).intersection(newIds);
  final directlyReachable = newAnalysis.reachableIds.toSet();
  // limitation 정규화(dedup+sort)를 1회로 hoist한다 — loss마다 재계산하지
  // 않는다(감사 P10 계열, 출력 동일).
  final sortedBeforeLimitations = beforeLimitations.toSet().toList()..sort();
  final sortedAfterLimitations = afterLimitations.toSet().toList()..sort();
  return {
    'format': 'graph-comparison',
    'version': 1,
    'addedNodes': newIds.difference(oldIds).toList()..sort(),
    'removedNodes': oldIds.difference(newIds).toList()..sort(),
    'addedEdges': after.edges
        .where((e) => !oldEdges.contains(e))
        .map(_edge)
        .toList(),
    'removedEdges': removed.map(_edge).toList(),
    'removedRoots': removedRoots.toList()..sort(),
    'addedRoots':
        afterRoots.keys.toSet().difference(beforeRoots.keys.toSet()).toList()
          ..sort(),
    'newlyUnreachable': [
      for (final id in losses)
        _loss(
          id,
          oldAnalysis,
          newEdges,
          removedRoots,
          sortedBeforeLimitations,
          sortedAfterLimitations,
        ),
    ],
    'newlyReachable': gains.where(directlyReachable.contains).toList()..sort(),
    'newlyRetainedByMember':
        gains.where((id) => !directlyReachable.contains(id)).toList()..sort(),
    'beforeLimitations': sortedBeforeLimitations,
    'afterLimitations': sortedAfterLimitations,
    'limitations': [
      'comparison describes observed graphs, not runtime safety or proof of a single causal change',
      'renames appear as removed and added IDs; use matching SDK, dependencies and build configuration',
    ],
  };
}

Map<String, Object> _edge(GraphEdge edge) => {
  'from': edge.sourceId,
  'kind': edge.kind.name,
  'to': edge.targetId,
};

Map<String, Object?> _loss(
  String id,
  ReachabilityResult old,
  Set<GraphEdge> newEdges,
  Set<String> removedRoots,
  List<String> beforeLimitations,
  List<String> afterLimitations,
) {
  final direct = old.explain(id);
  // 직접 도달을 먼저 가른다. explain은 멤버로 보존된 컨테이너도 reachable로
  // 답하므로, reachable만 보면 witness를 남길 대상을 놓친다. 선형 주사 대신
  // 결과 색인을 쓴다(감사 P3 — loss마다 O(R)이었다).
  final witness = old.isReachable(id) ? null : old.reachableMemberOf(id);
  final explanation = witness == null ? direct : old.explain(witness);
  return {
    'id': id,
    'retainedByMember': ?witness,
    'beforePath': explanation.path,
    'beforeLimitations': beforeLimitations,
    'afterLimitations': afterLimitations,
    'removedEdgesOnBeforePath': explanation.evidence
        .where((e) => !newEdges.contains(e))
        .map(_edge)
        .toList(),
    'removedRootsOnBeforePath': explanation.path
        .where(removedRoots.contains)
        .toList(),
  };
}
