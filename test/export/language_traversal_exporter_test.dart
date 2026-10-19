import 'dart:convert';

import 'package:dartograph/src/analysis/language_traversal.dart';
import 'package:dartograph/src/core/graph_edge.dart';
import 'package:dartograph/src/core/graph_node.dart';
import 'package:dartograph/src/core/graph_snapshot.dart';
import 'package:dartograph/src/export/language_traversal_exporter.dart';
import 'package:test/test.dart';

/// `language-traversal` 문서의 정점별 root 목록 상한(LANGUAGE-TRAVERSAL v1의
/// `roots` 64개)과 `rootsTruncated` 판정을 손으로 적은 기대값으로 확인한다.
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
}
