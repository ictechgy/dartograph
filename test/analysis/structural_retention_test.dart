import 'package:dartograph/src/analysis/reachability_analyzer.dart';
import 'package:dartograph/src/analysis/symbol_query.dart';
import 'package:dartograph/src/core/code_graph.dart';
import 'package:dartograph/src/core/graph_edge.dart';
import 'package:dartograph/src/core/graph_node.dart';
import 'package:test/test.dart';

/// 구조적으로만 보존된 선언(enum 상수·컨테이너·sealed 서브타입)의 사용 간선도
/// 따라가는 고정점을 합성 그래프로 고정한다. 정점·간선은 손으로 적은 리터럴이다.
void main() {
  const root = 'app::main';
  const roots = {root: RetentionReason.mainEntryPoint};

  GraphEdge use(String source, String target) =>
      GraphEdge(sourceId: source, targetId: target, kind: EdgeKind.reference);

  GraphEdge member(String source, String target) =>
      GraphEdge(sourceId: source, targetId: target, kind: EdgeKind.member);

  CodeGraph enumGraph() => CodeGraph()
    ..addNode(GraphNode(id: root))
    ..addNode(GraphNode(id: 'app::Env', isTypeDeclaration: true))
    ..addNode(GraphNode(id: 'app::Env.dev', isEnumConstant: true))
    ..addNode(GraphNode(id: 'app::_devUrl'))
    ..addNode(GraphNode(id: 'app::_unused'))
    ..addEdge(use(root, 'app::Env'))
    ..addEdge(member('app::Env', 'app::Env.dev'))
    // enum 상수의 인자는 그 상수 정점이 소유한다.
    ..addEdge(use('app::Env.dev', 'app::_devUrl'));

  test('enum constant arguments are followed and explained by witness', () {
    final result = ReachabilityAnalyzer().analyze(
      enumGraph().snapshot(),
      roots: roots,
    );
    expect(result.deadDeclarations.map((finding) => finding.id), [
      'app::_unused',
    ]);
    expect(result.isReachable('app::_devUrl'), isTrue);
    final explanation = result.explain('app::_devUrl');
    expect(explanation.reachable, isTrue);
    expect(
      explanation.reason,
      'reachable from a structurally retained declaration',
    );
    expect(explanation.witness, 'app::Env.dev');
    expect(explanation.path, ['app::Env.dev', 'app::_devUrl']);
    expect(explanation.evidence, [use('app::Env.dev', 'app::_devUrl')]);
    // 기존 구조적 보존 설명은 바뀌지 않는다.
    final constant = result.explain('app::Env.dev');
    expect(constant.reason, 'retained by its reachable enum');
    expect(constant.path, [root, 'app::Env']);
  });

  test('query names the retaining declaration as the path witness', () {
    final session = SymbolQuerySession(
      graph: enumGraph().snapshot(),
      roots: roots,
      limitations: const [],
    );
    Map<String, Object?> reachabilityOf(String id) =>
        (session.query(id)['result']! as Map<String, Object?>)['reachability']!
            as Map<String, Object?>;
    final structural = reachabilityOf('app::_devUrl');
    expect(structural['state'], 'reachable');
    expect(structural['path'], ['app::Env.dev', 'app::_devUrl']);
    expect(structural['witness'], 'app::Env.dev');
    // 루트에서 닿은 선언과 enum 상수의 기존 문서에는 witness가 없다.
    expect(reachabilityOf('app::Env').containsKey('witness'), isFalse);
    expect(reachabilityOf('app::Env.dev').containsKey('witness'), isFalse);
  });

  test('sealed subtypes and containers follow their own usage edges', () {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: root))
      ..addNode(
        GraphNode(id: 'app::Shape', isTypeDeclaration: true, isSealed: true),
      )
      ..addNode(GraphNode(id: 'app::Circle', isTypeDeclaration: true))
      ..addNode(GraphNode(id: 'app::Holder', isTypeDeclaration: true))
      ..addNode(GraphNode(id: 'app::Holder.value'))
      ..addNode(GraphNode(id: 'app::circleHelper'))
      ..addNode(GraphNode(id: 'app::holderHelper'))
      ..addNode(GraphNode(id: 'app::chained'))
      ..addEdge(use(root, 'app::Shape'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'app::Circle',
          targetId: 'app::Shape',
          kind: EdgeKind.inheritance,
        ),
      )
      ..addEdge(use('app::Circle', 'app::circleHelper'))
      ..addEdge(use(root, 'app::Holder.value'))
      ..addEdge(member('app::Holder', 'app::Holder.value'))
      // 컨테이너가 소유한 사용(생성자 초기화 등)도 따라간다.
      ..addEdge(use('app::Holder', 'app::holderHelper'))
      ..addEdge(use('app::holderHelper', 'app::chained'));

    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: roots,
    );
    expect(result.deadDeclarations, isEmpty);
    expect(result.explain('app::chained').path, [
      'app::Holder',
      'app::holderHelper',
      'app::chained',
    ]);
    expect(result.explain('app::circleHelper').witness, 'app::Circle');
  });

  test('declarations retained structurally keep their own explanation', () {
    // Env는 멤버(Env.label)만 도달한 컨테이너라 구조적으로 살아 있고, 그 상수
    // Env.dev도 그래서 보존된다. 사전순으로 먼저 처리되는 컨테이너 AHolder가
    // Env.dev로 가는 간선을 갖는다. 간선 따라가기를 구조 규칙의 닫힘 뒤로 미루지
    // 않으면 Env.dev가 기존 설명 대신 AHolder에서 시작하는 구조 경로로 설명된다.
    final graph = CodeGraph()
      ..addNode(GraphNode(id: root))
      ..addNode(GraphNode(id: 'app::AHolder', isTypeDeclaration: true))
      ..addNode(GraphNode(id: 'app::AHolder.value'))
      ..addNode(GraphNode(id: 'app::Env', isTypeDeclaration: true))
      ..addNode(GraphNode(id: 'app::Env.dev', isEnumConstant: true))
      ..addNode(GraphNode(id: 'app::Env.label'))
      ..addEdge(use(root, 'app::AHolder.value'))
      ..addEdge(use(root, 'app::Env.label'))
      ..addEdge(member('app::AHolder', 'app::AHolder.value'))
      ..addEdge(member('app::Env', 'app::Env.dev'))
      ..addEdge(member('app::Env', 'app::Env.label'))
      ..addEdge(use('app::AHolder', 'app::Env.dev'));
    final result = ReachabilityAnalyzer().analyze(
      graph.snapshot(),
      roots: roots,
    );
    expect(result.deadDeclarations, isEmpty);
    final constant = result.explain('app::Env.dev');
    expect(constant.reason, 'retained by its reachable enum');
    expect(constant.witness, 'app::Env');
    expect(result.isReachable('app::Env.dev'), isFalse);
  });

  test('override-only analysis uses the same structural closure', () {
    // 구조적으로 살아난 상수에서 닿는 타입의 재정의 루트도 켜져야 한다. 켜지지
    // 않으면 같은 입력에서 dead와 override-only가 상반된 결론을 낸다.
    final graph = enumGraph()
      ..addNode(GraphNode(id: 'app::Impl', isTypeDeclaration: true))
      ..addNode(GraphNode(id: 'app::Impl.run'))
      ..addNode(GraphNode(id: 'app::runHelper'))
      ..addEdge(use('app::Env.dev', 'app::Impl'))
      ..addEdge(member('app::Impl', 'app::Impl.run'))
      ..addEdge(use('app::Impl.run', 'app::runHelper'));
    final overrideRoots = {
      ...roots,
      'app::Impl.run': RetentionReason.overrideContract,
    };
    final findings = ReachabilityAnalyzer().overrideOnlyDeclarations(
      graph.snapshot(),
      roots: overrideRoots,
    );
    expect(findings, isEmpty);
  });
}
