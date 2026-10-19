import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartograph/src/analysis/language_traversal.dart';
import 'package:dartograph/src/core/graph_edge.dart';
import 'package:dartograph/src/core/graph_node.dart';
import 'package:dartograph/src/core/graph_snapshot.dart';
import 'package:dartograph/src/export/language_traversal_exporter.dart';
import 'package:test/test.dart';

import '../support/graph_fixture_support.dart';

/// `language-traversal` 문서의 정점별 root 목록 상한(LANGUAGE-TRAVERSAL v1의
/// `roots` 64개)·`rootsTruncated` 판정과 `graphRevision` 값을 손으로 적은
/// 기대값과 오라클로 확인한다.
void main() {
  final metadata = LanguageTraversalMetadata(
    generatedAt: DateTime.utc(2026),
    project: '/p',
    packageRoot: '/p',
    graphRevision: 'sha256:fixed',
    revision: 'r',
  );
  List<int> range(int start, int end) => [for (var i = start; i < end; i++) i];
  List<String> callees(int count) => [
    for (var i = 1; i <= count; i++) 'r${i.toString().padLeft(2, '0')}',
  ];

  /// hub가 [called]를 부르는 그래프를 dependents로 순회한 문서다. root는
  /// [requested] 순서로 번호가 붙는다.
  Map<String, Object?> hubDocument(
    List<String> called,
    List<String> requested,
  ) {
    final snapshot = GraphSnapshot(
      nodes: [
        GraphNode(id: 'hub'),
        for (final id in called) GraphNode(id: id),
      ],
      edges: [
        for (final id in called)
          GraphEdge(sourceId: 'hub', targetId: id, kind: EdgeKind.call),
      ],
    );
    final result = LanguageTraversal.traverse(
      snapshot,
      requested,
      TraversalDirection.dependents,
    );
    final text = exportLanguageTraversal(result, metadata);
    return jsonDecode(text) as Map<String, Object?>;
  }

  /// 문서의 `reached` 항목이다.
  List<Map<String, Object?>> reachedOf(Map<String, Object?> document) {
    final rows = document['reached']! as List;
    return rows.cast<Map<String, Object?>>();
  }

  test('a vertex reached from 65 roots lists the 64 smallest indices', () {
    final document = hubDocument(callees(65), callees(65));
    final reached = reachedOf(document);
    expect([for (final row in reached) row['via']], ['r01']);
    expect(reached.single['roots'], range(0, 64));
    expect(document['rootsTruncated'], isTrue);
    expect(document['truncated'], isFalse);
    expect(
      document['limitations'],
      contains(
        'roots-per-reached: some declarations are reached from more than 64 '
        'roots; only the 64 smallest root indices are listed',
      ),
    );
  });

  test('a root vertex does not count itself toward the 64-root cap', () {
    // hub 자신이 root 0이고 다른 root 64개(r01…r64)가 hub에 닿는다.
    final document = hubDocument(callees(64), ['hub', ...callees(64)]);
    final reached = reachedOf(document);
    expect([for (final row in reached) row['via']], ['r01']);
    expect(reached.single['roots'], range(1, 65));
    expect(document.containsKey('rootsTruncated'), isFalse);
    expect(document['truncated'], isFalse);
    expect(
      document['limitations'],
      isNot(contains(startsWith('roots-per-reached:'))),
    );
  });

  test('graphRevision hashes the documented node and edge tuples', () {
    final graph = GraphSnapshot(
      nodes: [
        GraphNode(id: 'a', isLibrary: true),
        GraphNode(
          id: 'b',
          isTypeDeclaration: true,
          isAbstract: true,
          isSealed: true,
          synthesized: true,
        ),
        GraphNode(id: 'é"q', isEnumConstant: true),
      ],
      edges: const [
        GraphEdge(sourceId: 'b', targetId: 'a', kind: EdgeKind.call),
      ],
    );
    // 아래 JSON의 UTF-8 바이트를 따로 해시한 값이다.
    // {"edges":[["b","a","call"]],"nodes":[["a",true,false,false,false,false,
    // false],["b",false,true,true,false,true,true],["é\"q",false,false,false,
    // true,false,false]]}
    expect(
      graphRevisionOf(graph),
      'sha256:'
      '9e46ed1185c7b9bdd7107ff0ad8ca4a9b5080c1c81dd1d0d117c6bb3940ea63f',
    );
  });

  test('graphRevision keeps the single-document hash on large graphs', () {
    // 해시 입력을 조각으로 넣더라도 문서 전체를 한 번에 인코딩해 해시하던
    // 값과 같다(오라클). 비 ASCII·짝 없는 서러게이트가 UTF-8 조각 경계를 넘긴다.
    final graph = escapeHeavyGraph(1500);
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
    final whole = sha256.convert(utf8.encode(jsonEncode(content)));
    expect(graphRevisionOf(graph), 'sha256:$whole');
  });
}
