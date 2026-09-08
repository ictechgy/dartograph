import 'dart:convert';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/export/graph_exporter.dart';
import 'package:test/test.dart';

void main() {
  const payloadMarker = '<script id="graph-data" type="application/json">';

  String payloadOf(String html) {
    final begin = html.indexOf(payloadMarker);
    expect(begin, isNot(-1), reason: 'payload script tag missing');
    final end = html.indexOf('</script>', begin);
    expect(end, isNot(-1), reason: 'payload script tag not closed');
    return html.substring(begin + payloadMarker.length, end);
  }

  Map<String, Object?> decodePayload(String html) =>
      jsonDecode(payloadOf(html)) as Map<String, Object?>;

  final snapshot = GraphSnapshot(
    nodes: [
      GraphNode(
        id: 'b',
        sourceUri: 'project:lib/b.dart',
        line: 2,
        column: 3,
        synthesized: true,
        isTypeDeclaration: true,
        isAbstract: true,
      ),
      GraphNode(id: 'a'),
    ],
    edges: const [GraphEdge(sourceId: 'b', targetId: 'a', kind: EdgeKind.call)],
  );

  test('JSON graph output has stable sorted keys and facts', () {
    expect(
      GraphExporter.json(snapshot, limitations: const ['single configuration']),
      '{"edges":[{"kind":"call","source":"b","target":"a"}],"limitations":["single configuration"],"nodes":[{"id":"a","isAbstract":false,"isTypeDeclaration":false,"synthesized":false},{"column":3,"id":"b","isAbstract":true,"isTypeDeclaration":true,"line":2,"sourceUri":"project:lib/b.dart","synthesized":true}]}\n',
    );
  });

  test('DOT and Mermaid output are deterministic and escaped', () {
    expect(
      GraphExporter.dot(snapshot, limitations: const ['single configuration']),
      'digraph dartograph {\n  // limitation: single configuration\n  "a";\n  "b" [style=dashed];\n  "b" -> "a" [label="call"];\n}\n',
    );
    expect(
      GraphExporter.mermaid(
        snapshot,
        limitations: const ['single configuration'],
      ),
      'flowchart LR\n  %% limitation: single configuration\n  n0["a"]\n  n1["b"]\n  n1 -->|call| n0\n',
    );
  });

  test('Mermaid escapes quotes, backslashes, and hashes with entity codes', () {
    final special = GraphSnapshot(
      // 두 번째 ID는 escape 결과(`#quot;`·`#92;`)와 겹치는 적대적 원문이다.
      // `#`을 먼저 바꾸므로 코드로 오디코딩되지 않고 원문 그대로 렌더링된다.
      nodes: [
        GraphNode(id: r'q"#\'),
        GraphNode(id: '#quot;#92;'),
      ],
      edges: const [],
    );
    // 따옴표는 인용 문자열을 중간에 끊어 라벨 구조를 깬다. Mermaid 문서는
    // `#quot;`·10진 코드(`#92;`)를 escape로 정의하고, `#` 자체도 코드로
    // 디코딩되므로 먼저 `#35;`로 바꿔야 인코딩이 손실 없다.
    expect(
      GraphExporter.mermaid(special),
      'flowchart LR\n'
      '  n0["#35;quot;#35;92;"]\n'
      '  n1["q#quot;#35;#92;"]\n',
    );
  });

  test('HTML output is self-contained with a deterministic payload', () {
    final html = GraphExporter.html(
      snapshot,
      limitations: const ['single configuration'],
    );

    expect(html, startsWith('<!DOCTYPE html>\n<html lang="en">\n'));
    // 자기완결: 외부 스크립트·스타일·URL 참조가 없다.
    expect(html, isNot(contains('<script src')));
    expect(html, isNot(contains('<link')));
    expect(html, isNot(contains('http://')));
    expect(html, isNot(contains('https://')));
    // limitations는 헤더 목록과 페이로드 양쪽에 실린다.
    expect(html, contains('1 limitation(s)'));
    expect(html, contains('<li>single configuration</li>'));

    final payload = payloadOf(html);
    expect(payload, isNot(contains('<')));
    expect(decodePayload(html), {
      'edges': [
        {'kind': 'call', 'source': 'b', 'target': 'a'},
      ],
      'limitations': ['single configuration'],
      'nodes': [
        {'id': 'a', 'kind': 'library', 'name': 'a', 'synthesized': false},
        {'id': 'b', 'kind': 'library', 'name': 'b', 'synthesized': true},
      ],
    });
  });

  test('HTML node kinds and display names derive from the id shape', () {
    final typed = GraphSnapshot(
      nodes: [
        GraphNode(id: 'package:app/lib/foo.dart'),
        GraphNode(id: 'package:app/lib/foo.dart::Bar', isTypeDeclaration: true),
        GraphNode(id: 'package:app/lib/foo.dart::Bar.baz'),
        GraphNode(id: '<no-library>'),
      ],
      edges: const [],
    );

    final nodes = (decodePayload(GraphExporter.html(typed))['nodes'] as List)
        .cast<Map<String, Object?>>();
    expect(nodes, [
      {
        'id': '<no-library>',
        'kind': 'library',
        'name': '<no-library>',
        'synthesized': false,
      },
      {
        'id': 'package:app/lib/foo.dart',
        'kind': 'library',
        'name': 'foo.dart',
        'synthesized': false,
      },
      {
        'id': 'package:app/lib/foo.dart::Bar',
        'kind': 'type',
        'name': 'Bar',
        'synthesized': false,
      },
      {
        'id': 'package:app/lib/foo.dart::Bar.baz',
        'kind': 'member',
        'name': 'Bar.baz',
        'synthesized': false,
      },
    ]);
  });

  test('HTML truncation keeps the most connected and says so', () {
    final hub = GraphSnapshot(
      nodes: [
        GraphNode(id: 'a'),
        GraphNode(id: 'b'),
        GraphNode(id: 'c'),
        GraphNode(id: 'd'),
        GraphNode(id: 'e'),
        GraphNode(id: 'hub'),
      ],
      edges: const [
        GraphEdge(sourceId: 'hub', targetId: 'a', kind: EdgeKind.import),
        GraphEdge(sourceId: 'hub', targetId: 'b', kind: EdgeKind.import),
        GraphEdge(sourceId: 'hub', targetId: 'c', kind: EdgeKind.import),
        GraphEdge(sourceId: 'hub', targetId: 'd', kind: EdgeKind.import),
      ],
    );

    final html = GraphExporter.html(hub, nodeLimit: 3);
    expect(html, contains('truncated from 6 nodes'));

    final payload = decodePayload(html);
    // degree 내림차순(hub 4) 후 동률 id 오름차순(a·b) — c·d·e는 잘린다.
    expect(payload['truncatedFrom'], 6);
    expect(
      (payload['nodes'] as List).map((node) => (node as Map)['id']).toList(),
      ['a', 'b', 'hub'],
    );
    // 잘린 정점의 간선은 페이로드에 남지 않는다.
    expect(payload['edges'], [
      {'kind': 'import', 'source': 'hub', 'target': 'a'},
      {'kind': 'import', 'source': 'hub', 'target': 'b'},
    ]);
  });

  test('HTML escapes angle brackets inside the JSON payload', () {
    final special = GraphSnapshot(
      nodes: [GraphNode(id: '<no-library>')],
      edges: const [],
    );

    final html = GraphExporter.html(special);
    // `<!--<script`류 토크나이저 함정: 페이로드에 여는 꺾쇠가 raw로 남지 않는다.
    // `>`는 script 데이터 상태에서 토크나이저 위험이 없어 raw로 둔다(cartograph 동일).
    expect(payloadOf(html), isNot(contains('<')));
    expect(payloadOf(html), contains(r'\u003cno-library>'));
    // JSON 파싱 결과는 이스케이프 전과 같다.
    expect(decodePayload(html)['nodes'], [
      {
        'id': '<no-library>',
        'kind': 'library',
        'name': '<no-library>',
        'synthesized': false,
      },
    ]);
  });

  test('Mermaid escapes angle brackets and ampersands in its own node ids', () {
    final special = GraphSnapshot(
      nodes: [
        GraphNode(id: '<no-library>'),
        GraphNode(id: 'a&b'),
      ],
      edges: const [],
    );
    // DOT용 백슬래시 escape가 아니라 HTML 엔티티로 처리해, dartograph가 스스로 만든
    // `<no-library>` 같은 노드 ID를 Mermaid가 HTML 태그로 오해하지 않게 한다.
    expect(
      GraphExporter.mermaid(special),
      'flowchart LR\n  n0["&lt;no-library&gt;"]\n  n1["a&amp;b"]\n',
    );
  });
}
