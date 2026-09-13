// Demonstrates the dartograph library API: build a dependency graph by hand,
// query it through a SymbolQuerySession, and print the dead-declaration
// findings as JSON.
//
// The `dartograph` command line tool derives this same kind of graph from
// real Dart sources; the library surface is for consumers that already hold
// graph facts (for example, derived from another compiler's output).
//
// Run from the package root:
//
//   dart run example/main.dart

import 'dart:convert';

import 'package:dartograph/dartograph.dart';

void main() {
  // A retained declaration also retains its enclosing library, so an
  // explicit library node needs no edge of its own to stay alive.
  final graph = CodeGraph()
    ..addNode(
      GraphNode(
        id: 'package:app/report.dart',
        sourceUri: 'package:app/report.dart',
        isLibrary: true,
      ),
    )
    ..addNode(
      GraphNode(
        id: 'package:app/report.dart::render',
        sourceUri: 'package:app/report.dart',
        line: 8,
        column: 1,
      ),
    )
    ..addNode(
      GraphNode(
        id: 'package:app/util.dart',
        sourceUri: 'package:app/util.dart',
        isLibrary: true,
      ),
    )
    ..addNode(
      GraphNode(
        id: 'package:app/util.dart::formatBytes',
        sourceUri: 'package:app/util.dart',
        line: 12,
        column: 1,
      ),
    )
    ..addNode(
      GraphNode(
        id: 'package:app/util.dart::formatColor',
        sourceUri: 'package:app/util.dart',
        line: 27,
        column: 1,
      ),
    )
    // Usage edges follow source -> target. `render` calls `formatBytes`, and
    // the import edge records the real library relationship.
    ..addEdge(
      const GraphEdge(
        sourceId: 'package:app/report.dart::render',
        targetId: 'package:app/util.dart::formatBytes',
        kind: EdgeKind.call,
      ),
    )
    ..addEdge(
      const GraphEdge(
        sourceId: 'package:app/report.dart',
        targetId: 'package:app/util.dart',
        kind: EdgeKind.import,
      ),
    );

  final session = SymbolQuerySession(
    graph: graph.snapshot(),
    // `render` is the only declaration the package publishes, so it is the
    // sole retention root here. Real analyses always surface non-empty
    // `limitations`; hand-built facts legitimately need none.
    roots: const {'package:app/report.dart::render': RetentionReason.publicApi},
    limitations: const [],
  );

  // `formatColor` is reachable from no retention root, so it is reported as
  // an observation with evidence — never as a deletion recommendation.
  // `formatBytes` stays alive through the call edge from `render`, and the
  // two library nodes stay alive through their contained declarations.
  final encoder = JsonEncoder.withIndent('  ');
  for (final finding in session.deadDeclarations) {
    print(encoder.convert(finding.toJson()));
  }
}
