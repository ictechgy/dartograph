import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/changed_files.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String canonicalRoot;
  late AnalyzerGraphResult indexed;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('affected-cli.');
    canonicalRoot = await directory.resolveSymbolicLinks();
    final library = Directory(p.join(directory.path, 'lib'))..createSync();
    for (final name in const ['a.dart', 'b.dart', 'c.dart']) {
      File(p.join(library.path, name)).writeAsStringSync('// $name\n');
    }
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart'))
      ..addNode(GraphNode(id: 'project:lib/b.dart'))
      ..addNode(
        GraphNode(id: 'project:lib/c.dart', sourceUri: 'project:lib/c.dart'),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/a.dart',
          targetId: 'project:lib/b.dart',
          kind: EdgeKind.import,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/b.dart',
          targetId: 'project:lib/c.dart',
          kind: EdgeKind.import,
        ),
      );
    indexed = AnalyzerGraphResult(graph: graph, limitations: const []);
  });

  tearDown(() => directory.delete(recursive: true));

  test(
    'affected answers changed libraries and transitive dependents',
    () async {
      final output = StringBuffer();
      final status = await runDartograph(
        ['affected', 'origin/main', directory.path],
        output: output,
        error: StringBuffer(),
        indexPackage: (_) async => indexed,
        changedFilesSince: (reference, root) async {
          expect(reference, 'origin/main');
          expect(root, directory.path);
          return {p.normalize(p.join(canonicalRoot, 'lib/c.dart'))};
        },
      );

      expect(status, ExitStatus.success.code);
      expect(
        output.toString(),
        '{"affected":[{"depth":2,"id":"project:lib/a.dart","path":'
        '["project:lib/a.dart","project:lib/b.dart","project:lib/c.dart"]},'
        '{"depth":1,"id":"project:lib/b.dart","path":'
        '["project:lib/b.dart","project:lib/c.dart"]}],'
        '"changed":["project:lib/c.dart"],"limitations":[]}\n',
      );
    },
  );

  test('affected reports success even when nothing changed', () async {
    final output = StringBuffer();
    final status = await runDartograph(
      ['affected', 'HEAD', directory.path],
      output: output,
      error: StringBuffer(),
      indexPackage: (_) async => indexed,
      changedFilesSince: (_, _) async => const {},
    );

    expect(status, ExitStatus.success.code);
    expect(
      output.toString(),
      '{"affected":[],"changed":[],"limitations":[]}\n',
    );
  });

  test('a changed Dart file without a library becomes a limitation', () async {
    final unmapped = File(p.join(directory.path, 'lib/generated.dart'));
    await unmapped.writeAsString('// excluded from analysis\n');
    final output = StringBuffer();
    final status = await runDartograph(
      ['affected', 'HEAD', directory.path],
      output: output,
      error: StringBuffer(),
      indexPackage: (_) async => indexed,
      changedFilesSince: (_, _) async => {
        p.normalize(p.join(canonicalRoot, 'lib/c.dart')),
        p.normalize(p.join(canonicalRoot, 'lib/generated.dart')),
      },
    );

    expect(status, ExitStatus.success.code);
    expect(
      output.toString(),
      contains(
        '"limitations":["changed-dart-files-without-library: 1 changed Dart '
        'file(s) are not part of any analyzed library"]',
      ),
    );
    expect(output.toString(), contains('"changed":["project:lib/c.dart"]'));
  });

  test(
    'changed files outside the package root are not counted as unmapped',
    () async {
      final status = await runDartograph(
        ['affected', 'HEAD', directory.path],
        output: StringBuffer(),
        error: StringBuffer(),
        indexPackage: (_) async => indexed,
        // 모노레포: 저장소 루트 기준 변경이 패키지 밖에 있다.
        changedFilesSince: (_, _) async => {
          '${p.dirname(canonicalRoot)}/other.dart',
        },
      );

      expect(status, ExitStatus.success.code);
    },
  );

  test('affected rejects malformed invocations as usage errors', () async {
    var calls = 0;
    for (final invocation in [
      ['affected'],
      ['affected', 'HEAD'],
      ['affected', directory.path],
      ['affected', 'HEAD', directory.path, 'extra'],
      ['affected', '--strict', directory.path],
      ['affected', 'HEAD', '--strict'],
    ]) {
      expect(
        await runDartograph(
          invocation,
          output: StringBuffer(),
          error: StringBuffer(),
          indexPackage: (_) async {
            calls++;
            return indexed;
          },
          changedFilesSince: (_, _) async => const {},
        ),
        ExitStatus.usage.code,
        reason: invocation.join(' '),
      );
    }
    expect(calls, 0);
  });

  test('git failures keep the documented changed-files diagnosis', () async {
    final errors = StringBuffer();
    final status = await runDartograph(
      ['affected', 'missing-ref', directory.path],
      output: StringBuffer(),
      error: errors,
      indexPackage: (_) async => indexed,
      changedFilesSince: (_, _) async => throw const ChangedFilesException(),
    );

    expect(status, ExitStatus.failure.code);
    expect(
      errors.toString(),
      'Changed files could not be computed. In CI, fetch full Git history.\n',
    );
  });

  test('index failures are not blamed on git', () async {
    final errors = StringBuffer();
    final status = await runDartograph(
      ['affected', 'HEAD', directory.path],
      output: StringBuffer(),
      error: errors,
      indexPackage: (_) async => throw StateError('index failed'),
      changedFilesSince: (_, _) async => const {},
    );

    expect(status, ExitStatus.failure.code);
    expect(
      errors.toString(),
      'Analysis failed: unable to index the package.\n',
    );
  });
}
