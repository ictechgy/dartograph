import 'dart:collection';

import '../core/graph_edge.dart';
import '../core/graph_snapshot.dart';
import '../core/retention_reason.dart';

export '../core/retention_reason.dart';

/// 도달하지 않는 선언이나 파일을 뒷받침하는 비삭제 판정이다.
final class DeadFinding {
  /// 보고 대상과 근거를 보존한다.
  const DeadFinding({
    required this.id,
    required this.kind,
    required this.source,
    required this.reason,
    required this.retentionRootsChecked,
    this.line,
    this.column,
    this.limitations = const [],
  });

  /// 그래프 정점 ID다.
  final String id;

  /// `declaration` 또는 `file`이다.
  final String kind;

  /// 사용자가 확인할 프로젝트 상대 소스다.
  final String source;

  /// 알 수 있을 때의 1부터 시작하는 줄이다.
  final int? line;

  /// 알 수 있을 때의 1부터 시작하는 열이다.
  final int? column;

  /// 발견을 만든 관찰이며 삭제 권고가 아니다.
  final String reason;

  /// 도달성을 시작할 때 실제로 확인한 루트다.
  final List<String> retentionRootsChecked;

  /// 이 발견을 해석할 때 함께 보여야 하는 한계다.
  final List<String> limitations;

  /// 큰 프로젝트에서도 출력 크기가 루트 수×finding 수로 폭증하지 않는 근거다.
  Map<String, Object> get retentionEvidence =>
      _retentionEvidence(retentionRootsChecked);

  /// 키와 목록 순서가 안정적인 JSON 값이다.
  Map<String, Object> toJson() => {
    'column': ?column,
    'evidence': retentionEvidence,
    'id': id,
    'kind': kind,
    'limitations': limitations,
    'line': ?line,
    'reason': reason,
    'source': source,
  };
}

/// 한 정점이 보존되는 경로 또는 미도달 근거다.
final class ReachabilityExplanation {
  /// 설명에 필요한 모든 근거를 보존한다.
  const ReachabilityExplanation({
    required this.id,
    this.known = true,
    required this.reachable,
    required this.reason,
    required this.rootsChecked,
    required this.path,
    required this.evidence,
    required this.retentionReason,
    required this.limitations,
    this.witness,
  });

  /// 설명 대상 ID다.
  final String id;

  /// 대상 ID가 분석 그래프에 실제로 존재하는지 나타낸다.
  final bool known;

  /// 보존 루트에서 도달했는지 나타낸다.
  final bool reachable;

  /// 미도달일 때의 관찰이다.
  final String? reason;

  /// 미도달 판정에서 확인한 루트다.
  final List<String> rootsChecked;

  /// 루트부터 대상까지의 결정적 최단 경로다.
  final List<String> path;

  /// 경로를 구성한 간선이다.
  final List<GraphEdge> evidence;

  /// 경로 시작점의 보존 이유다.
  final RetentionReason? retentionReason;

  /// 파일 도달성을 시작하게 한 선언 ID다.
  final String? witness;

  /// 설명에 적용되는 분석 한계다.
  final List<String> limitations;

  /// 소비자가 분기하기 쉬운 결정적 JSON 값이다.
  Map<String, Object?> toJson() => !known
      ? {
          'id': id,
          'known': false,
          'limitations': limitations,
          'reachable': false,
          'reason': reason,
        }
      : reachable
      ? {
          'evidence': evidence
              .map(
                (edge) => {
                  'from': edge.sourceId,
                  'kind': edge.kind.name,
                  'to': edge.targetId,
                },
              )
              .toList(),
          'id': id,
          'limitations': limitations,
          'path': path,
          'reachable': true,
          'reason': ?reason,
          'retentionReason': ?retentionReason?.name,
          'witness': ?witness,
        }
      : {
          'evidence': _retentionEvidence(rootsChecked),
          'id': id,
          'limitations': limitations,
          'reachable': false,
          'reason': reason,
        };
}

/// 한 번의 도달성 순회에서 나온 선언·파일 발견과 설명 자료다.
final class ReachabilityResult {
  ReachabilityResult._({
    required this.reachableIds,
    required this.deadDeclarations,
    required this.deadFiles,
    required Map<String, _PathStep> paths,
    required Map<String, _PathStep> libraryPaths,
    required Map<String, String> libraryWitnesses,
    required Set<String> nodeIds,
    required Map<String, RetentionReason> roots,
    required this.limitations,
  }) : _paths = paths,
       _libraryPaths = libraryPaths,
       _libraryWitnesses = libraryWitnesses,
       _nodeIds = nodeIds,
       _roots = roots;

  /// 정렬된 도달 선언 ID다.
  final List<String> reachableIds;

  /// 정렬된 미도달 선언 발견이다.
  final List<DeadFinding> deadDeclarations;

  /// 정렬된 미사용 파일 발견이다.
  final List<DeadFinding> deadFiles;

  final Map<String, _PathStep> _paths;
  final Map<String, _PathStep> _libraryPaths;
  final Map<String, String> _libraryWitnesses;
  final Set<String> _nodeIds;
  final Map<String, RetentionReason> _roots;

  /// 전체 결과에 적용되는 분석 한계다.
  final List<String> limitations;

  /// [id]의 보존 경로 또는 모든 루트에서 미도달한 근거를 돌려준다.
  ReachabilityExplanation explain(String id) {
    if (!_nodeIds.contains(id)) {
      return ReachabilityExplanation(
        id: id,
        known: false,
        reachable: false,
        reason: 'not found in graph',
        rootsChecked: const [],
        path: const [],
        evidence: const [],
        retentionReason: null,
        limitations: limitations,
      );
    }
    if (!id.contains('::') && _libraryPaths.containsKey(id)) {
      final ids = <String>[];
      final edges = <GraphEdge>[];
      String? current = id;
      while (current != null) {
        ids.add(current);
        final step = _libraryPaths[current]!;
        if (step.edge != null) edges.add(step.edge!);
        current = step.previous;
      }
      final path = ids.reversed.toList();
      final directRetention = _roots[id];
      return ReachabilityExplanation(
        id: id,
        reachable: true,
        reason: directRetention != null
            ? 'retained as a root'
            : path.length == 1
            ? 'contains a reachable declaration'
            : 'reachable from a library containing a reachable declaration',
        rootsChecked: const [],
        path: path,
        evidence: edges.reversed.toList(),
        retentionReason: directRetention,
        limitations: limitations,
        witness: _libraryWitnesses[id],
      );
    }
    if (!_paths.containsKey(id)) {
      return ReachabilityExplanation(
        id: id,
        reachable: false,
        reason: 'unreachable from all retention roots',
        rootsChecked: _roots.keys.toList(),
        path: const [],
        evidence: const [],
        retentionReason: null,
        limitations: limitations,
      );
    }
    final ids = <String>[];
    final edges = <GraphEdge>[];
    String? current = id;
    while (current != null) {
      ids.add(current);
      final step = _paths[current]!;
      if (step.edge != null) edges.add(step.edge!);
      current = step.previous;
    }
    return ReachabilityExplanation(
      id: id,
      reachable: true,
      reason: null,
      rootsChecked: const [],
      path: ids.reversed.toList(),
      evidence: edges.reversed.toList(),
      retentionReason: _roots[ids.last],
      limitations: limitations,
    );
  }
}

/// `EdgeKind.impliesUsage`만으로 전역 도달성을 계산한다.
final class ReachabilityAnalyzer {
  /// 보존 [roots]에서 그래프를 순회해 선언과 파일 발견을 만든다.
  ReachabilityResult analyze(
    GraphSnapshot graph, {
    required Map<String, RetentionReason> roots,
    List<String> limitations = const [],
  }) {
    final sortedRoots = SplayTreeMap<String, RetentionReason>.from(roots);
    final outgoing = <String, List<GraphEdge>>{};
    for (final edge in graph.edges.where((edge) => edge.kind.impliesUsage)) {
      outgoing.putIfAbsent(edge.sourceId, () => []).add(edge);
    }
    final paths = <String, _PathStep>{};
    final queue = Queue<String>();
    final nodeIds = graph.nodes.map((node) => node.id).toSet();
    for (final root in sortedRoots.keys.where(nodeIds.contains)) {
      paths[root] = const _PathStep(null, null);
      queue.add(root);
    }
    while (queue.isNotEmpty) {
      final source = queue.removeFirst();
      for (final edge in outgoing[source] ?? const []) {
        if (paths.containsKey(edge.targetId)) continue;
        paths[edge.targetId] = _PathStep(source, edge);
        queue.add(edge.targetId);
      }
    }

    final rootsChecked = sortedRoots.keys.where(nodeIds.contains).toList();
    final reachableContainers = <String>{};
    for (final id in paths.keys) {
      final symbolSeparator = id.indexOf('::');
      if (symbolSeparator < 0) continue;
      var memberSeparator = id.lastIndexOf('.');
      while (memberSeparator > symbolSeparator + 1) {
        final candidate = id.substring(0, memberSeparator);
        if (nodeIds.contains(candidate)) reachableContainers.add(candidate);
        memberSeparator = id.lastIndexOf('.', memberSeparator - 1);
      }
    }
    final declarations = graph.nodes
        .where((node) => node.id.contains('::'))
        .where((node) => !paths.containsKey(node.id))
        .where((node) => !reachableContainers.contains(node.id))
        .map(
          (node) => DeadFinding(
            id: node.id,
            kind: 'declaration',
            source: node.sourceUri ?? node.id.split('::').first,
            line: node.line,
            column: node.column,
            reason: 'unreachable from all retention roots',
            retentionRootsChecked: rootsChecked,
            limitations: limitationsForSource(
              limitations,
              node.sourceUri ?? node.id.split('::').first,
            ),
          ),
        )
        .toList();

    final libraryPaths = <String, _PathStep>{};
    final libraryWitnesses = <String, String>{};
    final reachableIds = paths.keys.toList()..sort();
    for (final id in reachableIds.where(
      (id) =>
          !id.contains('::') &&
          (id.startsWith('package:') || id.startsWith('project:')),
    )) {
      if (nodeIds.contains(id)) {
        libraryPaths[id] = const _PathStep(null, null);
      }
    }
    for (final id in reachableIds.where((id) => id.contains('::'))) {
      final library = id.split('::').first;
      if (!nodeIds.contains(library) || libraryPaths.containsKey(library)) {
        continue;
      }
      libraryPaths[library] = const _PathStep(null, null);
      libraryWitnesses[library] = id;
    }
    final libraryQueue = Queue<String>.from(libraryPaths.keys);
    while (libraryQueue.isNotEmpty) {
      final library = libraryQueue.removeFirst();
      for (final edge in outgoing[library] ?? const []) {
        if (!edge.targetId.contains('::') &&
            !libraryPaths.containsKey(edge.targetId)) {
          libraryPaths[edge.targetId] = _PathStep(library, edge);
          final witness = libraryWitnesses[library];
          if (witness != null) libraryWitnesses[edge.targetId] = witness;
          libraryQueue.add(edge.targetId);
        }
      }
    }
    final files = graph.nodes
        .where((node) => !node.id.contains('::'))
        .where((node) => node.id.startsWith('package:'))
        .where((node) => !libraryPaths.containsKey(node.id))
        .map(
          (node) => DeadFinding(
            id: node.id,
            kind: 'file',
            source: _librarySource(node.id),
            reason: 'no reachable declaration or reachable library import',
            retentionRootsChecked: rootsChecked,
            limitations: limitationsForSource(
              limitations,
              _librarySource(node.id),
            ),
          ),
        )
        .toList();
    return ReachabilityResult._(
      reachableIds: (paths.keys.toList()..sort()),
      deadDeclarations: declarations,
      deadFiles: files,
      paths: paths,
      libraryPaths: libraryPaths,
      libraryWitnesses: libraryWitnesses,
      nodeIds: nodeIds,
      roots: sortedRoots,
      limitations: List.unmodifiable(limitations),
    );
  }
}

/// 소스 한계는 관측된 파일에만 붙이고 전역 한계는 모든 finding에 보존한다.
List<String> limitationsForSource(List<String> limitations, String source) =>
    limitations
        .where(
          (item) => !item.startsWith('source-') || item.endsWith(': $source'),
        )
        .toSet()
        .toList()
      ..sort();

String _librarySource(String id) {
  final uri = Uri.parse(id);
  final separator = uri.path.indexOf('/');
  final relativePath = separator < 0
      ? uri.path
      : uri.path.substring(separator + 1);
  return 'project:lib/$relativePath';
}

final class _PathStep {
  const _PathStep(this.previous, this.edge);

  final String? previous;
  final GraphEdge? edge;
}

const _maximumReportedRetentionRoots = 20;

Map<String, Object> _retentionEvidence(List<String> roots) {
  if (roots.length <= _maximumReportedRetentionRoots) {
    return {'retentionRootsChecked': roots};
  }
  return {
    'retentionRootCount': roots.length,
    'retentionRootsChecked': roots
        .take(_maximumReportedRetentionRoots)
        .toList(growable: false),
    'retentionRootsTruncated': true,
  };
}
