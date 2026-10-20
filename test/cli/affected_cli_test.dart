import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/analysis_git.dart';
import 'package:dartograph/src/cli/changed_files.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/hostile_git_support.dart';

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
    'a matched source without a library node counts toward the limitation',
    () async {
      // 소스 URI는 매치되지만 라이브러리 노드가 없는(ghost) 선언 — 조용히
      // 사라지지 않고 unmapped 한계로 보고된다.
      final ghost = File(p.join(directory.path, 'lib/ghost.dart'));
      await ghost.writeAsString('// ghost\n');
      final graph = CodeGraph()
        ..addNode(
          GraphNode(
            id: 'project:lib/ghost.dart::run',
            sourceUri: 'project:lib/ghost.dart',
          ),
        );
      final output = StringBuffer();
      final status = await runDartograph(
        ['affected', 'HEAD', directory.path],
        output: output,
        error: StringBuffer(),
        indexPackage: (_) async =>
            AnalyzerGraphResult(graph: graph, limitations: const []),
        changedFilesSince: (_, _) async => {
          p.normalize(p.join(canonicalRoot, 'lib/ghost.dart')),
        },
      );

      expect(status, ExitStatus.success.code);
      expect(output.toString(), contains('"changed":[]'));
      expect(
        output.toString(),
        contains('changed-dart-files-without-library: 1'),
      );
    },
  );

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

  test(
    'affected runs no repository git setting while computing changed files',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'affected-hostile.',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final repository = await createHostileRepository(
        workspace,
        HostileGitSetting.committedAttributes,
      );
      File(
        repository.path('lib/edited.dart'),
      ).writeAsStringSync('class Edited {\n  int value = 0;\n}\n');
      final graph = CodeGraph()
        ..addNode(
          GraphNode(
            id: 'project:lib/edited.dart',
            sourceUri: 'project:lib/edited.dart',
          ),
        )
        ..addNode(
          GraphNode(
            id: 'project:lib/fx.dart',
            sourceUri: 'project:lib/fx.dart',
          ),
        );
      final output = StringBuffer();

      final status = await runDartograph(
        ['affected', 'HEAD', repository.root],
        output: output,
        error: StringBuffer(),
        indexPackage: (_) async =>
            AnalyzerGraphResult(graph: graph, limitations: const []),
      );

      expect(status, ExitStatus.success.code);
      expect(repository.commandRan, isFalse);
      // stat만 낡은 fx.dart도 씨앗이다. git이 내용을 다시 읽지 않는다.
      expect(
        output.toString(),
        '{"affected":[],"changed":["project:lib/edited.dart",'
        '"project:lib/fx.dart"],"limitations":[]}\n',
      );
    },
    skip: Platform.isWindows ? 'the fixture plants POSIX sh scripts' : false,
  );

  test(
    'a filter driver git cannot be told to skip is diagnosed, not run',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'affected-unsafe-driver.',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final repository = await createRepositoryWithFilterName(
        workspace,
        'a=b'.codeUnits,
      );
      final errors = StringBuffer();

      final status = await runDartograph(
        ['affected', 'HEAD', repository.root],
        output: StringBuffer(),
        error: errors,
        indexPackage: (_) async => indexed,
      );

      expect(status, ExitStatus.failure.code);
      expect(repository.commandRan, isFalse);
      expect(
        errors.toString(),
        'Changed files could not be computed: the git configuration defines a '
        "filter driver whose name contains '=' or is not valid UTF-8, which "
        'git cannot be told to skip. Rename or remove that filter driver.\n',
      );
    },
    skip: Platform.isWindows ? 'the fixture plants POSIX sh scripts' : false,
  );

  test(
    'a partial clone without the base history is diagnosed, not fetched',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'affected-partial-clone.',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final repository = await createPartialCloneRepository(
        workspace,
        PromisorTransport.sshCommand,
        MissingObject.baseCommit,
      );
      final errors = StringBuffer();

      final status = await runDartograph(
        ['affected', 'base', repository.root],
        output: StringBuffer(),
        error: errors,
        indexPackage: (_) async => indexed,
      );

      expect(status, ExitStatus.failure.code);
      expect(repository.commandRan, isFalse);
      expect(
        errors.toString(),
        'Changed files could not be computed. In a partial clone, dartograph '
        'does not let git fetch missing objects from the promisor remote; '
        'fetch the history you compare against first (in CI, fetch full Git '
        'history).\n',
      );
    },
    skip: partialCloneSkip,
  );

  test('a git that cannot skip the promisor fetch is diagnosed', () async {
    // 2.45 미만 git은 시험 환경의 git으로 재현할 수 없어 거부 결과를 주입한다.
    final errors = StringBuffer();

    final status = await runDartograph(
      ['affected', 'HEAD', directory.path],
      output: StringBuffer(),
      error: errors,
      indexPackage: (_) async => indexed,
      changedFilesSince: (_, _) async => throw const ChangedFilesException(
        refusal: AnalysisGitRefusal.unavoidableLazyFetch,
      ),
    );

    expect(status, ExitStatus.failure.code);
    expect(
      errors.toString(),
      'Changed files could not be computed: the git configuration names a '
      'promisor remote (a partial clone), and git older than 2.45 cannot be '
      'told not to fetch missing objects from it, which runs commands from '
      "the remote's settings. Use git 2.45 or newer.\n",
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
  test(
    'affected maps a changed symlink path to its library bidirectionally',
    () async {
      final lib = Directory(p.join(directory.path, 'lib'));
      final real = File(p.join(lib.path, 'real.dart'));
      await real.writeAsString('void linkedTarget() {}\n');
      await Link(p.join(lib.path, 'link.dart')).create('real.dart');
      final graph = CodeGraph()
        ..addNode(
          GraphNode(
            id: 'project:lib/link.dart',
            sourceUri: 'project:lib/link.dart',
          ),
        );
      final linked = AnalyzerGraphResult(graph: graph, limitations: const []);
      final linkPath = p.normalize(p.join(canonicalRoot, 'lib/link.dart'));
      final targetPath = await real.resolveSymbolicLinks();

      Future<String> runWith(Set<String> changed) async {
        final output = StringBuffer();
        expect(
          await runDartograph(
            ['affected', 'HEAD', directory.path],
            output: output,
            error: StringBuffer(),
            indexPackage: (_) async => linked,
            changedFilesSince: (_, _) async => changed,
          ),
          ExitStatus.success.code,
        );
        return output.toString();
      }

      // 링크 파일 자체의 변경(링크 경로)과 대상 변경(실 경로) 모두 씨앗이 된다.
      expect(
        await runWith({linkPath}),
        contains('"changed":["project:lib/link.dart"]'),
      );
      expect(
        await runWith({targetPath}),
        contains('"changed":["project:lib/link.dart"]'),
      );
      expect(await runWith(const {}), contains('"changed":[]'));
    },
  );
}
