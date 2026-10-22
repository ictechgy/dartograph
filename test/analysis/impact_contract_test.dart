import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/impact_analyzer.dart';
import 'package:dartograph/src/export/impact_reporter.dart';
import 'package:test/test.dart';

void main() {
  GraphSnapshot graph() => GraphSnapshot(
    nodes: [
      for (final id in ['implementation', 'contract', 'caller', 'test'])
        GraphNode(id: id, sourceUri: 'project:lib/$id.dart', line: 3),
    ],
    edges: const [
      GraphEdge(
        sourceId: 'implementation',
        targetId: 'contract',
        kind: EdgeKind.override,
      ),
      GraphEdge(sourceId: 'caller', targetId: 'contract', kind: EdgeKind.call),
      GraphEdge(sourceId: 'test', targetId: 'caller', kind: EdgeKind.call),
    ],
  );

  test('implementation edits reach callers typed as the base contract', () {
    final report = ImpactAnalysis.analyze(
      graph(),
      changedSymbols: ['implementation'],
    );
    expect(report.impacted.map((item) => item.id), contains('caller'));
    expect(report.impacted.firstWhere((item) => item.id == 'caller').path, [
      'caller',
      'contract',
      'implementation',
    ]);
  });

  test('depth boundary is incomplete when further callers exist', () {
    final report = ImpactAnalysis.analyze(
      graph(),
      changedSymbols: ['contract'],
      maxDepth: 1,
    );
    expect(report.truncated, isTrue);
  });

  test('caller declaration location is not an expression call-site claim', () {
    final report = ImpactAnalysis.analyze(
      graph(),
      changedSymbols: ['contract'],
    );
    final call = report.callSites.firstWhere((item) => item.fromId == 'caller');
    expect(call.toJson()['locationKind'], 'caller-declaration');
  });

  test(
    'projected contracts do not descend into concrete sibling implementations',
    () {
      final siblingGraph = GraphSnapshot(
        nodes: [
          for (final id in [
            'a',
            'b',
            'contract',
            'baseCaller',
            'bCaller',
            'helper',
          ])
            GraphNode(id: id),
        ],
        edges: const [
          GraphEdge(
            sourceId: 'a',
            targetId: 'contract',
            kind: EdgeKind.override,
          ),
          GraphEdge(
            sourceId: 'b',
            targetId: 'contract',
            kind: EdgeKind.override,
          ),
          GraphEdge(
            sourceId: 'baseCaller',
            targetId: 'contract',
            kind: EdgeKind.call,
          ),
          GraphEdge(sourceId: 'bCaller', targetId: 'b', kind: EdgeKind.call),
          GraphEdge(
            sourceId: 'contract',
            targetId: 'helper',
            kind: EdgeKind.call,
          ),
        ],
      );
      final report = ImpactAnalysis.analyze(
        siblingGraph,
        changedSymbols: ['a'],
      );
      expect(report.impacted.map((item) => item.id), [
        'contract',
        'baseCaller',
      ]);
      for (final format in [ImpactFormat.text, ImpactFormat.markdown]) {
        expect(
          ImpactReporter.render(format, report),
          contains('implementation-to-contract; not a call'),
        );
      }
      final genuine = ImpactAnalysis.analyze(
        siblingGraph,
        changedSymbols: ['a', 'helper'],
      );
      expect(genuine.impacted.map((item) => item.id), contains('bCaller'));
    },
  );
}
