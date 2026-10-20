import 'dart:convert';
import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/analysis_git.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/hostile_git_support.dart';
import '../support/route_fixture_support.dart';

/// `dartograph impact --format language-traversal` — isthmus trace용 순회
/// 문서 명령의 CLI 계약이다.
void main() {
  late Directory root;
  final fixedNow = DateTime.utc(2026, 9, 29, 1, 2, 3, 456);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('traversal-cli.');
  });
  tearDown(() => root.delete(recursive: true));

  Future<({int code, String output, String error})> run(
    List<String> arguments,
  ) async {
    final output = StringBuffer();
    final error = StringBuffer();
    final code = await runDartograph(
      arguments,
      output: output,
      error: error,
      now: () => fixedNow,
    );
    return (code: code, output: output.toString(), error: error.toString());
  }

  Future<void> writeClient() => writeRoutePackage(root, 'app', {
    'lib/api.dart': '''
import 'package:dio/dio.dart';

class UsersApi {
  UsersApi(this._dio);
  final Dio _dio;
  Future<void> load(int id) => _dio.get('/users/\$id');
}

class Screen {
  Screen(this.api);
  final UsersApi api;
  Future<void> open() => api.load(1);
}
''',
  });

  group('impact --format language-traversal', () {
    test('roots from a routes document reach their callers', () async {
      await writeClient();
      final routes = await run(['routes', '--role', 'client', root.path]);
      final facts = File(p.join(root.path, 'routes.json'));
      await facts.writeAsString(routes.output);
      final result = await run([
        'impact',
        '--format',
        'language-traversal',
        '--roots-from',
        facts.path,
        '--generated-at',
        '2026-09-29T00:00:00Z',
        '--revision',
        'rev-1',
        root.path,
      ]);
      expect(result.code, 0, reason: result.error);
      final document = jsonDecode(result.output) as Map<String, Object?>;
      expect(document['format'], 'language-traversal');
      expect(document['version'], 1);
      expect(document['direction'], 'dependents');
      expect(document['revision'], 'rev-1');
      expect(document['generatedAt'], '2026-09-29T00:00:00.000Z');
      expect(document['graphRevision'], startsWith('sha256:'));
      expect(document.containsKey('dispatch'), isFalse);
      expect(document['roots'], [
        {
          'id': 'package:app/api.dart::UsersApi.load',
          'symbol': {
            'kind': 'declaration',
            'location': {'line': 6, 'path': 'lib/api.dart'},
            'qualifiedName': 'UsersApi.load',
            'usr': 'package:app/api.dart::UsersApi.load',
          },
        },
      ]);
      final reached = [
        for (final row in document['reached']! as List)
          (row as Map<String, Object?>)['symbol'] as Map<String, Object?>,
      ];
      expect([
        for (final symbol in reached) symbol['usr'],
      ], contains('package:app/api.dart::Screen.open'));
    });

    test('an unknown root prints the document and exits 64', () async {
      await writeClient();
      final result = await run([
        'impact',
        '--format',
        'language-traversal',
        root.path,
        'package:app/api.dart::Missing',
      ]);
      expect(result.code, 64);
      final document = jsonDecode(result.output) as Map<String, Object?>;
      expect(document['roots'], [
        {'id': 'package:app/api.dart::Missing'},
      ]);
      expect(document['truncated'], isTrue);
      expect(document['truncationReasons'], ['root-not-found']);
      expect(
        document['limitations'],
        contains(startsWith('root-not-found: 1 requested root(s)')),
      );
    });

    test(
      'control characters, unsupported options and no roots exit 64',
      () async {
        await writeClient();
        final cases = [
          ['impact', '--format', 'language-traversal', root.path, 'a\u0001b'],
          [
            'impact',
            '--format',
            'language-traversal',
            '--revision',
            're v',
            root.path,
            'x',
          ],
          [
            'impact',
            '--format',
            'language-traversal',
            '--since',
            'HEAD',
            root.path,
          ],
          ['impact', '--format', 'language-traversal', root.path],
          [
            'impact',
            '--format',
            'language-traversal',
            '--direction',
            'sideways',
            root.path,
            'x',
          ],
        ];
        for (final arguments in cases) {
          final result = await run(arguments);
          expect(result.code, 64, reason: '$arguments');
          expect(result.output, isEmpty, reason: '$arguments');
        }
      },
    );

    test('revision is the clean git HEAD and omitted when dirty', () async {
      await writeClient();
      Future<void> git(List<String> arguments) async {
        final result = await Process.run('git', [
          '-C',
          root.path,
          '-c',
          'user.email=test@example.test',
          '-c',
          'user.name=test',
          ...arguments,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await File(
        p.join(root.path, '.gitignore'),
      ).writeAsString('.dart_tool/\n');
      await git(['init', '-q']);
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'init']);
      final head = (await Process.run('git', [
        '-C',
        root.path,
        'rev-parse',
        'HEAD',
      ])).stdout.toString().trim();
      Future<Object?> revision() async {
        final result = await run([
          'impact',
          '--format',
          'language-traversal',
          root.path,
          'package:app/api.dart::UsersApi.load',
        ]);
        expect(result.code, 0, reason: result.error);
        return (jsonDecode(result.output) as Map<String, Object?>)['revision'];
      }

      expect(await revision(), head);
      await File(
        p.join(root.path, 'lib', 'extra.dart'),
      ).writeAsString('void e() {}\n');
      expect(await revision(), isNull);
    });

    group('revision in a repository whose git settings name commands', () {
      // 색인은 가짜로 두어 git 판정만 본다. root가 그래프에 있어 종료 코드는 0이다.
      Future<Map<String, Object?>> traverse(String packageRoot) async {
        final graph = CodeGraph()
          ..addNode(
            GraphNode(
              id: 'project:lib/fx.dart::Alpha',
              sourceUri: 'project:lib/fx.dart',
            ),
          );
        final output = StringBuffer();
        final error = StringBuffer();
        final code = await runDartograph(
          [
            'impact',
            '--format',
            'language-traversal',
            packageRoot,
            'project:lib/fx.dart::Alpha',
          ],
          output: output,
          error: error,
          indexPackage: (_) async =>
              AnalyzerGraphResult(graph: graph, limitations: const []),
          now: () => fixedNow,
        );
        expect(code, 0, reason: error.toString());
        return jsonDecode(output.toString()) as Map<String, Object?>;
      }

      List<String> unverified(Map<String, Object?> document) => [
        for (final limitation in document['limitations']! as List)
          if ('$limitation'.startsWith('revision-unverified:')) '$limitation',
      ];

      const submoduleSettings = {
        HostileGitSetting.submoduleFilter,
        HostileGitSetting.submoduleFsmonitor,
        HostileGitSetting.submoduleHook,
      };

      for (final setting in HostileGitSetting.values) {
        test(
          '${setting.name} runs nothing while judging a clean HEAD',
          () async {
            final repository = await createHostileRepository(root, setting);

            final document = await traverse(repository.root);

            expect(repository.commandRan, isFalse);
            if (submoduleSettings.contains(setting)) {
              // 서브모듈 작업 트리는 보지 않으므로 깨끗하다고 주장하지 않는다.
              expect(document['revision'], isNull);
              expect(unverified(document), [
                startsWith(
                  'revision-unverified: the package root has 1 git '
                  'submodule(s);',
                ),
              ]);
            } else {
              expect(document['revision'], repository.head);
              expect(unverified(document), isEmpty);
            }
          },
          skip: Platform.isWindows
              ? 'the fixture plants POSIX sh scripts'
              : false,
        );
      }

      test('a refused git query explains the missing revision', () {
        // 2.45 미만 git의 거부는 시험 환경의 git으로 재현할 수 없어 이유를 직접 본다.
        expect(
          unverifiedRevisionNote(AnalysisGitRefusal.configurationUnreadable),
          isNull,
        );
        expect(
          unverifiedRevisionNote(AnalysisGitRefusal.unavoidableLazyFetch),
          startsWith(
            'revision-unverified: the git configuration names a promisor '
            'remote',
          ),
        );
        expect(
          unverifiedRevisionNote(
            AnalysisGitRefusal.unneutralizableFilterDriver,
          ),
          startsWith(
            'revision-unverified: the git configuration defines a filter '
            'driver',
          ),
        );
      });

      for (final transport in PromisorTransport.values) {
        test(
          'a partial clone missing the HEAD tree fetches nothing '
          '(${transport.name})',
          () async {
            final repository = await createPartialCloneRepository(
              root,
              transport,
              MissingObject.headTree,
            );

            final document = await traverse(repository.root);

            expect(repository.commandRan, isFalse);
            // git이 HEAD tree를 읽지 못하면 깨끗함을 확인할 수 없다.
            expect(document['revision'], isNull);
            expect(unverified(document), isEmpty);
          },
          skip: Platform.isWindows
              ? 'the fixture plants POSIX sh scripts'
              : false,
        );

        test(
          'a clean partial clone still records HEAD (${transport.name})',
          () async {
            final repository = await createPartialCloneRepository(
              root,
              transport,
              MissingObject.renamedFileBaseBlob,
            );

            final document = await traverse(repository.root);

            expect(repository.commandRan, isFalse);
            expect(document['revision'], repository.head);
            expect(unverified(document), isEmpty);
          },
          skip: Platform.isWindows
              ? 'the fixture plants POSIX sh scripts'
              : false,
        );
      }

      test(
        'a file its filter normalized is not claimed clean when its stat is stale',
        () async {
          // git-lfs처럼 clean filter가 커밋 내용을 바꾼 파일이다. filter를 끄면
          // 작업 트리 원본과 blob이 달라 보이므로 revision을 싣지 않는다(fail-safe).
          final repository = await createNormalizedFilterRepository(root);

          final document = await traverse(repository.root);

          expect(document['revision'], isNull);
          expect(unverified(document), isEmpty);
        },
        skip: Platform.isWindows
            ? 'the fixture plants POSIX sh scripts'
            : false,
      );

      for (final (label, rawName) in [
        ("'='", 'a=b'.codeUnits),
        ('invalid UTF-8', const [0xff, 0xfe]),
      ]) {
        test(
          'a driver name with $label leaves the revision unverified',
          () async {
            final repository = await createRepositoryWithFilterName(
              root,
              rawName,
            );

            final document = await traverse(repository.root);

            expect(repository.commandRan, isFalse);
            expect(document['revision'], isNull);
            expect(unverified(document), [
              startsWith(
                'revision-unverified: the git configuration defines a filter '
                'driver',
              ),
            ]);
          },
          skip: Platform.isWindows
              ? 'the fixture plants POSIX sh scripts'
              : false,
        );
      }
    });

    test(
      'roots-from stops reading as soon as the input passes 16 MiB',
      () async {
        // 쓰는 쪽이 16 MiB 남짓을 흘린 뒤 EOF 없이 파이프를 붙잡는다. 전부
        // 모은 뒤에야 길이를 보면 EOF를 기다리느라 상한 진단에 이르지 못하고,
        // 끝나지 않는 입력이면 메모리가 먼저 고갈된다.
        final fifo = p.join(root.path, 'roots.pipe');
        final mkfifo = await Process.run('mkfifo', [fifo]);
        expect(mkfifo.exitCode, 0, reason: mkfifo.stderr as String);
        final writer = await Process.start('sh', [
          '-c',
          r'exec 3> "$1"; head -c 17000000 /dev/zero >&3; exec sleep 120',
          'sh',
          fifo,
        ]);
        addTearDown(writer.kill);

        final result = await run([
          'impact',
          '--format',
          'language-traversal',
          '--roots-from',
          fifo,
          root.path,
        ]);

        expect(result.code, 64, reason: result.error);
        expect(result.error, contains('--roots-from exceeds 16 MiB.'));
        expect(result.output, isEmpty);
      },
      skip: Platform.isWindows,
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('roots-from reads a JSON string array', () {
      expect(parseTraversalRoots('["a","b"]'), ['a', 'b']);
      expect(
        parseTraversalRoots(
          '{"format":"bridge-facts","facts":[{"symbol":{"usr":"u"}},{}]}',
        ),
        ['u'],
      );
      expect(() => parseTraversalRoots('[1]'), throwsFormatException);
      expect(
        () => parseTraversalRoots('{"format":"x"}'),
        throwsFormatException,
      );
    });

    test('exchange text rejects control characters and lone surrogates', () {
      expect(isExchangeText('package:a/b.dart::C'), isTrue);
      expect(isExchangeText('😀'), isTrue);
      expect(isExchangeText(' '), isFalse);
      expect(isExchangeText('a\u0085b'), isFalse);
      expect(isExchangeText('a\uD800'), isFalse);
      expect(isExchangeText('\uDC00a'), isFalse);
    });
  });
}
