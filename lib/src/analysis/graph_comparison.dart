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
          beforeLimitations,
          afterLimitations,
        ),
    ],
    'newlyReachable': gains.where(directlyReachable.contains).toList()..sort(),
    'newlyRetainedByMember':
        gains.where((id) => !directlyReachable.contains(id)).toList()..sort(),
    'beforeLimitations': beforeLimitations.toSet().toList()..sort(),
    'afterLimitations': afterLimitations.toSet().toList()..sort(),
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
  final witness = direct.reachable
      ? null
      : old.reachableIds
            .where((candidate) => candidate.startsWith('$id.'))
            .firstOrNull;
  final explanation = witness == null ? direct : old.explain(witness);
  return {
    'id': id,
    'retainedByMember': ?witness,
    'beforePath': explanation.path,
    'beforeLimitations': beforeLimitations.toSet().toList()..sort(),
    'afterLimitations': afterLimitations.toSet().toList()..sort(),
    'removedEdgesOnBeforePath': explanation.evidence
        .where((e) => !newEdges.contains(e))
        .map(_edge)
        .toList(),
    'removedRootsOnBeforePath': explanation.path
        .where(removedRoots.contains)
        .toList(),
  };
}
