import 'dart:convert';
import 'dart:math';

import 'package:dartograph/src/analysis/reachability_analyzer.dart';
import 'package:dartograph/src/core/code_graph.dart';
import 'package:dartograph/src/core/graph_edge.dart';
import 'package:dartograph/src/core/graph_node.dart';
import 'package:dartograph/src/core/graph_snapshot.dart';
import 'package:test/test.dart';

/// `overrideOnlyDeclarations`의 증분 고정점이 정의대로의 반복 고정점(켤 수 있는
/// 재정의 루트를 모두 켠 뒤 전체 도달성을 다시 계산)과 같은 결과를 내는지 무작위
/// 그래프로 대조한다. 기준 구현은 공개 [ReachabilityAnalyzer.analyze]만 쓴다.
void main() {
  test('incremental fixpoint matches the iterated definition', () {
    final random = Random(20261101);
    var nonEmpty = 0;
    for (var round = 0; round < 400; round++) {
      final (graph, roots) = _randomGraph(random);
      final expected = _reference(graph, roots);
      final actual = ReachabilityAnalyzer().overrideOnlyDeclarations(
        graph,
        roots: roots,
        limitations: const ['global: kept'],
      );
      expect(
        jsonEncode([for (final finding in actual) finding.toJson()]),
        jsonEncode([for (final finding in expected) finding.toJson()]),
        reason: 'round $round',
      );
      if (expected.isNotEmpty) nonEmpty++;
    }
    // 대조가 빈 결과끼리의 비교로만 끝나지 않았음을 확인한다.
    expect(nonEmpty, greaterThan(100));
  });

  test('enum constants revived through a reached member enable roots', () {
    // E 자체는 도달하지 않고 멤버 E.helper만 도달한다. 컨테이너로 살아난 enum의
    // 상수 E.a도 살아 있으므로, E.a 안의 재정의 루트도 켜져야 한다.
    const library = 'package:app/e.dart';
    final graph = CodeGraph();
    for (final (id, constant) in const [
      ('$library::main', false),
      ('$library::E', false),
      ('$library::E.helper', false),
      ('$library::E.a', true),
      ('$library::E.a.inner', false),
      ('$library::Used', false),
    ]) {
      graph.addNode(
        GraphNode(
          id: id,
          sourceUri: 'project:lib/e.dart',
          isEnumConstant: constant,
        ),
      );
    }
    graph
      ..addEdge(
        const GraphEdge(
          sourceId: '$library::main',
          targetId: '$library::E.helper',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: '$library::E.a.inner',
          targetId: '$library::Used',
          kind: EdgeKind.call,
        ),
      );
    const roots = {
      '$library::main': RetentionReason.mainEntryPoint,
      '$library::E.a.inner': RetentionReason.overrideContract,
    };
    final snapshot = graph.snapshot();
    final findings = ReachabilityAnalyzer().overrideOnlyDeclarations(
      snapshot,
      roots: roots,
      limitations: const ['global: kept'],
    );
    expect(findings, isEmpty);
    expect(_reference(snapshot, roots), isEmpty);
  });

  test('a deep chain of override-enabled types stays linear', () {
    // 타입 i의 재정의 멤버가 타입 i+1을 만든다. 반복 고정점은 깊이만큼 전체
    // 도달성을 다시 계산한다. 결과만 고정한다(시간은 단언하지 않는다).
    const depth = 1500;
    const library = 'package:app/chain.dart';
    final graph = CodeGraph()
      ..addNode(GraphNode(id: '$library::main', sourceUri: 'project:lib/a'));
    final roots = <String, RetentionReason>{
      '$library::main': RetentionReason.mainEntryPoint,
    };
    for (var index = 0; index <= depth; index++) {
      graph
        ..addNode(
          GraphNode(id: '$library::T$index', sourceUri: 'project:lib/a'),
        )
        ..addNode(
          GraphNode(id: '$library::T$index.build', sourceUri: 'project:lib/a'),
        );
      roots['$library::T$index.build'] = RetentionReason.overrideContract;
    }
    for (var index = 0; index < depth; index++) {
      graph.addEdge(
        GraphEdge(
          sourceId: '$library::T$index.build',
          targetId: '$library::T${index + 1}',
          kind: EdgeKind.reference,
        ),
      );
    }
    graph
      ..addNode(GraphNode(id: '$library::Orphan', sourceUri: 'project:lib/a'))
      ..addNode(
        GraphNode(id: '$library::Orphan.build', sourceUri: 'project:lib/a'),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: '$library::main',
          targetId: '$library::T0',
          kind: EdgeKind.reference,
        ),
      );
    roots['$library::Orphan.build'] = RetentionReason.overrideContract;
    final findings = ReachabilityAnalyzer().overrideOnlyDeclarations(
      graph.snapshot(),
      roots: roots,
    );
    expect(findings.map((finding) => finding.id), [
      '$library::Orphan',
      '$library::Orphan.build',
    ]);
  });
}

/// 정의대로의 반복 고정점이다. 증분 구현 이전의 알고리즘을 그대로 옮겼다.
List<DeadFinding> _reference(
  GraphSnapshot graph,
  Map<String, RetentionReason> roots,
) {
  const limitations = ['global: kept'];
  final analyzer = ReachabilityAnalyzer();
  final nodeIds = graph.nodes.map((node) => node.id).toSet();
  String? container(String id) {
    final symbolSeparator = id.indexOf('::');
    if (symbolSeparator < 0) return null;
    var memberSeparator = id.lastIndexOf('.');
    while (memberSeparator > symbolSeparator + 1) {
      final candidate = id.substring(0, memberSeparator);
      if (nodeIds.contains(candidate)) return candidate;
      memberSeparator = id.lastIndexOf('.', memberSeparator - 1);
    }
    return null;
  }

  final active = <String, RetentionReason>{};
  final pending = <String, String>{};
  for (final entry in roots.entries) {
    final owner = entry.value == RetentionReason.overrideContract
        ? container(entry.key)
        : null;
    if (owner == null) {
      active[entry.key] = entry.value;
    } else {
      pending[entry.key] = owner;
    }
  }
  final withOverrides = analyzer.analyze(
    graph,
    roots: roots,
    limitations: limitations,
  );
  var conditional = analyzer.analyze(
    graph,
    roots: active,
    limitations: limitations,
  );
  while (pending.isNotEmpty) {
    final dead = {
      for (final finding in conditional.deadDeclarations) finding.id,
    };
    final enabled = [
      for (final entry in pending.entries)
        if (!dead.contains(entry.value)) entry.key,
    ];
    if (enabled.isEmpty) break;
    for (final id in enabled) {
      pending.remove(id);
      active[id] = roots[id]!;
    }
    conditional = analyzer.analyze(
      graph,
      roots: active,
      limitations: limitations,
    );
  }
  final deadWithOverrides = {
    for (final finding in withOverrides.deadDeclarations) finding.id,
  };
  final unmetRoots = (pending.keys.where(nodeIds.contains).toList()..sort());
  final findings = <DeadFinding>[];
  for (final finding in conditional.deadDeclarations) {
    if (deadWithOverrides.contains(finding.id)) continue;
    final explanation = withOverrides.explain(finding.id);
    final reachingRoot = explanation.reachable && explanation.path.isNotEmpty
        ? explanation.path.first
        : null;
    findings.add(
      DeadFinding(
        id: finding.id,
        kind: 'declaration',
        source: finding.source,
        line: finding.line,
        column: finding.column,
        reason:
            'retained only by override members of otherwise unreached types',
        retentionRootsChecked: reachingRoot != null
            ? [reachingRoot]
            : unmetRoots,
        limitations: finding.limitations,
      ),
    );
  }
  findings.sort((a, b) => a.id.compareTo(b.id));
  return findings;
}

/// 컨테이너·멤버·중첩 멤버·enum 상수·sealed 계층·구조/사용 간선이 섞인 그래프와
/// 재정의 루트가 섞인 보존 루트를 만든다.
(GraphSnapshot, Map<String, RetentionReason>) _randomGraph(Random random) {
  const library = 'package:app/l.dart';
  final graph = CodeGraph()..addNode(GraphNode(id: library, isLibrary: true));
  final ids = <String>[library];
  final members = <String>[];
  final typeCount = 2 + random.nextInt(9);
  for (var type = 0; type < typeCount; type++) {
    final id = '$library::T$type';
    final isEnum = random.nextInt(6) == 0;
    graph.addNode(
      GraphNode(
        id: id,
        sourceUri: 'project:lib/l.dart',
        line: type + 1,
        isTypeDeclaration: true,
        isSealed: !isEnum && random.nextInt(5) == 0,
      ),
    );
    ids.add(id);
    final memberCount = random.nextInt(4);
    for (var member = 0; member < memberCount; member++) {
      final memberId = '$id.m$member';
      graph.addNode(
        GraphNode(
          id: memberId,
          sourceUri: 'project:lib/l.dart',
          isEnumConstant: isEnum && member == 0,
        ),
      );
      ids.add(memberId);
      members.add(memberId);
      if (random.nextInt(4) == 0) {
        // 컨테이너 노드가 없는 중간 이름을 거친 중첩 멤버다.
        final nested = '$memberId.inner';
        graph.addNode(GraphNode(id: nested, sourceUri: 'project:lib/l.dart'));
        ids.add(nested);
        members.add(nested);
      }
    }
  }
  final functionCount = 1 + random.nextInt(4);
  for (var function = 0; function < functionCount; function++) {
    final id = '$library::f$function';
    graph.addNode(GraphNode(id: id, sourceUri: 'project:lib/l.dart'));
    ids.add(id);
  }
  // 그래프에 컨테이너가 없는 재정의 루트(합성 입력)도 섞는다.
  final orphanMember = '$library::Missing.m';
  graph.addNode(GraphNode(id: orphanMember, sourceUri: 'project:lib/l.dart'));
  ids.add(orphanMember);
  members.add(orphanMember);

  const kinds = EdgeKind.values;
  final edgeCount = random.nextInt(ids.length * 2);
  for (var edge = 0; edge < edgeCount; edge++) {
    final from = ids[random.nextInt(ids.length)];
    final to = ids[random.nextInt(ids.length)];
    if (from == to) continue;
    graph.addEdge(
      GraphEdge(
        sourceId: from,
        targetId: to,
        kind: kinds[random.nextInt(kinds.length)],
      ),
    );
  }

  final roots = <String, RetentionReason>{
    '$library::f0': RetentionReason.mainEntryPoint,
  };
  for (final member in members) {
    if (random.nextInt(2) == 0) {
      roots[member] = RetentionReason.overrideContract;
    } else if (random.nextInt(8) == 0) {
      roots[member] = RetentionReason.vmEntryPoint;
    }
  }
  if (random.nextInt(4) == 0) {
    roots['$library::T${random.nextInt(typeCount)}'] =
        RetentionReason.publicApi;
  }
  // 그래프에 없는 루트도 받아야 한다.
  if (random.nextInt(5) == 0) {
    roots['$library::Gone.m'] = RetentionReason.overrideContract;
  }
  return (graph.snapshot(), roots);
}
