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
  ///
  /// dead 발견에서는 확인한 전체 보존 루트다. `--report-test-only` 발견에서는
  /// 이 선언에 실제로 도달한 witness 테스트 루트 하나로 의미가 좁아진다
  /// (reason `reached only from test code`와 함께 읽는다).
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
    required Set<String> reachableEnumConstants,
    required Map<String, RetentionReason> roots,
    required this.limitations,
  }) : _paths = paths,
       _libraryPaths = libraryPaths,
       _libraryWitnesses = libraryWitnesses,
       _nodeIds = nodeIds,
       _reachableEnumConstants = reachableEnumConstants,
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
  final Set<String> _reachableEnumConstants;
  final Map<String, RetentionReason> _roots;

  /// 전체 결과에 적용되는 분석 한계다.
  final List<String> limitations;

  /// [id]를 보존하는 도달 가능한 멤버 중 첫 번째다.
  ///
  /// [reachableIds]가 정렬되어 있으므로 witness 선택은 결정적이다. 또한 그 값은
  /// `_paths`의 키이므로 돌려준 witness는 반드시 직접 도달 경로를 갖는다.
  /// [explain]이 witness로 한 단계만 재귀하고 끝나는 근거다.
  ///
  /// 라이브러리 ID에는 선언이 `::`로 붙으므로 `'$id.'` 접두는 걸리지 않는다.
  /// 라이브러리는 항상 null이 되어 기존 라이브러리 분기 판정을 바꾸지 않는다.
  String? _reachableMemberOf(String id) => reachableIds
      .where((candidate) => candidate.startsWith('$id.'))
      .firstOrNull;

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
      // 도달 가능한 멤버가 있으면 컨테이너는 보존된다. deadDeclarations도 같은
      // 근거로 제외하므로, 여기서 미도달로 답하면 한 실행에서 상반된 결론이 된다.
      // path·evidence는 witness까지의 실제 체인이라 `path.last == witness`다.
      // 존재하지 않는 멤버→컨테이너 간선을 지어내지 않기 위해 그대로 돌려준다.
      final memberWitness = _reachableMemberOf(id);
      if (memberWitness != null) {
        final witnessExplanation = explain(memberWitness);
        return ReachabilityExplanation(
          id: id,
          reachable: true,
          reason: 'retained by a reachable member',
          rootsChecked: const [],
          path: witnessExplanation.path,
          evidence: witnessExplanation.evidence,
          retentionReason: null,
          limitations: limitations,
          witness: memberWitness,
        );
      }
      // enum 상수는 도달 가능한 enum 컨테이너로 보존된다. deadDeclarations도 같은
      // 근거로 제외하므로, 여기서 미도달로 답하면 한 실행에서 상반된 결론이 된다.
      // path·evidence는 enum 컨테이너까지의 실제 체인이라 컨테이너에서 끝난다.
      if (_reachableEnumConstants.contains(id)) {
        final container = id.substring(0, id.lastIndexOf('.'));
        final containerExplanation = explain(container);
        return ReachabilityExplanation(
          id: id,
          reachable: true,
          reason: 'retained by its reachable enum',
          rootsChecked: const [],
          path: containerExplanation.path,
          evidence: containerExplanation.evidence,
          retentionReason: null,
          limitations: limitations,
          witness: container,
        );
      }
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
    // enum이 도달 가능하면 그 상수도 보존한다. `.values`·switch·직렬화는 상수를
    // 직접 참조하지 않아 usage 간선이 없으므로, 보존하지 않으면 enum 상수가
    // 미도달로 잘못 보고된다(컨테이너 구제는 멤버→컨테이너 단방향이라 상수를 못 살린다).
    final reachableEnumConstants = <String>{};
    for (final node in graph.nodes) {
      if (!node.isEnumConstant) continue;
      final separator = node.id.lastIndexOf('.');
      if (separator < 0) continue;
      final container = node.id.substring(0, separator);
      if (paths.containsKey(container) ||
          reachableContainers.contains(container)) {
        reachableEnumConstants.add(node.id);
      }
    }
    final declarations = graph.nodes
        .where((node) => node.id.contains('::'))
        .where((node) => !paths.containsKey(node.id))
        .where((node) => !reachableContainers.contains(node.id))
        .where((node) => !reachableEnumConstants.contains(node.id))
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
      reachableEnumConstants: reachableEnumConstants,
      roots: sortedRoots,
      limitations: List.unmodifiable(limitations),
    );
  }

  /// 테스트 코드에서만 도달되는 프로덕션 선언을 info 발견으로 반환한다.
  ///
  /// cartograph `dead --report-test-only`와 같은 질문이다. 테스트 디렉터리 루트를
  /// 빼고 도달성을 다시 계산해, 전체 루트로는 살아 있으나 테스트 루트 없이는
  /// 미도달이 되는 **프로덕션** 선언(테스트 디렉터리 밖)을 고른다. 이들은 죽은
  /// 코드가 아니라 "테스트가 유일한 호출자"라는 관측이며 삭제 권고가 아니다.
  /// `@visibleForTesting` 프로덕션 선언은 테스트 디렉터리 밖이라 루트로 남아
  /// 보수적으로 제외된다. 테스트 디렉터리 자체의 선언도 답에서 제외한다.
  List<DeadFinding> testOnlyDeclarations(
    GraphSnapshot graph, {
    required Map<String, RetentionReason> roots,
    List<String> limitations = const [],
  }) {
    final sources = <String, String?>{
      for (final node in graph.nodes) node.id: node.sourceUri,
    };
    final nodeIds = graph.nodes.map((node) => node.id).toSet();
    // 루트 제거는 reason과 source 접두어를 **양쪽** 요구한다. visibleForTesting
    // reason은 테스트 디렉터리 선언과 @visibleForTesting 프로덕션 선언이 공유하므로
    // source로 가르고, reason으로 테스트 관련 루트임을 확인한다. 접두어가 인덱스와
    // 어긋나도 프로덕션 루트를 오제거(거짓 양성)하지 않고 누락(안전)으로 편향된다.
    final nonTestRoots = <String, RetentionReason>{
      for (final entry in roots.entries)
        if (!_isTestRoot(entry.value, sources[entry.key]))
          entry.key: entry.value,
    };
    final testRootsChecked =
        roots.entries
            .where(
              (entry) =>
                  nodeIds.contains(entry.key) &&
                  _isTestRoot(entry.value, sources[entry.key]),
            )
            .map((entry) => entry.key)
            .toList()
          ..sort();
    final withTests = analyze(graph, roots: roots, limitations: limitations);
    final withoutTests = analyze(
      graph,
      roots: nonTestRoots,
      limitations: limitations,
    );
    final deadWithTests = withTests.deadDeclarations
        .map((finding) => finding.id)
        .toSet();
    final findings = <DeadFinding>[];
    for (final finding in withoutTests.deadDeclarations) {
      // 전체 루트에서도 죽었으면 일반 dead 발견이지 테스트 전용이 아니다.
      if (deadWithTests.contains(finding.id)) continue;
      // 테스트 디렉터리 내부 선언은 cartograph와 같이 답에서 제외한다.
      if (_isTestSource(finding.source)) continue;
      // 이 선언을 살리는 실제 테스트 루트를 근거로 쓴다. 전체 테스트 루트를
      // 나열하면 대부분 이 선언에 도달하지 않아 근거가 희석되고 20개를 넘으면
      // 진짜 루트가 잘린다. test-only 선언은 모든 도달 경로가 테스트 루트에서
      // 시작하므로(아니면 테스트 없이도 도달 가능) path.first가 곧 그 루트다.
      final explanation = withTests.explain(finding.id);
      final reachingRoot = explanation.reachable && explanation.path.isNotEmpty
          ? explanation.path.first
          : null;
      findings.add(
        DeadFinding(
          id: finding.id,
          kind: 'declaration',
          source: finding.source,
          line: finding.line,
          column: finding.column,
          reason: 'reached only from test code',
          retentionRootsChecked: reachingRoot != null
              ? [reachingRoot]
              : testRootsChecked,
          limitations: finding.limitations,
        ),
      );
    }
    return findings;
  }
}

/// 테스트 코드의 보존 루트 source 접두어다.
///
/// `analyzer_graph_index.dart`의 `_retentionReason`이 테스트 디렉터리 선언에
/// `visibleForTesting`를 부여하는 접두어와 일치해야 한다. 어긋나면 테스트 전용
/// 도달 판정이 테스트 루트를 잘못 분류하므로 회귀로 고정한다.
const _testSourcePrefixes = [
  'project:test/',
  'project:integration_test/',
  'project:example/test/',
  'project:example/integration_test/',
];

bool _isTestSource(String? source) =>
    source != null && _testSourcePrefixes.any(source.startsWith);

/// 보존 루트를 테스트 루트로 분류한다. reason과 source 접두어를 **양쪽** 요구한다.
///
/// `visibleForTesting` reason은 테스트 디렉터리 선언과 `@visibleForTesting`
/// 프로덕션 선언이 공유하므로 source 접두어로 가른다. 양쪽을 요구하면 인덱스의
/// 테스트 디렉터리 접두어와 `_testSourcePrefixes`가 어긋나도 프로덕션 루트를
/// 오제거(거짓 양성)하지 않고 누락(안전) 쪽으로 편향된다.
bool _isTestRoot(RetentionReason reason, String? source) =>
    reason == RetentionReason.visibleForTesting && _isTestSource(source);

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
  final encoded = separator < 0 ? uri.path : uri.path.substring(separator + 1);
  // Uri.path는 퍼센트 인코딩을 유지한다(%20 등). analyzer가 실제 파일 경로에서 만든
  // source 한계 ID는 디코딩된 경로를 쓰므로, 같은 모양으로 디코딩해야
  // limitationsForSource의 endsWith 매칭이 성립해 그 파일의 한계가 finding에서
  // 조용히 사라지지 않는다.
  return 'project:lib/${Uri.decodeComponent(encoded)}';
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
