import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/export/graph_exporter.dart';
import 'package:test/test.dart';

void main() {
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
