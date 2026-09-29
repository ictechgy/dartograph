import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../analysis/language_traversal.dart';
import '../core/graph_node.dart';
import '../core/graph_snapshot.dart';
import '../core/tool_info.dart';

/// 정점 하나가 싣는 root 인덱스 상한이다(LANGUAGE-TRAVERSAL v1).
const maxRootsPerReached = 64;

const _maxRelationships = 32;

/// `language-traversal` v1 문서의 문서 수준 값이다.
final class LanguageTraversalMetadata {
  /// 필드를 받는다.
  const LanguageTraversalMetadata({
    required this.generatedAt,
    required this.project,
    required this.packageRoot,
    required this.graphRevision,
    this.revision,
  });

  /// 문서 추출 시각이다(UTC 밀리초로 싣는다).
  final DateTime generatedAt;

  /// bridge-facts와 같은 POSIX realpath다. 위치 경로의 기준이다.
  final String project;

  /// 그래프 `project:` 소스 ID의 기준인 패키지 루트 realpath다.
  final String packageRoot;

  /// [graphRevisionOf]가 만든 그래프 내용 해시다.
  final String graphRevision;

  /// 분석한 소스 revision이다. 모르면 싣지 않는다.
  final String? revision;
}

/// 순회에 쓴 그래프 내용의 `sha256:` 해시다.
///
/// 정점(id·종류 표시)과 간선(양 끝·종류)을 정렬해 담는다. 위치는 넣지 않는다 —
/// 줄만 옮긴 편집은 순회 결과를 바꾸지 않는다. 방향과 무관한 입력만 쓰므로 같은
/// 그래프 위의 정·역방향 문서가 같은 값을 낸다.
String graphRevisionOf(GraphSnapshot graph) {
  final content = {
    'edges': [
      for (final edge in graph.edges)
        [edge.sourceId, edge.targetId, edge.kind.name],
    ],
    'nodes': [
      for (final node in graph.nodes)
        [
          node.id,
          node.isLibrary,
          node.isTypeDeclaration,
          node.isAbstract,
          node.isEnumConstant,
          node.isSealed,
          node.synthesized,
        ],
    ],
  };
  return 'sha256:${sha256.convert(utf8.encode(jsonEncode(content)))}';
}

/// isthmus `trace`가 읽는 `language-traversal` v1 문서를 키 정렬 JSON으로 낸다.
///
/// `dispatch`·`unresolvedCalls`는 싣지 않는다 — dartograph 그래프는 해석하지
/// 못한 호출 지점을 세지 않으므로 완전한 신고를 선언할 수 없다. 대신 모든 도달
/// 정점에 `evidence`를 실어 근거 등급 분류를 선언한다.
String exportLanguageTraversal(
  LanguageTraversalResult result,
  LanguageTraversalMetadata metadata, {
  List<String> limitations = const [],
}) {
  final rootsTruncated = result.reached.any(
    (row) => row.roots.length > maxRootsPerReached,
  );
  final reasons = [
    if (result.depthTruncated) 'depth',
    if (result.reachedTruncated) 'reached-limit',
    if (result.rootNotFound) 'root-not-found',
  ]..sort();
  final document = <String, Object?>{
    'format': 'language-traversal',
    'version': 1,
    'tool': {'name': 'dartograph', 'version': toolVersion},
    'generatedAt': DateTime.fromMillisecondsSinceEpoch(
      metadata.generatedAt.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String(),
    'platform': 'dart',
    'project': metadata.project,
    'revision': ?metadata.revision,
    'graphRevision': metadata.graphRevision,
    'direction': result.direction.name,
    'roots': [for (final root in result.roots) _root(root, metadata)],
    'reached': [for (final row in result.reached) _reached(row, metadata)],
    if (rootsTruncated) 'rootsTruncated': true,
    'truncated': reasons.isNotEmpty,
    if (reasons.isNotEmpty) 'truncationReasons': reasons,
    'limitations': SplayTreeSet<String>.from([
      ...limitations,
      ..._traversalLimitations(result, rootsTruncated),
    ]).toList(),
  };
  return '${const JsonEncoder.withIndent('  ').convert(_sorted(document))}\n';
}

List<String> _traversalLimitations(
  LanguageTraversalResult result,
  bool rootsTruncated,
) {
  final missing = result.roots.where((root) => root.node == null).length;
  return [
    'traversal-evidence: analyzer-resolved graph edges are direct evidence; '
        'an overriding member reaching the member it overrides (dynamic '
        'dispatch) is candidate evidence; bound dispatch is not proven',
    'unresolved-calls-unreported: calls through dynamic receivers, function '
        'values and callbacks have no graph edge and are not counted, so '
        'unresolvedCalls is not reported',
    if (missing > 0)
      'root-not-found: $missing requested root(s) did not match a dartograph '
          'declaration id exactly; pass the symbol.usr of routes facts or an '
          'id from dartograph impact/query',
    if (result.depthTruncated)
      'depth-limit: some reachable declarations are more than '
          '${LanguageTraversal.maxDepth} edge(s) from every root and are not '
          'listed',
    if (result.reachedTruncated)
      'reached-limit: more than ${LanguageTraversal.maxReached} reachable '
          'declarations; the (depth, usr) prefix is listed',
    if (rootsTruncated)
      'roots-per-reached: some declarations are reached from more than '
          '$maxRootsPerReached roots; only the $maxRootsPerReached smallest '
          'root indices are listed',
  ];
}

Map<String, Object?> _root(
  TraversalRoot root,
  LanguageTraversalMetadata metadata,
) => {
  'id': root.id,
  if (root.node != null) 'symbol': _symbol(root.node!, metadata),
};

Map<String, Object?> _reached(
  TraversalReached row,
  LanguageTraversalMetadata metadata,
) => {
  'symbol': _symbol(row.node, metadata),
  'via': row.via,
  'depth': row.depth,
  'roots': row.roots.take(maxRootsPerReached).toList(),
  if (row.relationships.isNotEmpty)
    'relationships': row.relationships.take(_maxRelationships).toList(),
  'evidence': row.evidence.name,
};

/// 줄은 싣고 열은 싣지 않는다 — 그래프 정점의 열은 UTF-16 단위라 교환
/// 사실의 UTF-8 바이트 열과 단위가 다르다.
Map<String, Object?> _symbol(
  GraphNode node,
  LanguageTraversalMetadata metadata,
) {
  final separator = node.id.indexOf('::');
  final path = _projectPath(node.sourceUri, metadata);
  return {
    'usr': node.id,
    'qualifiedName': separator < 0 ? node.id : node.id.substring(separator + 2),
    'kind': _kind(node),
    if (path != null)
      'location': {'path': path, if (node.line != null) 'line': node.line},
  };
}

String _kind(GraphNode node) {
  if (node.isLibrary) return 'library';
  if (node.isTypeDeclaration) return 'type';
  if (node.isEnumConstant) return 'enum-constant';
  return 'declaration';
}

/// 패키지 루트 기준 `project:` 소스를 문서 `project` 기준 POSIX 경로로 바꾼다.
String? _projectPath(String? sourceUri, LanguageTraversalMetadata metadata) {
  if (sourceUri == null || !sourceUri.startsWith('project:')) return null;
  final relative = sourceUri.substring('project:'.length);
  final absolute = p.join(metadata.packageRoot, relative);
  return p.posix.joinAll(p.split(p.relative(absolute, from: metadata.project)));
}

Object? _sorted(Object? value) {
  if (value is Map<String, Object?>) {
    return SplayTreeMap<String, Object?>.from(
      value.map((key, item) => MapEntry(key, _sorted(item))),
    );
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}
