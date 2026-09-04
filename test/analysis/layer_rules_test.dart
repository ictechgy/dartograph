import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/layer_rules.dart';
import 'package:test/test.dart';

void main() {
  test('YAML deny rule reports the dependency path and source evidence', () {
    final rules = LayerRuleSet.parse('''
layers:
  - name: presentation
    match: ["project:lib/presentation/**"]
  - name: domain
    match: ["project:lib/domain/**"]
  - name: data
    match: ["project:lib/data/**"]
rules:
  - name: presentation cannot reach data
    from: presentation
    deny: [data]
''');
    final graph = CodeGraph()
      ..addNode(
        GraphNode(
          id: 'screen',
          sourceUri: 'project:lib/presentation/screen.dart',
          line: 7,
          column: 4,
        ),
      )
      ..addNode(
        GraphNode(
          id: 'repo',
          sourceUri: 'project:lib/data/repo.dart',
          line: 2,
          column: 1,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'screen',
          targetId: 'repo',
          kind: EdgeKind.call,
        ),
      );

    final violations = LayerRuleEvaluator(rules).evaluate(graph.snapshot());

    expect(violations, hasLength(1));
    expect(violations.single.toJson(), {
      'evidence': {
        'column': 4,
        'edge': {'from': 'screen', 'kind': 'call', 'to': 'repo'},
        'line': 7,
        'source': 'project:lib/presentation/screen.dart',
      },
      'fromLayer': 'presentation',
      'path': ['screen', 'repo'],
      'rule': 'presentation cannot reach data',
      'toLayer': 'data',
    });
  });

  test(
    'allow rule ignores ownership edges and rejects other assigned targets',
    () {
      final rules = LayerRuleSet.parse('''
layers:
  - name: domain
    match: ["domain*"]
  - name: data
    match: ["data*"]
rules:
  - from: domain
    allow: []
''');
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'domainType'))
        ..addNode(GraphNode(id: 'dataType'))
        ..addEdge(
          const GraphEdge(
            sourceId: 'domainType',
            targetId: 'dataType',
            kind: EdgeKind.member,
          ),
        )
        ..addEdge(
          const GraphEdge(
            sourceId: 'domainType',
            targetId: 'dataType',
            kind: EdgeKind.reference,
          ),
        );

      final violations = LayerRuleEvaluator(rules).evaluate(graph.snapshot());

      expect(violations, hasLength(1));
      expect(
        violations.single.ruleName,
        'domain may only depend on allowed layers',
      );
    },
  );

  test(
    'malformed layer YAML fails closed with an actionable configuration error',
    () {
      expect(
        () => LayerRuleSet.parse('layers: wrong'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('layers must be a list'),
          ),
        ),
      );
    },
  );

  test('same-layer dependencies are always allowed', () {
    final rules = LayerRuleSet.parse('''
layers:
  - name: domain
    match: ["domain*"]
rules:
  - from: domain
    allow: []
''');
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'domainA'))
      ..addNode(GraphNode(id: 'domainB'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'domainA',
          targetId: 'domainB',
          kind: EdgeKind.reference,
        ),
      );

    expect(LayerRuleEvaluator(rules).evaluate(graph.snapshot()), isEmpty);
  });

  test('unnamed deny rules describe the denied layers', () {
    final rules = LayerRuleSet.parse('''
layers:
  - name: domain
    match: ["domain*"]
  - name: data
    match: ["data*"]
rules:
  - from: domain
    deny: [data]
''');
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'domainType'))
      ..addNode(GraphNode(id: 'dataType'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'domainType',
          targetId: 'dataType',
          kind: EdgeKind.reference,
        ),
      );

    expect(
      LayerRuleEvaluator(rules).evaluate(graph.snapshot()).single.ruleName,
      'domain must not depend on data',
    );
  });
}
