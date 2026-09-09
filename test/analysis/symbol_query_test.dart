import 'package:dartograph/dartograph.dart';
import 'package:test/test.dart';

void main() {
  // A→B, A→C, B→C, C→D 사용 체인과 M→{m1,m2,m3} 포함 관계.
  // C는 A에서 직접(1단계)과 B 경유(2단계)로 모두 닿으므로 visited가
  // 최단 깊이만 남기는지 검증한다.
  GraphSnapshot graph() => GraphSnapshot(
    nodes: [
      GraphNode(id: 'lib::A'),
      GraphNode(id: 'lib::B'),
      GraphNode(id: 'lib::C'),
      GraphNode(id: 'lib::D'),
      GraphNode(id: 'lib::M'),
      GraphNode(id: 'lib::M.m1'),
      GraphNode(id: 'lib::M.m2'),
      GraphNode(id: 'lib::M.m3'),
    ],
    edges: const [
      GraphEdge(sourceId: 'lib::A', targetId: 'lib::B', kind: EdgeKind.call),
      GraphEdge(sourceId: 'lib::A', targetId: 'lib::C', kind: EdgeKind.call),
      GraphEdge(sourceId: 'lib::B', targetId: 'lib::C', kind: EdgeKind.call),
      GraphEdge(sourceId: 'lib::C', targetId: 'lib::D', kind: EdgeKind.call),
      GraphEdge(
        sourceId: 'lib::M',
        targetId: 'lib::M.m1',
        kind: EdgeKind.member,
      ),
      GraphEdge(
        sourceId: 'lib::M',
        targetId: 'lib::M.m2',
        kind: EdgeKind.member,
      ),
      GraphEdge(
        sourceId: 'lib::M',
        targetId: 'lib::M.m3',
        kind: EdgeKind.member,
      ),
    ],
  );

  SymbolQuerySession session() => SymbolQuerySession(
    graph: graph(),
    roots: const {'lib::A': RetentionReason.mainEntryPoint},
    limitations: const [],
  );

  Map<String, Object?> resultOf(
    String requested, {
    int depth = 1,
    int? limit,
  }) =>
      session().query(requested, depth: depth, limit: limit)['result']
          as Map<String, Object?>;

  List<Map<String, Object?>> list(Map<String, Object?> result, String key) =>
      (result[key] as List).cast<Map<String, Object?>>();

  Map<String, Object?> truncatedOf(Map<String, Object?> result) =>
      (result['truncated'] as Map).cast<String, Object?>();

  group('query depth', () {
    test('depth 1 reports only direct usage neighbours at depth 1', () {
      final dependsOn = list(resultOf('A'), 'dependsOn');
      expect(dependsOn.map((n) => n['qualifiedName']).toList(), [
        'lib::B',
        'lib::C',
      ]);
      expect(dependsOn.every((n) => n['depth'] == 1), isTrue);
      expect(truncatedOf(resultOf('A'))['dependsOn'], isFalse);
    });

    test('depth 2 follows the chain and labels each neighbour depth', () {
      final dependsOn = list(resultOf('A', depth: 2), 'dependsOn');
      expect(dependsOn.map((n) => [n['qualifiedName'], n['depth']]).toList(), [
        ['lib::B', 1],
        ['lib::C', 1],
        ['lib::D', 2],
      ]);
    });

    test('a neighbour reached two ways keeps its shortest depth once', () {
      // C는 A→C(1)와 A→B→C(2) 모두 존재하지만 1단계 한 번만 보고된다.
      final dependsOn = list(resultOf('A', depth: 3), 'dependsOn');
      final c = dependsOn.where((n) => n['qualifiedName'] == 'lib::C').toList();
      expect(c, hasLength(1));
      expect(c.single['depth'], 1);
    });

    test('usedBy walks incoming usage edges in reverse by depth', () {
      final usedBy = list(resultOf('D', depth: 2), 'usedBy');
      expect(usedBy.map((n) => [n['qualifiedName'], n['depth']]).toList(), [
        ['lib::C', 1],
        ['lib::A', 2],
        ['lib::B', 2],
      ]);
    });

    test('usage neighbour carries every edge kind that reaches it', () {
      final dependsOn = list(resultOf('A'), 'dependsOn');
      expect(dependsOn.first['edges'], ['call']);
    });
  });

  group('query limit', () {
    test('limit caps a direction and raises its truncated flag only', () {
      final result = resultOf('A', depth: 2, limit: 2);
      final dependsOn = list(result, 'dependsOn');
      expect(dependsOn.map((n) => n['qualifiedName']).toList(), [
        'lib::B',
        'lib::C',
      ]);
      expect(truncatedOf(result)['dependsOn'], isTrue);
      // usedBy는 제한에 걸리지 않았으므로 따로 잘리지 않는다.
      expect(truncatedOf(result)['usedBy'], isFalse);
    });

    test(
      'a limit reached at a shallower depth omits deeper reachable nodes',
      () {
        // D는 depth 2로 도달 가능하지만 limit 2가 depth 1에서 가득 차면 생략된다.
        // 개수 제한이 남은 요청 깊이보다 우선한다.
        final dependsOn = list(resultOf('A', depth: 3, limit: 2), 'dependsOn');
        expect(dependsOn.map((n) => n['qualifiedName']).toList(), [
          'lib::B',
          'lib::C',
        ]);
      },
    );

    test('no limit means no truncation', () {
      final result = resultOf('A', depth: 3);
      expect(truncatedOf(result)['dependsOn'], isFalse);
      expect(list(result, 'dependsOn'), hasLength(3));
    });
  });

  group('query containment', () {
    test('members stay one level regardless of depth', () {
      final members = list(resultOf('M', depth: 3), 'members');
      expect(members.map((n) => [n['qualifiedName'], n['depth']]).toList(), [
        ['lib::M.m1', 1],
        ['lib::M.m2', 1],
        ['lib::M.m3', 1],
      ]);
      expect(
        members.every((n) => (n['edges'] as List).single == 'member'),
        isTrue,
      );
    });

    test('member limit truncates members only', () {
      final result = resultOf('M', limit: 2);
      expect(list(result, 'members').map((n) => n['qualifiedName']).toList(), [
        'lib::M.m1',
        'lib::M.m2',
      ]);
      expect(truncatedOf(result)['members'], isTrue);
    });

    test('declaredIn names the containing type of a member', () {
      final declaredIn = resultOf('m1')['declaredIn'] as Map<String, Object?>;
      expect(declaredIn['qualifiedName'], 'lib::M');
      expect(declaredIn['depth'], 1);
    });

    test('containment is not reported as a usage dependency', () {
      // M의 멤버는 dependsOn이 아니라 members에 담긴다.
      expect(list(resultOf('M'), 'dependsOn'), isEmpty);
      expect(list(resultOf('M'), 'members'), hasLength(3));
    });
  });

  group('query self reference', () {
    // 재귀 호출처럼 자기 자신으로 향하는 사용 간선은 cartograph와 같이
    // 자기 자신의 이웃으로 실리지 않는다(visited가 start로 초기화되므로).
    // 옛 1-hop 순회는 self-loop를 dependsOn/usedBy에 포함했으므로 이는
    // depth=1에서도 관측되는 좁은 동작 델타다.
    Map<String, Object?> selfRefResult() {
      final graph = GraphSnapshot(
        nodes: [
          GraphNode(id: 'lib::Rec'),
          GraphNode(id: 'lib::Caller'),
        ],
        edges: const [
          GraphEdge(
            sourceId: 'lib::Rec',
            targetId: 'lib::Rec',
            kind: EdgeKind.call,
          ),
          GraphEdge(
            sourceId: 'lib::Caller',
            targetId: 'lib::Rec',
            kind: EdgeKind.call,
          ),
        ],
      );
      return SymbolQuerySession(
            graph: graph,
            roots: const {'lib::Caller': RetentionReason.mainEntryPoint},
            limitations: const [],
          ).query('Rec')['result']
          as Map<String, Object?>;
    }

    test('a self-referential symbol is not its own neighbour', () {
      final result = selfRefResult();
      expect(
        list(result, 'dependsOn').map((n) => n['qualifiedName']).toList(),
        isEmpty,
      );
      expect(list(result, 'usedBy').map((n) => n['qualifiedName']).toList(), [
        'lib::Caller',
      ]);
    });
  });

  group('public API surface', () {
    test(
      'deadDeclarations exposes unreachable declarations as DeadFinding',
      () {
        // app::member는 member 간선만으로 루트에서 도달하지 못해 죽은 선언이다
        // (reachability_analyzer_test의 첫 fixture와 같은 그래프).
        final graph = GraphSnapshot(
          nodes: [
            GraphNode(id: 'app::root', sourceUri: 'project:lib/main.dart'),
            GraphNode(id: 'app::called', sourceUri: 'project:lib/live.dart'),
            GraphNode(id: 'app::member', sourceUri: 'project:lib/live.dart'),
          ],
          edges: const [
            GraphEdge(
              sourceId: 'app::root',
              targetId: 'app::called',
              kind: EdgeKind.call,
            ),
            GraphEdge(
              sourceId: 'app::called',
              targetId: 'app::member',
              kind: EdgeKind.member,
            ),
          ],
        );
        final session = SymbolQuerySession(
          graph: graph,
          roots: const {'app::root': RetentionReason.mainEntryPoint},
          limitations: const [],
        );

        // DeadFinding은 배럴로 export되므로 타입을 직접 이름으로 쓸 수 있고,
        // getter가 내부 ReachabilityResult를 발견 목록으로 좁히는 공개 표면을 고정한다.
        final List<DeadFinding> dead = session.deadDeclarations;
        expect(dead.map((finding) => finding.id), ['app::member']);
      },
    );
  });
}
