import 'dart:collection';
import 'dart:convert';
import 'dart:math';

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

  test(
    'a reachable sealed type preserves its direct and transitive subtypes',
    () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'app::root'))
        ..addNode(
          GraphNode(
            id: 'package:app/shape.dart::Shape',
            isTypeDeclaration: true,
            isSealed: true,
          ),
        )
        ..addNode(
          GraphNode(
            id: 'package:app/shape.dart::Circle',
            isTypeDeclaration: true,
          ),
        )
        ..addNode(
          GraphNode(
            id: 'package:app/shape.dart::RectBase',
            isTypeDeclaration: true,
            isSealed: true,
          ),
        )
        ..addNode(
          GraphNode(
            id: 'package:app/shape.dart::Square',
            isTypeDeclaration: true,
          ),
        )
        // switch 디스패치만 쓰이는 서브타입은 사용 간선이 없다 — 상위만 도달.
        ..addEdge(
          const GraphEdge(
            sourceId: 'app::root',
            targetId: 'package:app/shape.dart::Shape',
            kind: EdgeKind.reference,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'package:app/shape.dart::Circle',
            targetId: 'package:app/shape.dart::Shape',
            kind: EdgeKind.inheritance,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'package:app/shape.dart::RectBase',
            targetId: 'package:app/shape.dart::Shape',
            kind: EdgeKind.inheritance,
          ),
        )
        // sealed인 서브타입의 서브타입도 전이 보존된다.
        ..addEdge(
          const GraphEdge(
            sourceId: 'package:app/shape.dart::Square',
            targetId: 'package:app/shape.dart::RectBase',
            kind: EdgeKind.inheritance,
          ),
        );

      final result = ReachabilityAnalyzer().analyze(
        graph.snapshot(),
        roots: const {'app::root': RetentionReason.mainEntryPoint},
      );

      expect(result.deadDeclarations, isEmpty);
      final explanation = result.explain('package:app/shape.dart::Circle');
      expect(explanation.reachable, isTrue);
      expect(
        explanation.reason,
        'retained as a subtype of a reachable sealed type',
      );
      expect(explanation.witness, 'package:app/shape.dart::Shape');
      expect(explanation.path, ['app::root', 'package:app/shape.dart::Shape']);
      final transitive = result.explain('package:app/shape.dart::Square');
      expect(transitive.reachable, isTrue);
      expect(transitive.witness, 'package:app/shape.dart::RectBase');
    },
  );

  test('an unreachable sealed type still reports its subtypes as dead', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'app::root'))
      ..addNode(
        GraphNode(
          id: 'package:app/shape.dart::Orphan',
          isTypeDeclaration: true,
          isSealed: true,
        ),
      )
      ..addNode(
        GraphNode(id: 'package:app/shape.dart::Impl', isTypeDeclaration: true),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/shape.dart::Impl',
          targetId: 'package:app/shape.dart::Orphan',
          kind: EdgeKind.inheritance,
        ),
      );

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {'app::root': RetentionReason.mainEntryPoint},
    );

    // 상위 sealed가 도달하지 못하면 서브타입 보존이 과해지지 않는다.
    expect(result.deadDeclarations.map((finding) => finding.id), [
      'package:app/shape.dart::Impl',
      'package:app/shape.dart::Orphan',
    ]);
  });

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

  test('project-scheme file nodes are reported as dead files', () {
    // package_config이 없는 프로젝트는 자기 라이브러리를 project: ID로 둔다 —
    // dead-file 검사가 package:만 보면 이 파일 발견이 조용히 사라진다.
    final graph = CodeGraph()
      ..addNode(
        GraphNode(
          id: 'project:lib/main.dart::main',
          sourceUri: 'project:lib/main.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/orphan.dart::dead',
          sourceUri: 'project:lib/orphan.dart',
        ),
      )
      ..addNode(GraphNode(id: 'project:lib/main.dart'))
      ..addNode(GraphNode(id: 'project:lib/orphan.dart'));

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {
        'project:lib/main.dart::main': RetentionReason.mainEntryPoint,
      },
    );

    expect(
      result.deadFiles.map((finding) => finding.id),
      contains('project:lib/orphan.dart'),
    );
    expect(
      result.deadDeclarations.map((finding) => finding.id),
      contains('project:lib/orphan.dart::dead'),
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

  test('test-only reachability reports production code only tests reach', () {
    final graph = CodeGraph()
      // 프로덕션: main이 도달, 테스트만 도달, 어디서도 도달 못 함, @visibleForTesting.
      ..addNode(
        GraphNode(
          id: 'package:app/main.dart::main',
          sourceUri: 'project:lib/main.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/prod.dart::usedByMain',
          sourceUri: 'project:lib/prod.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/prod.dart::usedByTestOnly',
          sourceUri: 'project:lib/prod.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/prod.dart::deadEverywhere',
          sourceUri: 'project:lib/prod.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/prod.dart::vftKept',
          sourceUri: 'project:lib/prod.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/prod.dart::reachedByVft',
          sourceUri: 'project:lib/prod.dart',
        ),
      )
      // 테스트 디렉터리 선언(루트)과 그 내부 헬퍼.
      ..addNode(
        GraphNode(
          id: 'package:app/prod_test.dart::testMain',
          sourceUri: 'project:test/prod_test.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/prod_test.dart::testHelper',
          sourceUri: 'project:test/prod_test.dart',
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/main.dart::main',
          targetId: 'package:app/prod.dart::usedByMain',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/prod_test.dart::testMain',
          targetId: 'package:app/prod.dart::usedByTestOnly',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/prod_test.dart::testMain',
          targetId: 'package:app/prod_test.dart::testHelper',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/prod.dart::vftKept',
          targetId: 'package:app/prod.dart::reachedByVft',
          kind: EdgeKind.call,
        ),
      );

    final findings = ReachabilityAnalyzer().testOnlyDeclarations(
      graph.snapshot(),
      roots: const {
        'package:app/main.dart::main': RetentionReason.mainEntryPoint,
        'package:app/prod_test.dart::testMain':
            RetentionReason.visibleForTesting,
        // @visibleForTesting 프로덕션 선언은 lib/ 소스라 테스트 루트가 아니다.
        'package:app/prod.dart::vftKept': RetentionReason.visibleForTesting,
      },
    );

    // 테스트에서만 도달되는 프로덕션 선언 하나만 보고된다.
    expect(findings.map((finding) => finding.id), [
      'package:app/prod.dart::usedByTestOnly',
    ]);
    expect(findings.single.reason, 'reached only from test code');
    expect(findings.single.kind, 'declaration');
    // 근거는 실제로 도달한 테스트 루트다(전체 테스트 루트 나열이 아니다).
    expect(findings.single.retentionRootsChecked, [
      'package:app/prod_test.dart::testMain',
    ]);
  });

  test('test-only reachability is empty when nothing depends on tests', () {
    final graph = CodeGraph()
      ..addNode(
        GraphNode(
          id: 'package:app/main.dart::main',
          sourceUri: 'project:lib/main.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/prod.dart::used',
          sourceUri: 'project:lib/prod.dart',
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/main.dart::main',
          targetId: 'package:app/prod.dart::used',
          kind: EdgeKind.call,
        ),
      );

    expect(
      ReachabilityAnalyzer().testOnlyDeclarations(
        graph.snapshot(),
        roots: const {
          'package:app/main.dart::main': RetentionReason.mainEntryPoint,
        },
      ),
      isEmpty,
    );
  });

  test('test-only reachability recognizes every test-directory prefix', () {
    // _testSourcePrefixes의 네 접두어 각각이 테스트 루트로 분류되는지 고정한다.
    // 인덱스의 _retentionReason 접두어와 어긋나면 이 테스트가 실패한다.
    for (final prefix in const [
      'project:test/',
      'project:integration_test/',
      'project:example/test/',
      'project:example/integration_test/',
    ]) {
      final graph = CodeGraph()
        ..addNode(
          GraphNode(id: 'app::prod', sourceUri: 'project:lib/prod.dart'),
        )
        ..addNode(
          GraphNode(id: 'app::testRoot', sourceUri: '${prefix}x_test.dart'),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'app::testRoot',
            targetId: 'app::prod',
            kind: EdgeKind.call,
          ),
        );
      final findings = ReachabilityAnalyzer().testOnlyDeclarations(
        graph.snapshot(),
        roots: const {'app::testRoot': RetentionReason.visibleForTesting},
      );
      expect(findings.map((f) => f.id), ['app::prod'], reason: prefix);
    }
  });

  test('a test-source root with a non-testing reason is not removed', () {
    // _isTestRoot는 reason과 source를 양쪽 요구한다. source가 테스트 디렉터리여도
    // reason이 visibleForTesting가 아니면(인덱스 drift 가정) 테스트 루트로 제거하지
    // 않아, 그 전용 callee를 거짓 양성으로 보고하지 않는다(누락으로 안전 편향).
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'app::prod', sourceUri: 'project:lib/prod.dart'))
      ..addNode(GraphNode(id: 'app::oddRoot', sourceUri: 'project:test/x.dart'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'app::oddRoot',
          targetId: 'app::prod',
          kind: EdgeKind.call,
        ),
      );
    final findings = ReachabilityAnalyzer().testOnlyDeclarations(
      graph.snapshot(),
      roots: const {'app::oddRoot': RetentionReason.mainEntryPoint},
    );
    expect(findings, isEmpty);
  });

  test('redundant public finds internal-only public declarations', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::runner',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::Internal',
          sourceUri: 'project:lib/a.dart',
          isTypeDeclaration: true,
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::_secret',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::<unnamed-extension@project:lib/a.dart#3>',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addNode(GraphNode(id: 'project:lib/b.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:lib/b.dart::Shared',
          sourceUri: 'project:lib/b.dart',
          isTypeDeclaration: true,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::runner',
          targetId: 'project:lib/a.dart::Internal',
          kind: EdgeKind.reference,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::runner',
          targetId: 'project:lib/a.dart::_secret',
          kind: EdgeKind.call,
        ),
      )
      // 이름 없는 extension은 살아 있어도 라이브러리 비공개 마커(`<`)로 제외된다.
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::runner',
          targetId:
              'project:lib/a.dart::<unnamed-extension@project:lib/a.dart#3>',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        // 다른 라이브러리가 쓰는 공개 선언은 좁히면 깨진다 — 제외.
        const GraphEdge(
          sourceId: 'project:lib/a.dart::Internal',
          targetId: 'project:lib/b.dart::Shared',
          kind: EdgeKind.call,
        ),
      );

    final findings = ReachabilityAnalyzer().redundantPublicDeclarations(
      graph.snapshot(),
      roots: const {
        'project:lib/a.dart::runner': RetentionReason.mainEntryPoint,
      },
    );

    // 내부 전용 공개 선언만 나온다: 비공개(_)·외부 사용(Shared)·고정 마커는 제외.
    expect(findings.map((finding) => finding.id), [
      'project:lib/a.dart::Internal',
    ]);
    expect(findings.single.kind, 'declaration');
    expect(findings.single.reason, contains('own library'));
  });

  test(
    'redundant public excludes roots, dead, enum constants, and overrides',
    () {
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
        ..addNode(
          GraphNode(
            id: 'project:lib/a.dart::root',
            sourceUri: 'project:lib/a.dart',
          ),
        )
        ..addNode(
          GraphNode(
            id: 'project:lib/a.dart::deadPublic',
            sourceUri: 'project:lib/a.dart',
          ),
        )
        ..addNode(
          GraphNode(
            id: 'project:lib/a.dart::Color',
            sourceUri: 'project:lib/a.dart',
            isTypeDeclaration: true,
          ),
        )
        ..addNode(
          GraphNode(
            id: 'project:lib/a.dart::Color.red',
            sourceUri: 'project:lib/a.dart',
            isEnumConstant: true,
          ),
        )
        ..addNode(
          GraphNode(
            id: 'project:lib/a.dart::Impl.method',
            sourceUri: 'project:lib/a.dart',
          ),
        )
        ..addNode(
          GraphNode(
            id: 'project:lib/b.dart::Api.method',
            sourceUri: 'project:lib/b.dart',
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'project:lib/a.dart::root',
            targetId: 'project:lib/a.dart::Color',
            kind: EdgeKind.reference,
          ),
        )
        // Impl.method는 살아 있는 공개 선언이지만 override 계약을 이행 중이다.
        ..addEdge(
          const GraphEdge(
            sourceId: 'project:lib/a.dart::root',
            targetId: 'project:lib/a.dart::Impl.method',
            kind: EdgeKind.call,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'project:lib/a.dart::Color',
            targetId: 'project:lib/a.dart::Color.red',
            kind: EdgeKind.member,
          ),
        )
        ..addEdge(
          // 공개 계약 이행 override — 가시성을 못 좁힌다.
          const GraphEdge(
            sourceId: 'project:lib/a.dart::Impl.method',
            targetId: 'project:lib/b.dart::Api.method',
            kind: EdgeKind.override,
          ),
        );

      final findings = ReachabilityAnalyzer().redundantPublicDeclarations(
        graph.snapshot(),
        roots: const {'project:lib/a.dart::root': RetentionReason.publicApi},
      );

      // 보존 루트(root)·미도달(deadPublic)·enum 상수(Color.red)·override
      // 이행(Impl.method)은 전부 제외되고 내부 전용 공개 타입만 남는다.
      expect(findings.map((finding) => finding.id), [
        'project:lib/a.dart::Color',
      ]);
    },
  );

  test('redundant public skips structurally retained declarations', () {
    // sealed 서브타입은 사용 간선 없이 exhaustive 디스패치로 보존되고,
    // 컨테이너는 도달 가능한 멤버로 보존된다 — 둘 다 "내부 전용"이 아니라
    // 미관측이므로 가시성 축소 권고 대상이 아니다.
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::root',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/b.dart::Base',
          sourceUri: 'project:lib/b.dart',
          isTypeDeclaration: true,
          isSealed: true,
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/b.dart::Sub',
          sourceUri: 'project:lib/b.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/c.dart::Holder',
          sourceUri: 'project:lib/c.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/c.dart::Holder.run',
          sourceUri: 'project:lib/c.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::Internal',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::root',
          targetId: 'project:lib/b.dart::Base',
          kind: EdgeKind.reference,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::root',
          targetId: 'project:lib/c.dart::Holder.run',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::root',
          targetId: 'project:lib/a.dart::Internal',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        // Sub는 Base를 구현한다 — Sub로 향하는 사용 간선은 없다.
        const GraphEdge(
          sourceId: 'project:lib/b.dart::Sub',
          targetId: 'project:lib/b.dart::Base',
          kind: EdgeKind.inheritance,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/c.dart::Holder',
          targetId: 'project:lib/c.dart::Holder.run',
          kind: EdgeKind.member,
        ),
      );

    final findings = ReachabilityAnalyzer().redundantPublicDeclarations(
      graph.snapshot(),
      roots: const {'project:lib/a.dart::root': RetentionReason.mainEntryPoint},
    );

    // Sub(sealed 디스패치 보존)·Holder(도달 멤버 보존)는 제외되고 진짜
    // 내부 전용 공개 선언만 남는다.
    expect(findings.map((finding) => finding.id), [
      'project:lib/a.dart::Internal',
    ]);
  });

  test('redundant public skips private containers and operators', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::root',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::_Hidden.helper',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::Math.+',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::Plain',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::root',
          targetId: 'project:lib/a.dart::_Hidden.helper',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::root',
          targetId: 'project:lib/a.dart::Math.+',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart::root',
          targetId: 'project:lib/a.dart::Plain',
          kind: EdgeKind.call,
        ),
      );

    final findings = ReachabilityAnalyzer().redundantPublicDeclarations(
      graph.snapshot(),
      roots: const {'project:lib/a.dart::root': RetentionReason.mainEntryPoint},
    );
    // `_Hidden.helper`는 겉보기 공개 이름이지만 비공개 컨테이너 안이라 라이브러리
    // 밖 접근이 불가능하고, `+`는 이름에 `_`를 붙일 수 없는 연산자다. 내부
    // 전용 공개 선언만 여전히 나온다.
    expect(findings.map((finding) => finding.id), [
      'project:lib/a.dart::Plain',
    ]);
  });

  test('source limitations attach by suffix even when a source has ": "', () {
    const gaps =
        'analysis gaps may affect reachability outside the source files where '
        'they were observed';
    const conditional =
        'conditional-imports: 1 directive(s) use only the analyzer-selected '
        'configuration';
    final graph = CodeGraph();
    for (final (id, source) in [
      ('app::a', 'project:lib/a.dart'),
      ('app::b', 'project:lib/x: b.dart'),
      ('app::c', 'b.dart'),
      ('app::d', 'project:lib/d.dart'),
      ('app::e', 'lib/x: b.dart'),
    ]) {
      graph.addNode(GraphNode(id: id, sourceUri: source));
    }

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: const {},
      limitations: const [
        'source-analysis-errors: project:lib/a.dart',
        conditional,
        'source-unresolved-invocations: project:lib/x: b.dart',
        'source-analysis-errors: project:lib/a.dart',
        'source-without-separator',
        gaps,
        'source-conditional-configuration: project:lib/other.dart',
      ],
    );

    final limitationsById = {
      for (final finding in result.deadDeclarations)
        finding.id: finding.limitations,
    };
    expect(limitationsById, {
      'app::a': [
        gaps,
        conditional,
        'source-analysis-errors: project:lib/a.dart',
      ],
      'app::b': [
        gaps,
        conditional,
        'source-unresolved-invocations: project:lib/x: b.dart',
      ],
      // `': b.dart'`로 끝나는 한계는 그 접미사 source에도 붙는다(endsWith 의미).
      'app::c': [
        gaps,
        conditional,
        'source-unresolved-invocations: project:lib/x: b.dart',
      ],
      'app::d': [gaps, conditional],
      // `project:` 뒤 부분은 `': '` 바로 뒤가 아니라 접미사 매칭이 아니다.
      'app::e': [gaps, conditional],
    });
  });

  test('limitations are read once per analysis, not once per source', () {
    // source마다 limitation 전체를 다시 훑으면 읽기 수가 source 수 × 한계 수가
    // 된다. 시간 대신 목록 읽기 수로 결정적으로 확인한다.
    const files = 400;
    final items = [
      'analysis gaps may affect reachability outside the source files where '
          'they were observed',
      for (var i = 0; i < files; i += 2)
        'source-analysis-errors: project:lib/f$i.dart',
      for (var i = 0; i < files; i += 5)
        'source-unresolved-invocations: project:lib/f$i.dart',
    ];
    final dead = CodeGraph();
    final internal = CodeGraph();
    final testOnly = CodeGraph()
      ..addNode(
        GraphNode(
          id: 'project:test/a_test.dart::main',
          sourceUri: 'project:test/a_test.dart',
        ),
      );
    for (var i = 0; i < files; i++) {
      final source = 'project:lib/f$i.dart';
      dead.addNode(GraphNode(id: '$source::dead', sourceUri: source));
      internal
        ..addNode(GraphNode(id: '$source::root', sourceUri: source))
        ..addNode(GraphNode(id: '$source::helper', sourceUri: source))
        ..addEdge(
          GraphEdge(
            sourceId: '$source::root',
            targetId: '$source::helper',
            kind: EdgeKind.call,
          ),
        );
      testOnly
        ..addNode(GraphNode(id: '$source::tested', sourceUri: source))
        ..addEdge(
          GraphEdge(
            sourceId: 'project:test/a_test.dart::main',
            targetId: '$source::tested',
            kind: EdgeKind.call,
          ),
        );
    }
    final analyzer = ReachabilityAnalyzer();
    final runs = <String, List<DeadFinding> Function(List<String>)>{
      'analyze': (limitations) => analyzer
          .analyze(dead.snapshot(), roots: const {}, limitations: limitations)
          .deadDeclarations,
      'redundantPublicDeclarations': (limitations) =>
          analyzer.redundantPublicDeclarations(
            internal.snapshot(),
            roots: {
              for (var i = 0; i < files; i++)
                'project:lib/f$i.dart::root': RetentionReason.mainEntryPoint,
            },
            limitations: limitations,
          ),
      'testOnlyDeclarations': (limitations) => analyzer.testOnlyDeclarations(
        testOnly.snapshot(),
        roots: const {
          'project:test/a_test.dart::main': RetentionReason.visibleForTesting,
        },
        limitations: limitations,
      ),
    };
    for (final MapEntry(key: name, value: run) in runs.entries) {
      final counting = _CountingList(items);
      final findings = run(counting);
      expect(findings, hasLength(files), reason: name);
      for (final finding in findings) {
        expect(
          finding.limitations,
          _legacyLimitationsForSource(items, finding.source),
          reason: '$name ${finding.id}',
        );
      }
      expect(counting.reads, lessThanOrEqualTo(8 * items.length), reason: name);
    }
  });

  test('source limitations match the per-source filter on random inputs', () {
    final random = Random(20261018);
    const pieces = [
      'project:',
      'lib/',
      'a',
      'b.dart',
      ': ',
      ':',
      ' ',
      'x',
      'project:lib/a.dart',
    ];
    String randomSource() => [
      for (var k = random.nextInt(5); k >= 0; k--)
        pieces[random.nextInt(pieces.length)],
    ].join();
    for (var round = 0; round < 300; round++) {
      final sources = [for (var i = 0; i < 6; i++) randomSource()];
      String anySource() => random.nextBool()
          ? sources[random.nextInt(sources.length)]
          : randomSource();
      final limitations = [
        for (var i = random.nextInt(12); i > 0; i--)
          switch (random.nextInt(6)) {
            0 => 'global-${random.nextInt(3)}: ${anySource()}',
            1 => 'source-without-separator-${random.nextInt(3)}',
            2 => 'source-a${anySource()}',
            _ => 'source-kind-${random.nextInt(3)}: ${anySource()}',
          },
      ];
      final graph = CodeGraph();
      for (final (index, source) in sources.indexed) {
        graph.addNode(GraphNode(id: 'app::d$index', sourceUri: source));
      }

      final result = ReachabilityAnalyzer().analyze(
        graph.snapshot(),
        roots: const {},
        limitations: limitations,
      );

      for (final finding in result.deadDeclarations) {
        expect(
          finding.limitations,
          _legacyLimitationsForSource(limitations, finding.source),
          reason:
              'round $round ${finding.id} source "${finding.source}" '
              'limitations $limitations',
        );
      }
    }
  });
}

/// 성능 수정 전의 source별 한계 필터다 — 결과 동등성의 오라클로 옮겨 둔다.
List<String> _legacyLimitationsForSource(
  List<String> limitations,
  String source,
) =>
    limitations
        .where(
          (item) => !item.startsWith('source-') || item.endsWith(': $source'),
        )
        .toSet()
        .toList()
      ..sort();

/// 원소를 읽은 횟수를 세는 읽기 전용 목록이다.
final class _CountingList extends ListBase<String> {
  _CountingList(this._items);

  final List<String> _items;

  /// `[]`로 원소를 읽은 횟수다(반복자도 이 연산자로 읽는다).
  var reads = 0;

  @override
  int get length => _items.length;

  @override
  set length(int value) => throw UnsupportedError('read-only list');

  @override
  String operator [](int index) {
    reads++;
    return _items[index];
  }

  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('read-only list');
}
