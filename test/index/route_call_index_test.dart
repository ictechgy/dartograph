import 'dart:io';

import 'package:dartograph/src/index/http_wrappers.dart';
import 'package:dartograph/src/index/route_call_index.dart';
import 'package:test/test.dart';

import '../support/route_fixture_support.dart';

/// `routes` 스캐너의 신원·한계·정책 회귀다. 기대값은 각 라이브러리의 확인된
/// 동작(fixtures/http_routes 오라클)과 계약 문서에서 손으로 적었다.
void main() {
  Future<RouteCallIndexResult> scan(
    Map<String, String> files, {
    List<HttpWrapperDeclaration> wrappers = const [],
    bool includeTests = false,
    bool resolvePackages = true,
  }) async {
    final root = await Directory.systemTemp.createTemp('dartograph-route');
    addTearDown(() => root.delete(recursive: true));
    await writeRoutePackage(root, 'app', files);
    if (!resolvePackages) {
      await File('${root.path}/.dart_tool/package_config.json').writeAsString(
        '{"configVersion":2,"packages":[{"name":"app","rootUri":"../",'
        '"packageUri":"lib/","languageVersion":"3.11"}]}',
      );
    }
    return indexRouteCalls(
      root.path,
      wrappers: wrappers,
      includeTests: includeTests,
    );
  }

  List<String> templates(RouteCallIndexResult result) => [
    for (final fact in result.facts) '${fact['method']} ${fact['channel']}',
  ];

  test(
    'a project function named like an http API is not a route call',
    () async {
      final result = await scan({
        'lib/a.dart': '''
Future<void> get(Uri url) async {}
Future<void> run() => get(Uri.parse('https://api.example.test/x'));
''',
      });
      expect(result.facts, isEmpty);
      expect(result.limitations, isEmpty);
    },
  );

  test('unresolved client packages are coverage gaps, not facts', () async {
    final result = await scan({
      'lib/a.dart': '''
import 'package:dio/dio.dart';
Future<void> run(Dio dio) => dio.get('/users');
''',
    }, resolvePackages: false);
    expect(result.facts, isEmpty);
    expect(
      result.limitations.single,
      startsWith('route-call-coverage: 1 import(s) of HTTP client packages'),
    );
  });

  test('test sources are excluded unless included with testSource', () async {
    const files = {
      'test/a_test.dart': '''
import 'package:http/http.dart' as http;
Future<void> main() async => http.get(Uri.parse('https://api.example.test/t'));
''',
    };
    expect((await scan(files)).facts, isEmpty);
    final included = await scan(files, includeTests: true);
    expect(included.facts.single['testSource'], isTrue);
    expect(included.facts.single['channel'], '/t');
  });

  test('a rewritten dio base drops the literal base (base anchor)', () async {
    final result = await scan({
      'lib/a.dart': '''
import 'package:dio/dio.dart';
final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'));
void configure() { dio.options.baseUrl = 'https://other.example.test'; }
Future<void> run() => dio.get('/users');
''',
    });
    final fact = result.facts.single;
    expect(fact['channel'], '/users');
    expect(fact['pathAnchor'], 'base');
    expect(fact.containsKey('authority'), isFalse);
  });

  test('an interceptor rewriting the path turns dio calls dynamic', () async {
    final result = await scan({
      'lib/a.dart': '''
import 'package:dio/dio.dart';
final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'));
class Rewrite extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.path = '/mock' + options.path;
    handler.next(options);
  }
}
Future<void> run() => dio.get('/users');
''',
    });
    final fact = result.facts.single;
    expect(fact['dynamic'], isTrue);
    expect(fact['channelPrefix'], '/v1/users');
    expect(
      result.limitations.single,
      startsWith('url-rewrite-interceptors: 1 site(s) rewrite dio'),
    );
  });

  test('unmodelled client APIs are counted as coverage', () async {
    final result = await scan({
      'lib/a.dart': '''
import 'dart:io';
import 'package:dio/dio.dart';
Future<void> run(Dio dio, HttpClient client) async {
  await dio.fetch(RequestOptions(path: '/x'));
  await client.getUrl(Uri.parse('https://api.example.test/y'));
}
''',
    });
    expect(result.facts, isEmpty);
    expect(
      result.limitations.single,
      'route-call-coverage: 2 call site(s) use HTTP client APIs this producer '
      'does not model (dart:io HttpClient 1, dio fetch/download 1); their '
      'requests are not facts',
    );
  });

  test('webhook and high-entropy segments are masked', () async {
    final result = await scan({
      'lib/a.dart': '''
import 'package:http/http.dart' as http;
Future<void> slack() =>
    http.post(Uri.parse('https://hooks.slack.com/services/T0/B0/XYZ'));
Future<void> token() => http.get(
  Uri.parse('https://api.example.test/v1/a1b2c3d4e5f6a7b8c9'),
);
''',
    });
    expect(templates(result), ['POST /{}/{}/{}/{}', 'GET /v1/{}']);
    expect([for (final f in result.facts) f['maskedSegments']], [4, 1]);
  });

  test('a declared wrapper that matches no call is unresolved', () async {
    const wrapper = HttpWrapperDeclaration(
      position: 3,
      language: 'dart',
      kind: 'function',
      owner: 'package:app/a.dart',
      name: 'missing',
      pathArg: WrapperArgument(index: 0),
      defaultMethod: 'GET',
      pathAnchor: 'root',
    );
    final result = await scan(
      {'lib/a.dart': 'void unrelated() {}\n'},
      wrappers: [wrapper],
    );
    expect(
      result.limitations.single,
      startsWith(
        'http-wrapper-unresolved: 1 declared dart wrapper(s) matched '
        'no call (wrappers[3])',
      ),
    );
  });

  test('a retrofit base passed by a constructor call is not trusted', () async {
    final result = await scan({
      'lib/api.dart': '''
import 'package:dio/dio.dart';
import 'package:retrofit/retrofit.dart';
@RestApi(baseUrl: 'https://api.example.test/v1')
abstract class Api {
  factory Api(Dio dio, {String? baseUrl}) => throw UnimplementedError();
  @GET('/users')
  Future<void> users();
}
Api staging(Dio dio) => Api(dio, baseUrl: 'https://staging.example.test');
''',
    });
    final fact = result.facts.single;
    expect(fact['channel'], '/users');
    expect(fact['pathAnchor'], 'base');
  });

  test(
    'generated files with client calls outside a service are gaps',
    () async {
      final result = await scan({
        'lib/a.dart': "part 'a.g.dart';\n",
        'lib/a.g.dart': '''
part of 'a.dart';
Future<void> generated(Dio dio) => dio.get('/generated');
''',
        'lib/b.dart': '''
import 'package:dio/dio.dart';
export 'a.dart';
''',
      });
      expect(result.facts, isEmpty);
      // a.g.dart는 dio를 import하지 않아 호출이 해석되지 않는다 — 해석된 경우만
      // 센다. 해석되는 생성 파일은 아래에서 확인한다.
      final resolved = await scan({
        'lib/a.dart': "import 'package:dio/dio.dart';\npart 'a.g.dart';\n",
        'lib/a.g.dart': '''
part of 'a.dart';
Future<void> generated(Dio dio) => dio.get('/generated');
''',
      });
      expect(resolved.facts, isEmpty);
      expect(
        resolved.limitations.single,
        startsWith('generated-client-unscanned: 1 generated Dart file(s)'),
      );
    },
  );

  test('dio configuration through cascades, fields and BaseOptions', () async {
    final result = await scan({
      'lib/a.dart': """
import 'package:dio/dio.dart';
const kBase = 'https://api.example.test';
final cascade = Dio()..options.baseUrl = '\$kBase/c';
final replaced = Dio()..options = BaseOptions(baseUrl: '\$kBase/r', method: 'post');
final options = BaseOptions(baseUrl: '\$kBase/o');
class Holder {
  final dio = Dio(options);
  Future<void> run() => dio.get('/x');
}
Future<void> a() => cascade.get('/users');
Future<void> b() => replaced.request('/orders');
Future<void> c(String host) => Dio(BaseOptions(baseUrl: host)).head('/h');
""",
    });
    expect(templates(result), [
      'GET /o/x',
      'GET /c/users',
      'POST /r/orders',
      'HEAD /h',
    ]);
    expect(result.facts[3]['pathAnchor'], 'base');
  });

  test('copyWith on RequestOptions rewrites base and method', () async {
    final result = await scan({
      'lib/a.dart': """
import 'package:dio/dio.dart';
final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/v1'));
RequestOptions retarget(RequestOptions o) =>
    o.copyWith(baseUrl: 'https://mock.example.test', method: 'GET');
Future<void> run() => dio.post('/users');
""",
    });
    final fact = result.facts.single;
    expect(fact['channel'], '/users');
    expect(fact['pathAnchor'], 'base');
    expect(fact['methodDynamic'], isTrue);
    expect(result.limitations.single, contains('baseUrl 1, method 1'));
  });

  test('string concatenation, query tails and tryParse resolve', () async {
    final result = await scan({
      'lib/a.dart': """
import 'package:http/http.dart' as http;
const base = 'https://api.example.test';
Future<void> a(String? q) {
  final tail = q == null ? '' : '?q=' + q;
  return http.get(Uri.tryParse(base + '/search' + tail)!);
}
Future<void> b(int id) {
  final uri = Uri.parse('\$base/items/' + id.toString());
  return http.get(uri);
}
Future<void> c(Uri uri) => http.get(uri);
Future<void> d(String path) => http.get(Uri.https('api.example.test', path));
""",
    });
    expect(templates(result), [
      'GET /search',
      'GET /items/{}',
      'GET null',
      'GET null',
    ]);
    expect(result.facts[0]['queryTailStripped'], isTrue);
    // 매개변수 Uri를 그대로 보내는 함수는 선언되지 않은 래퍼 싱크다.
    expect(
      result.limitations.single,
      startsWith('http-wrapper-undeclared: 2 '),
    );
  });

  test('retrofit relative bases without a slash stay base anchored', () async {
    final result = await scan({
      'lib/api.dart': """
import 'package:dio/dio.dart';
import 'package:retrofit/retrofit.dart';
@RestApi(baseUrl: 'v2/')
abstract class Relative {
  @GET('/users')
  Future<void> users();
  @Method(HttpMethod.QUERY, '/search')
  Future<void> search();
}
@RestApi(baseUrl: '../up/')
abstract class Climbing {
  @GET('/users')
  Future<void> users();
}
""",
    });
    expect(
      [
        for (final fact in result.facts)
          '${fact['method']} ${fact['channel']} ${fact['pathAnchor']}',
      ],
      ['GET /v2/users base', 'null /v2/search base', 'GET null base'],
    );
  });

  test('chopper absolute bases and direct client calls', () async {
    final result = await scan({
      'lib/api.dart': """
import 'package:chopper/chopper.dart';
const kBase = 'https://api.example.test/v1';
@ChopperApi(baseUrl: kBase)
abstract class Service extends ChopperService {
  @Get(path: 'items/{id}')
  Future<Response<String>> item(@Path('id') String id);
  @Post(path: '/a/../b')
  Future<Response<String>> dots();
}
Future<void> direct(ChopperClient client) =>
    client.get(Uri.parse('/raw'));
""",
    });
    expect(
      [
        for (final fact in result.facts)
          '${fact['method']} ${fact['channel']} ${fact['pathAnchor']}',
      ],
      ['GET /v1/items/{} root', 'POST /v1/b root'],
    );
    expect(result.limitations.single, contains('chopper ChopperClient 1'));
  });

  test('wrapper arguments: enum, static constants, dot shorthand', () async {
    const send = HttpWrapperDeclaration(
      position: 0,
      language: 'dart',
      kind: 'function',
      owner: 'package:app/a.dart',
      name: 'send',
      methodArg: WrapperArgument(index: 0),
      pathArg: WrapperArgument(label: 'path'),
      methodEnum: {'post': 'POST', 'PUT': 'PUT'},
      pathAnchor: 'root',
      service: 'api',
    );
    const sendVerb = HttpWrapperDeclaration(
      position: 1,
      language: 'dart',
      kind: 'function',
      owner: 'package:app/a.dart::Client',
      name: 'call',
      methodArg: WrapperArgument(index: 0),
      pathArg: WrapperArgument(index: 1),
      methodEnum: {'get': 'GET'},
      pathAnchor: 'base',
    );
    final result = await scan(
      {
        'lib/a.dart': """
enum Verb { get, post }
abstract final class Verbs {
  static const PUT = 'ignored';
  static const DELETE = 'DELETE';
}
Future<void> send(Object verb, {String? path}) async {}
class Client {
  Future<void> call(Verb verb, String path) async {}
}
Future<void> a() => send(Verb.post, path: '/a');
Future<void> b() => send(Verbs.PUT, path: '/b');
Future<void> c() => send(Verbs.DELETE, path: '/c');
Future<void> d(Client client) => client.call(.get, '/d');
Future<void> e() => send(Verb.get);
""",
      },
      wrappers: [send, sendVerb],
    );
    expect(templates(result), [
      'POST /a',
      'PUT /b',
      'DELETE /c',
      'GET /d',
      'null null',
    ]);
    expect(result.facts[0]['service'], 'api');
    expect(result.facts[3].containsKey('service'), isFalse);
  });
}
