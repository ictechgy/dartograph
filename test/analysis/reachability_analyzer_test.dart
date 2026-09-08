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

  test(
    'a reachable enum preserves constants consumed only through .values',
    () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'app::root'))
        ..addNode(GraphNode(id: 'package:app/enums.dart::Status'))
        ..addNode(
          GraphNode(
            id: 'package:app/enums.dart::Status.active',
            isEnumConstant: true,
          ),
        )
        ..addNode(
          GraphNode(
            id: 'package:app/enums.dart::Status.inactive',
            isEnumConstant: true,
          ),
        )
        // `.values`는 enum만 참조하고 개별 상수로는 usage 간선을 만들지 않는다.
        ..addEdge(
          const GraphEdge(
            sourceId: 'app::root',
            targetId: 'package:app/enums.dart::Status',
            kind: EdgeKind.reference,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'package:app/enums.dart::Status',
            targetId: 'package:app/enums.dart::Status.active',
            kind: EdgeKind.member,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'package:app/enums.dart::Status',
            targetId: 'package:app/enums.dart::Status.inactive',
            kind: EdgeKind.member,
          ),
        );

      final result = ReachabilityAnalyzer().analyze(
        graph.snapshot(),
        roots: const {'app::root': RetentionReason.mainEntryPoint},
      );

      // enum이 도달 가능하면 상수는 미도달로 보고되지 않는다(오탐 회귀).
      expect(result.deadDeclarations, isEmpty);
      // explain도 dead와 같은 근거로 보존을 설명한다.
      final explanation = result.explain(
        'package:app/enums.dart::Status.active',
      );
      expect(explanation.reachable, isTrue);
      expect(explanation.reason, 'retained by its reachable enum');
      expect(explanation.witness, 'package:app/enums.dart::Status');
      expect(explanation.path, ['app::root', 'package:app/enums.dart::Status']);
    },
  );

  test('an unreachable enum still reports its constants as dead', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'app::root'))
      ..addNode(GraphNode(id: 'package:app/enums.dart::Orphan'))
      ..addNode(
        GraphNode(
          id: 'package:app/enums.dart::Orphan.only',
          isEnumConstant: true,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/enums.dart::Orphan',
          targetId: 'package:app/enums.dart::Orphan.only',
          kind: EdgeKind.member,
        ),
      );

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {'app::root': RetentionReason.mainEntryPoint},
    );

    // enum 자체가 도달하지 못하면 보존이 과해지지 않고 상수도 보고를 유지한다.
    expect(result.deadDeclarations.map((finding) => finding.id), [
      'package:app/enums.dart::Orphan',
      'package:app/enums.dart::Orphan.only',
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

  test('a percent-encoded library id keeps its file-level limitation', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'package:app/main.dart'))
      ..addNode(GraphNode(id: 'package:app/main.dart::main'))
      ..addNode(GraphNode(id: 'package:app/foo%20bar.dart'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/main.dart',
          targetId: 'package:app/main.dart::main',
          kind: EdgeKind.member,
        ),
      );

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {
        'package:app/main.dart::main': RetentionReason.mainEntryPoint,
      },
      // analyzer는 실제(디코딩된) 파일 경로로 source 한계를 만든다.
      limitations: const ['source-analysis-errors: project:lib/foo bar.dart'],
    );

    final file = result.deadFiles.singleWhere(
      (finding) => finding.id == 'package:app/foo%20bar.dart',
    );
    // Uri.path의 %20를 디코딩해야 source가 analyzer 한계와 매치되어, 그 파일의
    // 한계가 finding에서 조용히 사라지지 않는다.
    expect(file.source, 'project:lib/foo bar.dart');
    expect(
      file.limitations,
      contains('source-analysis-errors: project:lib/foo bar.dart'),
    );
  });
}
