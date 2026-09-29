import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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
