import 'package:dartograph/src/index/http_wrappers.dart';
import 'package:dartograph/src/index/route_limitation_scopes.dart';
import 'package:dartograph/src/index/route_url_rules.dart';
import 'package:test/test.dart';

/// 벡터가 다루지 않는 조립 경계다. 기대값은 dio 5.11.1·Dart SDK `Uri` 실행
/// 결과와 계약 문장에서 손으로 적었다.
void main() {
  ComposedRoute compose(List<UrlPart> parts, UrlJoin join) =>
      composeRoute(parts, join);

  group('dio join', () {
    test('an absolute path ignores the base and removes dot segments', () {
      final route = compose([
        const LiteralUrlPart('https://Other.example.test/a/../b'),
      ], DioJoin(DioBase.parseLiteral('https://api.example.test/v1')));
      expect(route.template, '/b');
      expect(route.authority, 'other.example.test');
    });

    test('a leading value followed by a rooted literal is a base anchor', () {
      final route = compose(const [
        ValueUrlPart(),
        LiteralUrlPart('/users//list'),
      ], const DioJoin(null));
      expect((route.template, route.pathAnchor), ('/users/list', 'base'));
    });

    test('a leading value followed by a relative literal is ambiguous', () {
      final route = compose(const [
        ValueUrlPart(),
        LiteralUrlPart('users'),
      ], const DioJoin(null));
      expect(route.dynamic, isTrue);
      expect(route.limitation, ambiguousBaseJoinPrefix);
    });

    test('an unknown base with a leading // path is ambiguous', () {
      final route = compose([const LiteralUrlPart('//x')], const DioJoin(null));
      expect(route.limitation, ambiguousBaseJoinPrefix);
    });

    test('a leading value after a literal base is not a root segment', () {
      final base = DioJoin(
        DioBase.parseLiteral('https://api.example.test/v1/'),
      );
      final whole = compose(const [ValueUrlPart()], base);
      expect(whole.dynamic, isTrue);
      expect(whole.limitation, isNull);
      final tail = compose(const [ValueUrlPart(), LiteralUrlPart('/x')], base);
      expect(
        (tail.template, tail.pathAnchor, tail.authority),
        ('/x', 'base', null),
      );
    });

    test('a whole-path value is dynamic without an ambiguous join', () {
      final route = compose(const [ValueUrlPart()], const DioJoin(null));
      expect(route.dynamic, isTrue);
      expect(route.limitation, isNull);
    });

    test('a path with :/ keeps double slashes (dio does not collapse)', () {
      final route = compose([
        const LiteralUrlPart('/a:/b//c'),
      ], DioJoin(DioBase.parseLiteral('https://api.example.test')));
      expect(route.template, '/a:/b//c');
    });

    test('.. above an unknown base is dynamic', () {
      final route = compose([
        const LiteralUrlPart('/../x'),
      ], const DioJoin(null));
      expect(route.dynamic, isTrue);
      expect(route.pathAnchor, 'base');
    });

    test('a relative base path keeps the base anchor', () {
      final route = compose([
        const LiteralUrlPart('/users'),
      ], const DioJoin(DioBase(path: '/v2/', anchor: 'base')));
      expect((route.template, route.pathAnchor), ('/v2/users', 'base'));
    });

    test('literal bases without an http host are not claimed', () {
      expect(DioBase.parseLiteral('/api'), isNull);
      expect(DioBase.parseLiteral('https:///x'), isNull);
      expect(
        DioBase.parseLiteral('https://u:p@H.test:8080/v1')?.authority,
        'h.test:8080',
      );
    });
  });

  group('uri string join', () {
    test('a dynamic host keeps the path after it as a base anchor', () {
      final route = compose(const [
        LiteralUrlPart('https://api.'),
        ValueUrlPart(),
        LiteralUrlPart('.example.test/v1/items'),
      ], const UriStringJoin());
      expect((route.template, route.pathAnchor), ('/v1/items', 'base'));
      expect(route.authority, isNull);
    });

    test('a host without a path is the root template', () {
      final route = compose(const [
        LiteralUrlPart('https://'),
        ValueUrlPart(),
      ], const UriStringJoin());
      expect((route.template, route.pathAnchor), ('/', 'base'));
    });

    test('a scheme value before // uses the authority rule', () {
      final route = compose(const [
        ValueUrlPart(),
        LiteralUrlPart('//user@api.example.test/x'),
      ], const UriStringJoin());
      expect((route.template, route.authority), ('/x', 'api.example.test'));
    });

    test('a leading value before a relative literal is ambiguous', () {
      final route = compose(const [
        ValueUrlPart(),
        LiteralUrlPart('items'),
      ], const UriStringJoin());
      expect(route.limitation, ambiguousBaseJoinPrefix);
    });

    test('an invalid authority is dropped but the path is kept', () {
      final route = compose([
        const LiteralUrlPart('https://bad_host!/x'),
      ], const UriStringJoin());
      expect((route.template, route.authority), ('/x', null));
    });

    test('a dynamic prefix ending in dots is not proven', () {
      final route = compose(const [
        LiteralUrlPart('https://h.test/a/..'),
        ValueUrlPart(),
      ], const UriStringJoin());
      expect(route.dynamic, isTrue);
      expect(route.channelPrefix, isNull);
    });

    test('a dynamic prefix resolves complete dot segments', () {
      final route = compose(const [
        LiteralUrlPart('https://h.test/a/../b/x'),
        ValueUrlPart(),
      ], const UriStringJoin());
      expect(route.channelPrefix, '/b/x');
    });
  });

  test('declared and slash joins place the anchor', () {
    expect(
      compose(const [
        ValueUrlPart(),
        LiteralUrlPart('/x'),
      ], const DeclaredJoin('root')).pathAnchor,
      'base',
    );
    expect(
      compose(const [
        ValueUrlPart(),
        LiteralUrlPart('x'),
      ], const SlashJoin()).template,
      '/x',
    );
    expect(
      compose(const [LiteralUrlPart('x')], const DeclaredJoin('root')).template,
      '/x',
    );
    expect(compose(const [], const PathOnlyJoin()).dynamic, isTrue);
  });

  test('uri path join is root and removes dot segments', () {
    final route = compose([
      const LiteralUrlPart('/a/../b'),
    ], const UriPathJoin());
    expect((route.template, route.pathAnchor), ('/b', 'root'));
    expect(
      compose(const [
        ValueUrlPart(),
        LiteralUrlPart('/x'),
      ], const UriPathJoin()).dynamic,
      isTrue,
    );
  });

  test('templates that break the grammar after joining are dynamic', () {
    final route = compose([
      LiteralUrlPart('/${'a' * 2100}'),
    ], const PathOnlyJoin());
    expect(route.dynamic, isTrue);
  });

  test('unencoded paths encode percent, query and fragment characters', () {
    expect(encodeUnencodedPath('/a%2fb?c#d é'), '/a%252fb%3Fc%23d%20%C3%A9');
  });

  test('scope validation rejects malformed shapes', () {
    expect(routeScopeProblem({'templates': 'x'}), isNotNull);
    expect(
      routeScopeProblem({
        'templates': [1],
      }),
      isNotNull,
    );
    expect(
      routeScopeProblem({
        'templateSuffixes': ['/{**}'],
      }),
      isNotNull,
    );
    expect(
      routeScopeProblem({
        'templates': ['/a'],
        'methods': ['GET', 'GET'],
      }),
      isNotNull,
    );
    expect(
      routeScopeApplies(
        const RouteLimitationScope(templates: ['/files/{}.json']),
        '/files/report.json',
        'GET',
        'root',
      ),
      isTrue,
    );
    expect(
      routeScopeApplies(
        const RouteLimitationScope(templates: ['/files/{}.json']),
        '/files/report.txt',
        'GET',
        'root',
      ),
      isFalse,
    );
    expect(
      routeScopeApplies(
        const RouteLimitationScope(templates: ['/a/b{}']),
        '/a/{}x',
        'GET',
        'root',
      ),
      isTrue,
    );
  });

  group('http-wrappers parsing', () {
    String document(String wrapper) =>
        '{"format":"http-wrappers","version":1,"wrappers":[$wrapper]}';
    const valid =
        '"language":"dart","kind":"function","owner":"package:a/b.dart",'
        '"name":"send","pathArg":{"index":0},"pathAnchor":"root"';

    test('a complete dart declaration is read', () {
      final declaration = parseHttpWrappers(
        document(
          '{$valid,"methodArg":{"label":"method","index":1},'
          '"methodEnum":{"get":"GET"},"service":"api"}',
        ),
      ).single;
      expect(declaration.methodArg?.label, 'method');
      expect(declaration.methodEnum, {'get': 'GET'});
      expect(declaration.service, 'api');
    });

    test('contract violations are declaration errors', () {
      final invalid = [
        'not json',
        '[]',
        '{"format":"http-wrappers","version":2,"wrappers":[]}',
        '{"format":"x","version":1,"wrappers":[]}',
        '{"format":"http-wrappers","version":1,"wrappers":{}}',
        '{"format":"http-wrappers","version":1,"wrappers":[],"extra":1}',
        document('1'),
        document('{$valid}'),
        document('{$valid,"defaultMethod":"get"}'),
        document('{$valid,"defaultMethod":"GET","unknown":1}'),
        document(
          '{"language":"dart","kind":"constructor","owner":"package:a/b.dart",'
          '"name":"new","pathArg":{"index":0},"defaultMethod":"GET",'
          '"pathAnchor":"root"}',
        ),
        document(
          '{"language":"dart","kind":"function","owner":"package:a/b.dart",'
          '"name":"a-b","pathArg":{"index":0},"defaultMethod":"GET",'
          '"pathAnchor":"root"}',
        ),
        document('{$valid,"defaultMethod":"GET","pathArg":{"index":-1}}'),
        document('{$valid,"defaultMethod":"GET","pathArg":{}}'),
        document('{$valid,"defaultMethod":"GET","pathArg":1}'),
        document('{$valid,"defaultMethod":"GET","methodEnum":{"x":"ANY"}}'),
        document('{$valid,"defaultMethod":"GET","methodEnum":[]}'),
        document(
          '{"language":"dart","kind":"function","owner":"package:a/b.dart",'
          '"name":"send","defaultMethod":"GET","pathAnchor":"root"}',
        ),
        document('{$valid,"defaultMethod":"GET","service":""}'),
      ];
      for (final content in invalid) {
        expect(
          () => parseHttpWrappers(content),
          throwsA(isA<HttpWrappersFormatException>()),
          reason: content,
        );
      }
    });

    test('other languages are validated but not shaped like dart', () {
      final declaration = parseHttpWrappers(
        document(
          '{"language":"kotlin","kind":"constructor","owner":"com.example.Api",'
          '"name":"<init>","pathArg":{"label":"path"},"defaultMethod":"GET",'
          '"pathAnchor":"base"}',
        ),
      ).single;
      expect(declaration.language, 'kotlin');
      expect(HttpWrappersFormatException('m').toString(), 'm');
    });
  });
}
