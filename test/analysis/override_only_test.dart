import 'package:dartograph/src/analysis/reachability_analyzer.dart';
import 'package:dartograph/src/core/code_graph.dart';
import 'package:dartograph/src/core/graph_edge.dart';
import 'package:dartograph/src/core/graph_node.dart';
import 'package:test/test.dart';

void main() {
  const library = 'package:app/widgets.dart';
  const source = 'project:lib/widgets.dart';

  CodeGraph graphOf(List<String> ids, List<(String, String, EdgeKind)> edges) {
    final graph = CodeGraph();
    for (final id in ids) {
      graph.addNode(GraphNode(id: id, sourceUri: source));
    }
    for (final (from, to, kind) in edges) {
      graph.addEdge(GraphEdge(sourceId: from, targetId: to, kind: kind));
    }
    return graph;
  }

  test('override roots count only after their type is reachable', () {
    // main → Screen을 만든다. Screen.build(재정의)는 Header를, Header.build는
    // Logo를 만든다 — Logo를 살리려면 고정점 반복이 두 번 필요하다.
    // Orphan은 아무도 만들지 않으므로 Orphan.build 재정의 루트만이 살린다.
    final graph = graphOf(
      [
        '$library::main',
        '$library::Screen',
        '$library::Screen.build',
        '$library::Header',
        '$library::Header.build',
        '$library::Logo',
        '$library::Logo.build',
        '$library::Orphan',
        '$library::Orphan.build',
        '$library::OrphanHelper',
      ],
      [
        ('$library::main', '$library::Screen', EdgeKind.reference),
        ('$library::Screen.build', '$library::Header', EdgeKind.reference),
        ('$library::Header.build', '$library::Logo', EdgeKind.reference),
        ('$library::Orphan.build', '$library::OrphanHelper', EdgeKind.call),
      ],
    );
    const roots = {
      '$library::main': RetentionReason.mainEntryPoint,
      '$library::Screen.build': RetentionReason.overrideContract,
      '$library::Header.build': RetentionReason.overrideContract,
      '$library::Logo.build': RetentionReason.overrideContract,
      '$library::Orphan.build': RetentionReason.overrideContract,
    };

    // 기본 dead는 재정의 루트를 무조건 보존하므로 아무것도 보고하지 않는다.
    final analyzer = ReachabilityAnalyzer();
    expect(
      analyzer.analyze(graph.snapshot(), roots: roots).deadDeclarations,
      isEmpty,
    );

    final findings = analyzer.overrideOnlyDeclarations(
      graph.snapshot(),
      roots: roots,
      limitations: const ['global: kept'],
    );
    expect(findings.map((finding) => finding.id), [
      '$library::Orphan',
      '$library::Orphan.build',
      '$library::OrphanHelper',
    ]);
    for (final finding in findings) {
      expect(finding.kind, 'declaration');
      expect(
        finding.reason,
        'retained only by override members of otherwise unreached types',
      );
      expect(finding.source, source);
      expect(finding.limitations, ['global: kept']);
      // 근거는 기본 분석에서 이 선언을 살린 재정의 루트 하나다.
      expect(finding.retentionRootsChecked, ['$library::Orphan.build']);
    }
  });

  test('a type reached through its supertype keeps its overrides', () {
    // Leaf를 만들면 상속 간선으로 Middle이 살아 Middle의 재정의도 루트가 된다.
    // 다른 루트(vmEntryPoint)로 살아 있는 멤버도 그 컨테이너를 살린다.
    final graph = graphOf(
      [
        '$library::main',
        '$library::Middle',
        '$library::Middle.toString',
        '$library::Leaf',
        '$library::Native',
        '$library::Native.call',
        '$library::Native.toString',
      ],
      [
        ('$library::main', '$library::Leaf', EdgeKind.reference),
        ('$library::Leaf', '$library::Middle', EdgeKind.inheritance),
      ],
    );
    final findings = ReachabilityAnalyzer().overrideOnlyDeclarations(
      graph.snapshot(),
      roots: const {
        '$library::main': RetentionReason.mainEntryPoint,
        '$library::Middle.toString': RetentionReason.overrideContract,
        '$library::Native.call': RetentionReason.vmEntryPoint,
        '$library::Native.toString': RetentionReason.overrideContract,
      },
    );
    expect(findings, isEmpty);
  });
}
