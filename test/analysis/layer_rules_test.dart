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

  test('explainNode names the layer, matched pattern and rules from it', () {
    final rules = LayerRuleSet.parse('''
layers:
  - name: ui
    match: ["project:lib/ui/**"]
  - name: data
    match: ["project:lib/data/**"]
rules:
  - name: ui must not reach data
    from: ui
    deny: [data]
  - from: data
    allow: []
''');
    final graph = CodeGraph()
      ..addNode(
        GraphNode(id: 'screen', sourceUri: 'project:lib/ui/screen.dart'),
      );

    final explained = LayerRuleEvaluator(
      rules,
    ).explainNode(graph.snapshot(), 'screen');
    expect(explained.known, isTrue);
    expect(explained.layer, 'ui');
    expect(explained.matchedPattern, 'project:lib/ui/**');
    // 정점 ID가 sourceUri보다 먼저 후보로 검사되지만, ID는 패턴에 매치되지
    // 않으므로 sourceUri가 매치 후보다.
    expect(explained.matchedCandidate, 'project:lib/ui/screen.dart');
    // ui에서 출발하는 규칙만 실린다(data 출발 규칙은 제외).
    expect(explained.rules.map((rule) => rule.name).toList(), [
      'ui must not reach data',
    ]);
    expect(explained.rules.single.toJson(), {
      'allow': false,
      'from': 'ui',
      'name': 'ui must not reach data',
      'targets': ['data'],
    });
  });

  test('explainNode reports a present node matching no layer as known', () {
    final rules = LayerRuleSet.parse('''
layers:
  - name: ui
    match: ["project:lib/ui/**"]
rules:
  - from: ui
    allow: []
''');
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'other', sourceUri: 'project:lib/other.dart'));

    final explained = LayerRuleEvaluator(
      rules,
    ).explainNode(graph.snapshot(), 'other');
    expect(explained.known, isTrue);
    expect(explained.layer, isNull);
    expect(explained.matchedPattern, isNull);
    expect(explained.matchedCandidate, isNull);
    expect(explained.rules, isEmpty);
  });

  test('explainNode marks an id absent from the graph as unknown', () {
    final rules = LayerRuleSet.parse('''
layers:
  - name: ui
    match: ["project:lib/ui/**"]
rules:
  - from: ui
    allow: []
''');
    final graph = CodeGraph()..addNode(GraphNode(id: 'screen'));

    final explained = LayerRuleEvaluator(
      rules,
    ).explainNode(graph.snapshot(), 'missing');
    expect(explained.known, isFalse);
    expect(explained.id, 'missing');
    expect(explained.layer, isNull);
    expect(explained.rules, isEmpty);
  });

  test('configuration errors fail closed with precise per-key messages', () {
    void expectParseFailure(String yaml, String message) {
      expect(
        () => LayerRuleSet.parse(yaml),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains(message),
          ),
        ),
        reason: yaml,
      );
    }

    expectParseFailure(
      'layers:\n'
          '  - name: dup\n'
          '    match: [a]\n'
          '  - name: dup\n'
          '    match: [b]\n'
          'rules: []\n',
      'duplicate layer name',
    );
    expectParseFailure(
      'layers:\n  - name: ""\n    match: [a]\nrules: []\n',
      'must be a non-empty string',
    );
    expectParseFailure(
      'layers:\n  - name: a\n    match: nope\nrules: []\n',
      'must be a list of strings',
    );
    expectParseFailure(
      'layers:\n  - name: a\n    match: [x]\n    typo: 1\nrules: []\n',
      'unknown layer key',
    );
    expectParseFailure(
      'layers:\n  - name: a\n    match: [x]\n'
          'rules:\n  - from: a\n    deny: [a]\n    typo: 1\n',
      'unknown rule key',
    );
  });

  test('question-mark glob matches exactly one non-separator character', () {
    final rules = LayerRuleSet.parse(
      'layers:\n  - name: ui\n    match: ["project:lib/u?/**"]\nrules: []\n',
    );
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'in', sourceUri: 'project:lib/ui/screen.dart'))
      ..addNode(GraphNode(id: 'out', sourceUri: 'project:lib/uxi/screen.dart'))
      ..addNode(GraphNode(id: 'deep', sourceUri: 'project:lib/u/i/x.dart'));
    final evaluator = LayerRuleEvaluator(rules);

    expect(
      evaluator.explainNode(graph.snapshot(), 'in').matchedPattern,
      'project:lib/u?/**',
    );
    // `?`는 정확히 한 문자(구분자 제외) — uxi는 두 문자라 매치하지 않고,
    // u/i는 `/`를 건널 수 없다.
    expect(evaluator.explainNode(graph.snapshot(), 'out').layer, isNull);
    expect(evaluator.explainNode(graph.snapshot(), 'deep').layer, isNull);
  });
}
