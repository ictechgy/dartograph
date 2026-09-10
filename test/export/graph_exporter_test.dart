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
      GraphNode(id: 'a', isLibrary: true),
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

  test('DOT colors cycle participants and leaves acyclic bytes unchanged', () {
    final cyclic = GraphSnapshot(
      nodes: [
        GraphNode(id: 'a', isLibrary: true),
        GraphNode(id: 'b'),
        GraphNode(id: 's', synthesized: true),
        GraphNode(id: 'z'),
      ],
      edges: const [
        GraphEdge(sourceId: 'a', targetId: 'b', kind: EdgeKind.call),
        GraphEdge(sourceId: 'b', targetId: 'a', kind: EdgeKind.call),
        GraphEdge(sourceId: 's', targetId: 'a', kind: EdgeKind.call),
        GraphEdge(sourceId: 'b', targetId: 's', kind: EdgeKind.call),
        GraphEdge(sourceId: 'z', targetId: 'a', kind: EdgeKind.reference),
      ],
    );

    // 순환 참여 정점만 붉게 — z(순환 밖)는 색칠 없고, 비참여 출력은 기존 바이트.
    expect(
      GraphExporter.dot(cyclic, cycleNodeIds: const {'a', 'b', 's'}),
      'digraph dartograph {\n'
      '  "a" [color=red fontcolor=red];\n'
      '  "b" [color=red fontcolor=red];\n'
      '  "s" [style=dashed color=red fontcolor=red];\n'
      '  "z";\n'
      '  "a" -> "b" [label="call"];\n'
      '  "b" -> "a" [label="call"];\n'
      '  "b" -> "s" [label="call"];\n'
      '  "s" -> "a" [label="call"];\n'
      '  "z" -> "a" [label="reference"];\n'
      '}\n',
    );
    // cycleNodeIds를 주지 않으면 색칠이 없다(acyclic 그래프의 기존 출력 보존).
    expect(GraphExporter.dot(cyclic), isNot(contains('color=red')));
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

  test('anon keeps the json document shape with identity strings mapped', () {
    final document =
        jsonDecode(
              GraphExporter.anon(
                GraphSnapshot(
                  nodes: [
                    GraphNode(
                      id: 'project:lib/billing.dart',
                      sourceUri: 'project:lib/billing.dart',
                      isLibrary: true,
                    ),
                    GraphNode(
                      id: 'project:lib/billing.dart::Invoice.total',
                      sourceUri: 'project:lib/billing.dart',
                      line: 4,
                      column: 3,
                    ),
                  ],
                  edges: const [
                    GraphEdge(
                      sourceId: 'project:lib/billing.dart::Invoice.total',
                      targetId: 'project:lib/billing.dart',
                      kind: EdgeKind.member,
                    ),
                  ],
                ),
                limitations: const [
                  'configured-entry-point-without-main: lib/billing.dart',
                ],
              ),
            )
            as Map<String, Object?>;

    // 문서·정점·간선의 키 모양은 json과 같다(식별 문자열만 바뀐다).
    expect(document.keys, ['edges', 'limitations', 'nodes']);
    final nodes = (document['nodes'] as List).cast<Map<String, Object?>>();
    expect(nodes, hasLength(2));
    expect(nodes.first.keys, [
      'id',
      'isAbstract',
      'isTypeDeclaration',
      'sourceUri',
      'synthesized',
    ]);
    expect(nodes.last.keys, [
      'column',
      'id',
      'isAbstract',
      'isTypeDeclaration',
      'line',
      'sourceUri',
      'synthesized',
    ]);
    // 라이브러리·멤버 점 구조는 유지되고 식별자는 치환된다.
    expect(nodes.first['id'], matches(r'^project:lib/s\d+\.dart$'));
    expect(nodes.last['id'], matches(r'^project:lib/s\d+\.dart::s\d+\.s\d+$'));
    expect(nodes.first['sourceUri'], nodes.first['id']);
    // 경로가 박힌 limitation 문구도 같은 치환을 받는다.
    expect(document['limitations'], [
      matches(r'^configured-entry-point-without-main: lib/s\d+\.dart$'),
    ]);
  });

  test('JSON nodes carry isEnumConstant conditionally', () {
    final enums = GraphSnapshot(
      nodes: [
        GraphNode(id: 'Status', isTypeDeclaration: true),
        GraphNode(id: 'Status.active', isEnumConstant: true),
      ],
      edges: const [
        GraphEdge(
          sourceId: 'Status',
          targetId: 'Status.active',
          kind: EdgeKind.member,
        ),
      ],
    );
    // 조건부 필드 규약(line·column과 동일): 참일 때만 실어 기존 그래프의
    // 바이트를 보존하고 캐시 문서와 필드 사실을 맞춘다.
    expect(
      GraphExporter.json(enums),
      '{"edges":[{"kind":"member","source":"Status","target":"Status.active"}],'
      '"limitations":[],"nodes":[{"id":"Status","isAbstract":false,'
      '"isTypeDeclaration":true,"synthesized":false},{"id":"Status.active",'
      '"isAbstract":false,"isEnumConstant":true,"isTypeDeclaration":false,'
      '"synthesized":false}]}\n',
    );
    // enum 상수가 없는 기존 스냅샷의 골든은 무수정 — 위 테스트들이 증거다.
    expect(GraphExporter.json(snapshot), isNot(contains('isEnumConstant')));
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
        {'id': 'b', 'kind': 'type', 'name': 'b', 'synthesized': true},
      ],
    });
  });

  test('HTML node kinds and display names come from explicit node flags', () {
    final typed = GraphSnapshot(
      nodes: [
        GraphNode(id: 'package:app/lib/foo.dart', isLibrary: true),
        GraphNode(id: 'package:app/lib/foo.dart::Bar', isTypeDeclaration: true),
        GraphNode(id: 'package:app/lib/foo.dart::Bar.baz'),
        GraphNode(id: '<no-library>', isLibrary: true),
        // `<unnamed-extension@…>`는 `::` 없는 선언 ID다. 종류는 명시 플래그로
        // member가 되고(옛 id 모양 유추는 library로 오판했다) 이름은 경로
        // 마지막 세그먼트로 보존된다.
        GraphNode(id: '<unnamed-extension@package:app/lib/foo.dart#40>'),
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
        'id': '<unnamed-extension@package:app/lib/foo.dart#40>',
        'kind': 'member',
        'name': 'foo.dart#40>',
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

  test('HTML kind/name ignore `::` in filenames because kind is explicit', () {
    final weird = GraphSnapshot(
      nodes: [
        // 파일명에 `::`를 담은 경우(macOS 등에서 합법). 종류는 id 모양이 아니라
        // 명시 isLibrary가 정하므로 라이브러리는 라이브러리로 남는다.
        GraphNode(id: 'package:app/lib/weird::name.dart', isLibrary: true),
        GraphNode(
          id: 'package:app/lib/weird::name.dart::Decl',
          isTypeDeclaration: true,
        ),
        // 옛 `.dart::` 휴리스틱의 잔여 엣지: 파일명 자체가 `.dart::`를 포함하면
        // (`weird.dart::name.dart`) id 파식으로는 선언과 구분이 불가능했다.
        // 명시 종류는 이 경우도 정확히 가른다.
        GraphNode(id: 'package:app/lib/weird.dart::name.dart', isLibrary: true),
        GraphNode(id: 'package:app/lib/weird.dart::name.dart::Foo.bar'),
      ],
      edges: const [],
    );

    final nodes = (decodePayload(GraphExporter.html(weird))['nodes'] as List)
        .cast<Map<String, Object?>>();
    expect(nodes, [
      {
        'id': 'package:app/lib/weird.dart::name.dart',
        'kind': 'library',
        'name': 'weird.dart::name.dart',
        'synthesized': false,
      },
      {
        'id': 'package:app/lib/weird.dart::name.dart::Foo.bar',
        'kind': 'member',
        // 선언 이름은 마지막 `::` 뒤로 뽑힌다(파일명의 `::`와 무관).
        'name': 'Foo.bar',
        'synthesized': false,
      },
      {
        'id': 'package:app/lib/weird::name.dart',
        'kind': 'library',
        'name': 'weird::name.dart',
        'synthesized': false,
      },
      {
        'id': 'package:app/lib/weird::name.dart::Decl',
        'kind': 'type',
        'name': 'Decl',
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
      nodes: [GraphNode(id: '<no-library>', isLibrary: true)],
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

  test('HTML payload defuses script-tag tokenizer traps in node ids', () {
    final hostile = GraphSnapshot(
      nodes: [
        GraphNode(id: 'a</script>'),
        GraphNode(id: 'b<!--<script'),
      ],
      edges: const [
        GraphEdge(
          sourceId: 'b<!--<script',
          targetId: 'a</script>',
          kind: EdgeKind.call,
        ),
      ],
    );

    final html = GraphExporter.html(hostile);
    // 페이로드에 여는 꺾쇠가 raw로 남지 않으므로 문서의 실제 `</script>`는
    // 페이로드 닫는 태그와 인라인 JS 끝 두 곳뿐이다.
    expect(payloadOf(html), isNot(contains('<')));
    expect('</script>'.allMatches(html).length, 2);
    // 라운드 트립: 이스케이프는 JSON 파싱 결과를 바꾸지 않는다.
    final payload = decodePayload(html);
    expect(
      (payload['nodes'] as List).map((node) => (node as Map)['id']).toList(),
      ['a</script>', 'b<!--<script'],
    );
    expect(payload['edges'], [
      {'kind': 'call', 'source': 'b<!--<script', 'target': 'a</script>'},
    ]);
  });

  test('HTML output is byte-identical across runs', () {
    final first = GraphExporter.html(
      snapshot,
      limitations: const ['single configuration'],
    );
    final second = GraphExporter.html(
      snapshot,
      limitations: const ['single configuration'],
    );
    expect(first, second);
  });

  test('Mermaid keeps newline-bearing ids on one physical line', () {
    final split = GraphSnapshot(
      nodes: [GraphNode(id: 'project:lib/a\nb.dart')],
      edges: const [],
    );
    final mermaid = GraphExporter.mermaid(split);
    // raw 개행은 라벨을 두 문장으로 절단한다(실측 주입 경로). 엔티티 코드로
    // 한 물리행을 유지하고, 원문 `#10;`은 `#35;` 선행 치환으로 구분된다.
    expect(mermaid, 'flowchart LR\n  n0["project:lib/a#10;b.dart"]\n');
    final literal = GraphSnapshot(
      nodes: [
        GraphNode(id: 'a#10;b'),
        GraphNode(id: 'c\rd'),
      ],
      edges: const [],
    );
    expect(
      GraphExporter.mermaid(literal),
      'flowchart LR\n  n0["a#35;10;b"]\n  n1["c#13;d"]\n',
    );
  });

  test('DOT escapes carriage returns like newlines', () {
    final split = GraphSnapshot(
      nodes: [GraphNode(id: 'a\rb')],
      edges: const [],
    );
    expect(GraphExporter.dot(split), 'digraph dartograph {\n  "a\\rb";\n}\n');
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
