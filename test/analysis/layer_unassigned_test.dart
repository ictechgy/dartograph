import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/layer_rules.dart';
import 'package:test/test.dart';

void main() {
  final rules = LayerRuleSet.parse('''
layers:
  - name: presentation
    match: ["project:lib/presentation/**"]
  - name: domain
    match: ["project:lib/domain/**"]
rules:
  - name: presentation only reaches domain
    from: presentation
    allow: [domain]
''');

  CodeGraph graph() {
    final graph = CodeGraph();
    for (final (id, source) in const [
      ('screen', 'project:lib/presentation/screen.dart'),
      ('header', 'project:lib/presentation/header.dart'),
      ('service', 'project:lib/domain/service.dart'),
      ('util', 'project:lib/util/util.dart'),
      ('helper', 'project:lib/helper.dart'),
    ]) {
      graph.addNode(GraphNode(id: id, sourceUri: source));
    }
    for (final (from, to, kind) in const [
      ('screen', 'service', EdgeKind.call),
      ('screen', 'header', EdgeKind.call),
      // 규칙이 있는 레이어에서 어느 레이어에도 없는 정점으로 가는 사용 간선이다.
      ('screen', 'util', EdgeKind.call),
      ('screen', 'helper', EdgeKind.reference),
      ('header', 'util', EdgeKind.call),
      // 구조 간선은 사용이 아니다.
      ('screen', 'helper', EdgeKind.member),
      // 규칙이 없는 레이어와 미배정 출발점은 규칙이 검사하지 않는 것이 맞다.
      ('service', 'util', EdgeKind.call),
      ('util', 'screen', EdgeKind.call),
    ]) {
      graph.addEdge(GraphEdge(sourceId: from, targetId: to, kind: kind));
    }
    return graph;
  }

  test('edges into unassigned nodes are counted, not reported', () {
    final evaluator = LayerRuleEvaluator(rules);
    final snapshot = graph().snapshot();

    // allow 규칙도 미배정 대상은 검사하지 않는다(기존 계약 유지).
    expect(evaluator.evaluate(snapshot), isEmpty);
    expect(
      evaluator.unassignedTargetsLimitation(snapshot),
      'unassigned-layer-targets: 3 usage edge(s) from layers with rules reach '
      '2 node(s) outside every layer; layer rules do not check them',
    );
  });

  test('no limitation when every target of a ruled layer is assigned', () {
    final rules = LayerRuleSet.parse('''
layers:
  - name: presentation
    match: ["project:lib/presentation/**"]
  - name: rest
    match: ["project:lib/**"]
rules:
  - name: presentation only reaches rest
    from: presentation
    allow: [rest]
''');
    expect(
      LayerRuleEvaluator(rules).unassignedTargetsLimitation(graph().snapshot()),
      isNull,
    );
  });
}
