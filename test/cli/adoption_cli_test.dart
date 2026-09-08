import 'dart:convert';
import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/changed_files.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late AnalyzerGraphResult indexed;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('adoption-cli.');
    final library = Directory(p.join(directory.path, 'lib'))..createSync();
    File(p.join(library.path, 'dead.dart')).writeAsStringSync('void dead() {}');
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'package:app/main.dart'))
      ..addNode(GraphNode(id: 'package:app/main.dart::main'))
      ..addNode(GraphNode(id: 'package:app/dead.dart'))
      ..addNode(
        GraphNode(
          id: 'package:app/dead.dart::dead',
          sourceUri: 'project:lib/dead.dart',
          line: 4,
          column: 2,
        ),
      );
    indexed = AnalyzerGraphResult(
      graph: graph,
      limitations: const [AnalyzerLimitation.conditionalConfiguration],
      retentionRoots: const {
        'package:app/main.dart::main': RetentionReason.mainEntryPoint,
      },
    );
  });

  tearDown(() => directory.delete(recursive: true));

  test(
    'baseline command writes a file that dead uses for suppression',
    () async {
      final path = p.join(directory.path, '.dartograph-baseline.json');
      final baselineOutput = StringBuffer();
      expect(
        await runDartograph(
          ['baseline', '--write', path, directory.path],
          output: baselineOutput,
          indexPackage: (_) async => indexed,
        ),
        ExitStatus.success.code,
      );
      expect(File(path).existsSync(), isTrue);

      final output = StringBuffer();
      expect(
        await runDartograph(
          ['dead', '--format', 'json', '--baseline', path, directory.path],
          output: output,
          indexPackage: (_) async => indexed,
        ),
        ExitStatus.success.code,
      );
      expect(output.toString(), contains('"findings":[]'));
      expect(output.toString(), contains('"suppressedCount":2'));
    },
  );

  test('since limits findings and every report format is accepted', () async {
    final canonicalRoot = await directory.resolveSymbolicLinks();
    for (final format in ['text', 'json', 'github-actions', 'sarif']) {
      final output = StringBuffer();
      expect(
        await runDartograph(
          [
            'dead',
            '--format',
            format,
            '--since',
            'origin/main',
            directory.path,
          ],
          output: output,
          indexPackage: (_) async => indexed,
          changedFilesSince: (_, root) async => {
            p.normalize(p.join(canonicalRoot, 'lib/dead.dart')),
          },
        ),
        ExitStatus.findings.code,
      );
      expect(
        output.toString(),
        contains('unreachable from all retention roots'),
      );
    }
  });

  test(
    'since canonicalizes an in-repository symlink before matching',
    () async {
      Directory(p.join(directory.path, 'lib')).deleteSync(recursive: true);
      final sources = Directory(p.join(directory.path, 'sources'))
        ..createSync();
      File(
        p.join(sources.path, 'dead.dart'),
      ).writeAsStringSync('void dead() {}');
      Link(p.join(directory.path, 'lib')).createSync('sources');
      final canonicalSource = await File(
        p.join(directory.path, 'lib', 'dead.dart'),
      ).resolveSymbolicLinks();

      final output = StringBuffer();
      expect(
        await runDartograph(
          ['dead', '--format', 'json', '--since', 'HEAD', directory.path],
          output: output,
          indexPackage: (_) async => indexed,
          changedFilesSince: (_, _) async => {canonicalSource},
        ),
        ExitStatus.findings.code,
      );
      expect(output.toString(), contains('package:app/dead.dart::dead'));
    },
  );

  test('since includes an unmappable source instead of hiding it', () async {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'package:app/main.dart'))
      ..addNode(GraphNode(id: 'package:app/main.dart::main'))
      ..addNode(GraphNode(id: 'package:app/unknown.dart::dead'));
    final result = AnalyzerGraphResult(
      graph: graph,
      limitations: const [],
      retentionRoots: const {
        'package:app/main.dart::main': RetentionReason.mainEntryPoint,
      },
    );
    final output = StringBuffer();

    expect(
      await runDartograph(
        ['dead', '--format', 'json', '--since', 'HEAD', directory.path],
        output: output,
        indexPackage: (_) async => result,
        changedFilesSince: (_, _) async => const {},
      ),
      ExitStatus.findings.code,
    );
    expect(output.toString(), contains('package:app/unknown.dart::dead'));
  });

  test('dead explain returns usage for an unknown graph id', () async {
    final output = StringBuffer();

    expect(
      await runDartograph(
        [
          'dead',
          '--explain',
          'package:app/missing.dart::missing',
          '--format',
          'json',
          directory.path,
        ],
        output: output,
        indexPackage: (_) async => indexed,
      ),
      ExitStatus.usage.code,
    );
    expect(jsonDecode(output.toString()), {
      'id': 'package:app/missing.dart::missing',
      'known': false,
      'limitations': [
        'conditional imports and exports use one analyzer configuration',
      ],
      'reachable': false,
      'reason': 'not found in graph',
    });
  });

  test('dead explain reports a reachable library witness', () async {
    final output = StringBuffer();

    expect(
      await runDartograph(
        [
          'dead',
          '--explain',
          'package:app/main.dart',
          '--format',
          'json',
          directory.path,
        ],
        output: output,
        indexPackage: (_) async => indexed,
      ),
      ExitStatus.success.code,
    );
    expect(
      jsonDecode(output.toString()),
      containsPair('witness', 'package:app/main.dart::main'),
    );
  });

  test('dead explain rejects baseline and since before indexing', () async {
    for (final scopedOption in [
      ['--baseline', p.join(directory.path, 'baseline.json')],
      ['--since', 'HEAD'],
    ]) {
      var indexedPackage = false;

      expect(
        await runDartograph(
          [
            'dead',
            '--explain',
            'package:app/main.dart::main',
            '--format',
            'json',
            ...scopedOption,
            directory.path,
          ],
          output: StringBuffer(),
          error: StringBuffer(),
          indexPackage: (_) async {
            indexedPackage = true;
            return indexed;
          },
        ),
        ExitStatus.usage.code,
      );
      expect(indexedPackage, isFalse);
    }
  });

  test('invalid baselines have a specific path-free diagnostic', () async {
    final baseline = File(p.join(directory.path, 'invalid-baseline.json'));
    await baseline.writeAsString('{}');
    for (final arguments in [
      ['dead', '--format', 'json', '--baseline', baseline.path, directory.path],
      ['query', 'dead', '--baseline', baseline.path, directory.path],
    ]) {
      final errors = StringBuffer();

      expect(
        await runDartograph(
          arguments,
          error: errors,
          indexPackage: (_) async => indexed,
        ),
        ExitStatus.failure.code,
      );
      expect(
        errors.toString(),
        'Baseline is invalid: create it with dartograph baseline --write.\n',
      );
      expect(errors.toString(), isNot(contains(baseline.path)));
    }
  });

  test('since failures use the documented analysis-failure exit', () async {
    final errors = StringBuffer();
    expect(
      await runDartograph(
        ['dead', '--format', 'json', '--since', 'missing', directory.path],
        error: errors,
        indexPackage: (_) async => indexed,
        changedFilesSince: (_, _) =>
            ChangedFiles.since('missing', directory.path),
      ),
      ExitStatus.failure.code,
    );
    expect(
      errors.toString(),
      'Changed files could not be computed. In CI, fetch full Git history.\n',
    );
  });

  test(
    'baseline StateError uses the documented analysis-failure exit',
    () async {
      final errors = StringBuffer();
      expect(
        await runDartograph(
          [
            'baseline',
            '--write',
            p.join(directory.path, 'baseline.json'),
            directory.path,
          ],
          error: errors,
          indexPackage: (_) => throw StateError('index failed'),
        ),
        ExitStatus.failure.code,
      );
      expect(
        errors.toString(),
        'Analysis failed: unable to index the package.\n',
      );
    },
  );

  test(
    'a missing baseline file is reported as invalid, not an index failure',
    () async {
      final absent = p.join(directory.path, 'absent-baseline.json');
      // dead와 query가 같은 _readBaseline을 공유하므로 둘 다 검증한다.
      for (final arguments in [
        ['dead', '--format', 'json', '--baseline', absent, directory.path],
        ['query', 'dead', '--baseline', absent, directory.path],
      ]) {
        final errors = StringBuffer();
        expect(
          await runDartograph(
            arguments,
            error: errors,
            indexPackage: (_) async => indexed,
          ),
          ExitStatus.failure.code,
        );
        // baseline 부재(PathNotFoundException)는 인덱싱 실패가 아니다. 원인을
        // 반대로 가리키지 않고 정확한 안내를 낸다.
        expect(
          errors.toString(),
          'Baseline is invalid: create it with dartograph baseline --write.\n',
        );
        expect(errors.toString(), isNot(contains('unable to index')));
        expect(errors.toString(), isNot(contains(absent)));
      }
    },
  );
}
