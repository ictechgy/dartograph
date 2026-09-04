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
}
