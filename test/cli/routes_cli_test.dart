import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/route_fixture_support.dart';

/// `dartograph routes --role client`와 `impact --format language-traversal` —
/// isthmus http 도메인 교환 명령의 CLI 계약이다.
void main() {
  late Directory root;
  final fixedNow = DateTime.utc(2026, 9, 29, 1, 2, 3, 456);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('routes-cli.');
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

  group('routes', () {
    test('emits a client http document with usr identities', () async {
      await writeClient();
      final result = await run(['routes', '--role', 'client', root.path]);
      expect(result.code, 0, reason: result.error);
      final document = jsonDecode(result.output) as Map<String, Object?>;
      expect(document['target'], 'http');
      expect(document['roles'], ['client']);
      expect(document['sourceSets'], {'tests': 'excluded'});
      expect(document['platform'], 'dart');
      expect(document['project'], root.resolveSymbolicLinksSync());
      expect(document['generatedAt'], '2026-09-29T01:02:03.456Z');
      expect((document['facts']! as List).single, {
        'baseRef': 'package:app/api.dart::UsersApi._dio',
        'channel': '/users/{}',
        'dynamic': false,
        'kind': 'route-call',
        'location': {'column': 32, 'line': 6, 'path': 'lib/api.dart'},
        'method': 'GET',
        'pathAnchor': 'base',
        'symbol': {
          'qualifiedName': 'UsersApi.load',
          'usr': 'package:app/api.dart::UsersApi.load',
        },
      });
    });

    test('a scan without calls keeps target http and roles', () async {
      await writeRoutePackage(root, 'app', {'lib/a.dart': 'void a() {}\n'});
      final result = await run([
        'routes',
        '--role',
        'client',
        '--include-tests',
        '--service',
        'example-mobile',
        '--format',
        'json',
        root.path,
      ]);
      expect(result.code, 0, reason: result.error);
      final document = jsonDecode(result.output) as Map<String, Object?>;
      expect(document['target'], 'http');
      expect(document['facts'], isEmpty);
      expect(document['service'], 'example-mobile');
      expect(document['sourceSets'], {'tests': 'included'});
    });

    test('--project writes locations relative to the shared root', () async {
      final package = Directory(p.join(root.path, 'packages', 'app'));
      await package.create(recursive: true);
      await writeRoutePackage(package, 'app', {
        'lib/a.dart': '''
import 'package:http/http.dart' as http;
Future<void> a() => http.get(Uri.parse('https://api.example.test/a'));
''',
      });
      final result = await run([
        'routes',
        '--role',
        'client',
        '--project',
        root.path,
        package.path,
      ]);
      expect(result.code, 0, reason: result.error);
      final document = jsonDecode(result.output) as Map<String, Object?>;
      expect(document['project'], root.resolveSymbolicLinksSync());
      final fact = (document['facts']! as List).single as Map<String, Object?>;
      expect(
        (fact['location']! as Map<String, Object?>)['path'],
        'packages/app/lib/a.dart',
      );
      // usr는 impact와 같은 패키지 루트 기준 ID다.
      expect(
        (fact['symbol']! as Map<String, Object?>)['usr'],
        'package:app/a.dart::a',
      );
    });

    test('usage errors exit 64', () async {
      await writeClient();
      final cases = [
        ['routes', root.path],
        ['routes', '--role', 'server', root.path],
        ['routes', '--role', 'client', '--format', 'text', root.path],
        ['routes', '--role', 'client', '--service', ' ', root.path],
        ['routes', '--role', 'client', '--bogus', root.path],
        ['routes', '--role', 'client'],
        ['routes', '--role', 'client', '--role', 'client', root.path],
        [
          'routes',
          '--role',
          'client',
          '--wrappers',
          p.join(root.path, 'missing.json'),
          root.path,
        ],
      ];
      for (final arguments in cases) {
        expect((await run(arguments)).code, 64, reason: '$arguments');
      }
    });

    test('an invalid wrappers file and a service conflict exit 64', () async {
      await writeClient();
      final invalid = File(p.join(root.path, 'bad.json'));
      await invalid.writeAsString(
        '{"format":"http-wrappers","version":1,"wrappers":[{"language":"dart",'
        '"kind":"function","owner":"not an id","name":"send",'
        '"pathArg":{"index":0},"defaultMethod":"GET","pathAnchor":"root"}]}',
      );
      final bad = await run([
        'routes',
        '--role',
        'client',
        '--wrappers',
        invalid.path,
        root.path,
      ]);
      expect(bad.code, 64);
      expect(bad.error, contains('wrappers[0].owner'));
      expect(bad.error, isNot(contains('not an id')));
      final conflicting = File(p.join(root.path, 'service.json'));
      await conflicting.writeAsString(
        '{"format":"http-wrappers","version":1,"wrappers":[{"language":"dart",'
        '"kind":"function","owner":"package:app/api.dart","name":"send",'
        '"pathArg":{"index":0},"defaultMethod":"GET","pathAnchor":"root",'
        '"service":"a"}]}',
      );
      final conflict = await run([
        'routes',
        '--role',
        'client',
        '--service',
        'b',
        '--wrappers',
        conflicting.path,
        root.path,
      ]);
      expect(conflict.code, 64);
    });
  });
}
