import 'dart:convert';

import 'package:dartograph/src/analysis/reachability_analyzer.dart';
import 'package:dartograph/src/core/code_graph.dart';
import 'package:dartograph/src/core/graph_edge.dart';
import 'package:dartograph/src/core/graph_node.dart';
import 'package:test/test.dart';

void main() {
  test('member edges alone do not make a declaration reachable', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'app::root', sourceUri: 'project:lib/main.dart'))
      ..addNode(
        GraphNode(id: 'app::called', sourceUri: 'project:lib/live.dart'),
      )
      ..addNode(
        GraphNode(id: 'app::member', sourceUri: 'project:lib/live.dart'),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'app::root',
          targetId: 'app::called',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'app::called',
          targetId: 'app::member',
          kind: EdgeKind.member,
        ),
      );

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {'app::root': RetentionReason.mainEntryPoint},
    );

    expect(result.reachableIds, ['app::called', 'app::root']);
    expect(result.deadDeclarations.map((finding) => finding.id), [
      'app::member',
    ]);
  });

  test('a reachable member keeps its container but not dead siblings', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'app::root'))
      ..addNode(GraphNode(id: 'package:app/model.dart::Widget'))
      ..addNode(GraphNode(id: 'package:app/model.dart::Widget.live'))
      ..addNode(GraphNode(id: 'package:app/model.dart::Widget.dead'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'app::root',
          targetId: 'package:app/model.dart::Widget.live',
          kind: EdgeKind.call,
        ),
      );

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {'app::root': RetentionReason.mainEntryPoint},
    );

    expect(result.deadDeclarations.map((finding) => finding.id), [
      'package:app/model.dart::Widget.dead',
    ]);
    // dead가 보존으로 판정한 컨테이너는 explain도 같은 근거로 설명해야 한다.
    // 한쪽만 미도달이라고 답하면 같은 실행에서 상반된 결론이 나온다.
    final explanation = result.explain('package:app/model.dart::Widget');
    expect(explanation.reachable, isTrue);
    expect(explanation.reason, 'retained by a reachable member');
    expect(explanation.witness, 'package:app/model.dart::Widget.live');
    expect(explanation.path, [
      'app::root',
      'package:app/model.dart::Widget.live',
    ]);
  });

  test('explanations choose a deterministic shortest preservation path', () {
    final graph = CodeGraph();
    for (final id in const ['z-root', 'a-root', 'middle', 'target']) {
      graph.addNode(GraphNode(id: id, sourceUri: 'project:lib/app.dart'));
    }
    for (final edge in const [
      GraphEdge(sourceId: 'z-root', targetId: 'target', kind: EdgeKind.call),
      GraphEdge(sourceId: 'a-root', targetId: 'middle', kind: EdgeKind.call),
      GraphEdge(
        sourceId: 'middle',
        targetId: 'target',
        kind: EdgeKind.reference,
      ),
    ]) {
      graph.addEdge(edge);
    }

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {
        'z-root': RetentionReason.vmEntryPoint,
        'a-root': RetentionReason.mainEntryPoint,
      },
    );

    expect(result.explain('target').toJson(), {
      'id': 'target',
      'reachable': true,
      'retentionReason': 'vmEntryPoint',
      'path': ['z-root', 'target'],
      'evidence': [
        {'from': 'z-root', 'kind': 'call', 'to': 'target'},
      ],
      'limitations': const <String>[],
    });
    expect(
      jsonEncode(result.explain('target').toJson()),
      '{"evidence":[{"from":"z-root","kind":"call","to":"target"}],"id":"target","limitations":[],"path":["z-root","target"],"reachable":true,"retentionReason":"vmEntryPoint"}',
    );
  });

  test('explanations distinguish an unknown id from dead code', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'app::root'))
      ..addNode(GraphNode(id: 'app::dead'));

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {'app::root': RetentionReason.mainEntryPoint},
    );

    expect(result.explain('app::missing').toJson(), {
      'id': 'app::missing',
      'known': false,
      'limitations': const <String>[],
      'reachable': false,
      'reason': 'not found in graph',
    });
  });

  test('file explanations follow imports from a reachable library', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'package:app/main.dart'))
      ..addNode(GraphNode(id: 'package:app/live.dart'))
      ..addNode(
        GraphNode(
          id: 'package:app/main.dart::main',
          sourceUri: 'project:lib/main.dart',
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/main.dart',
          targetId: 'package:app/live.dart',
          kind: EdgeKind.import,
        ),
      );

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {
        'package:app/main.dart::main': RetentionReason.mainEntryPoint,
      },
    );

    expect(result.explain('package:app/live.dart').toJson(), {
      'evidence': [
        {
          'from': 'package:app/main.dart',
          'kind': 'import',
          'to': 'package:app/live.dart',
        },
      ],
      'id': 'package:app/live.dart',
      'limitations': const <String>[],
      'path': ['package:app/main.dart', 'package:app/live.dart'],
      'reachable': true,
      'reason': 'reachable from a library containing a reachable declaration',
      'witness': 'package:app/main.dart::main',
    });
  });

  test('a library retention root is not also reported as dead', () {
    final graph = CodeGraph()..addNode(GraphNode(id: 'package:app/entry.dart'));

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {'package:app/entry.dart': RetentionReason.generatedCode},
    );

    expect(result.deadFiles, isEmpty);
    expect(result.explain('package:app/entry.dart').toJson(), {
      'evidence': const <Object>[],
      'id': 'package:app/entry.dart',
      'limitations': const <String>[],
      'path': ['package:app/entry.dart'],
      'reachable': true,
      'reason': 'retained as a root',
      'retentionReason': 'generatedCode',
    });
  });

  test('dead declarations and files carry evidence without deletion advice', () {
    final graph = CodeGraph()
      ..addNode(
        GraphNode(
          id: 'package:app/main.dart::main',
          sourceUri: 'project:lib/main.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/orphan.dart::dead',
          sourceUri: 'project:lib/orphan.dart',
        ),
      )
      ..addNode(GraphNode(id: 'package:app/main.dart'))
      ..addNode(GraphNode(id: 'package:app/orphan.dart'));

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {
        'package:app/main.dart::main': RetentionReason.mainEntryPoint,
      },
    );

    expect(result.deadDeclarations.single.toJson(), {
      'id': 'package:app/orphan.dart::dead',
      'kind': 'declaration',
      'source': 'project:lib/orphan.dart',
      'reason': 'unreachable from all retention roots',
      'evidence': {
        'retentionRootsChecked': ['package:app/main.dart::main'],
      },
      'limitations': const <String>[],
    });
    expect(
      jsonEncode(result.deadDeclarations.single.toJson()),
      '{"evidence":{"retentionRootsChecked":["package:app/main.dart::main"]},"id":"package:app/orphan.dart::dead","kind":"declaration","limitations":[],"reason":"unreachable from all retention roots","source":"project:lib/orphan.dart"}',
    );
    expect(result.deadFiles.single.toJson(), {
      'id': 'package:app/orphan.dart',
      'kind': 'file',
      'source': 'project:lib/orphan.dart',
      'reason': 'no reachable declaration or reachable library import',
      'evidence': {
        'retentionRootsChecked': ['package:app/main.dart::main'],
      },
      'limitations': const <String>[],
    });
    expect(
      result.deadFiles.single.toJson().toString(),
      isNot(contains('delete')),
    );
  });
}
