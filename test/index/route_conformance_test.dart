import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartograph/src/index/http_wrappers.dart';
import 'package:dartograph/src/index/route_limitation_scopes.dart';
import 'package:dartograph/src/index/route_url_rules.dart';
import 'package:test/test.dart';

import 'route_location_probe.dart';

/// isthmus 공유 적합성 벡터(`http-template`·`url-compose`·
/// `http-limitation-scope`)의 생산자 케이스를 dartograph 규칙으로 실행한다.
/// `http-dispatch`는 lock으로 대조만 하고 생산자 케이스(`dispatch.validate`)는
/// 적용하지 않는다 — 아래 테스트가 그 분류를 고정한다.
///
/// 벤더링한 파일의 sha256을 `conformance.lock`과 먼저 대조한다. 생산자 케이스의
/// 규칙 식별자를 모르면 건너뛰지 않고 실패한다 — 새 규칙이 조용히 미검증으로
/// 남지 않게 하기 위해서다. `producer:<다른 생산자>` 케이스(Spring·OpenAPI 서버
/// 변환)는 dartograph에 적용되지 않는다.
void main() {
  const directory = 'fixtures/isthmus_conformance';

  Map<String, Object?> document(String name) =>
      jsonDecode(File('$directory/$name').readAsStringSync())
          as Map<String, Object?>;

  List<Map<String, Object?>> producerCases(String name) {
    final suite = document(name);
    expect(suite['format'], 'isthmus-conformance');
    expect(suite['version'], 1);
    return [
      for (final raw in suite['cases']! as List)
        if ((raw as Map<String, Object?>)['appliesTo']! as List case final to
            when to.contains('producer') || to.contains('producer:dartograph'))
          raw,
    ];
  }

  test('vendored vectors match the lock file', () {
    final lock = document('conformance.lock');
    expect(lock['format'], 'isthmus-conformance-lock');
    final files = lock['files']! as Map<String, Object?>;
    expect(files.keys.toSet(), {
      'http-dispatch.json',
      'http-limitation-scope.json',
      'http-template.json',
      'url-compose.json',
    });
    for (final entry in files.entries) {
      final bytes = File('$directory/${entry.key}').readAsBytesSync();
      expect(
        sha256.convert(bytes).toString(),
        entry.value,
        reason: 'vendored ${entry.key} differs from conformance.lock',
      );
    }
    final commit = (lock['isthmus']! as Map<String, Object?>)['commit'];
    expect(commit, matches(RegExp(r'^[0-9a-f]{40}$')));
  });

  test('http-template producer cases pass', () {
    final cases = producerCases('http-template.json');
    for (final testCase in cases) {
      final id = testCase['id'];
      final input = testCase['input']! as Map<String, Object?>;
      final expected = testCase['expect']! as Map<String, Object?>;
      switch (testCase['ruleId']) {
        case 'template.grammar':
          final reason = validateRouteTemplate(input['template']! as String);
          expect(reason == null, expected['valid'], reason: '$id');
          if (expected.containsKey('reason')) {
            expect(reason, expected['reason'], reason: '$id');
          }
        case 'template.normalize':
          expect(
            normalizeRoutePath(input['path']! as String),
            expected['template'],
            reason: '$id',
          );
        default:
          fail('unknown producer rule ${testCase['ruleId']} in $id');
      }
    }
    expect(cases, hasLength(33));
  });

  test('http-limitation-scope producer cases pass', () {
    final cases = producerCases('http-limitation-scope.json');
    for (final testCase in cases) {
      final id = testCase['id'];
      final input = testCase['input']! as Map<String, Object?>;
      final expected = testCase['expect']! as Map<String, Object?>;
      final entry = input['scope']! as Map<String, Object?>;
      switch (testCase['ruleId']) {
        case 'scope.validate':
          expect(
            routeScopeProblem(entry) == null,
            expected['valid'],
            reason: '$id',
          );
        case 'scope.applies':
          expect(routeScopeProblem(entry), isNull, reason: '$id scope valid');
          final probe = input['probe']! as Map<String, Object?>;
          final applies = routeScopeApplies(
            _scopeOf(entry),
            probe['template']! as String,
            probe['method'] as String?,
            probe['pathAnchor']! as String,
            declaration: probe['side'] == 'declaration',
          );
          expect(applies, expected['applies'], reason: '$id');
        default:
          fail('unknown producer rule ${testCase['ruleId']} in $id');
      }
    }
    expect(cases, hasLength(27));
  });

  // dartograph는 클라이언트 route-call만 내고 route-decl의 `order`를 내지 않는다.
  // `dispatch.validate`는 registration-order 문서의 `order`를 검증하는 규칙이라
  // 검증할 생산 출력이 없으므로 적용하지 않는다. 다른 생산자 규칙이 더해지면
  // 조용히 미검증으로 남지 않게 실패한다.
  test('http-dispatch producer cases are classified as not applicable', () {
    final cases = producerCases('http-dispatch.json');
    for (final testCase in cases) {
      if (testCase['ruleId'] != 'dispatch.validate') {
        fail(
          'unknown producer rule ${testCase['ruleId']} in ${testCase['id']}',
        );
      }
    }
    expect(cases, hasLength(18));
  });

  test('url-compose producer cases pass', () async {
    final cases = producerCases('url-compose.json');
    for (final testCase in cases) {
      final id = '${testCase['id']}';
      final input = testCase['input']! as Map<String, Object?>;
      final expected =
          (testCase['expect'] as Map<String, Object?>?) ??
          const <String, Object?>{};
      final dynamicExpected = testCase['expectDynamic'] == true;
      switch (testCase['ruleId']) {
        case 'compose.interpolation' ||
            'compose.query-tail' ||
            'compose.suffix' ||
            'compose.normalize':
          _checkComposed(
            id,
            composeRoute(_parts(input['parts']! as List), const PathOnlyJoin()),
            expected,
            dynamicExpected,
            testCase,
          );
        case 'compose.base-join':
          final composed = composeRoute([
            LiteralUrlPart(input['path']! as String),
          ], _join(input));
          _checkComposed(id, composed, expected, dynamicExpected, testCase);
        case 'compose.strip':
          _checkComposed(
            id,
            composeRoute([
              LiteralUrlPart(input['url']! as String),
            ], const PathOnlyJoin()),
            expected,
            dynamicExpected,
            testCase,
          );
        case 'compose.mask':
          final (template, count) = maskRouteTemplate(
            input['template']! as String,
            input['authority'] as String?,
          );
          expect(template, expected['template'], reason: id);
          expect(count, expected['maskedSegments'], reason: id);
        case 'wrapper.method':
          _checkMethod(id, input, expected, dynamicExpected);
        case 'wrapper.location':
          final line = await probeWrapperCallLine(
            callStartLine: input['callStartLine']! as int,
            methodArgumentLine: input['methodArgLine']! as int,
            pathArgumentLine: input['pathArgLine']! as int,
          );
          expect(line, expected['line'], reason: id);
        default:
          fail('unknown producer rule ${testCase['ruleId']} in $id');
      }
    }
    expect(cases, hasLength(41));
  });
}

RouteLimitationScope _scopeOf(Map<String, Object?> entry) {
  List<String> strings(String key) => [
    for (final value in (entry[key] as List?) ?? const []) value as String,
  ];
  return RouteLimitationScope(
    templates: strings('templates'),
    templatePrefixes: strings('templatePrefixes'),
    templateSuffixes: strings('templateSuffixes'),
    methods: strings('methods'),
  );
}

/// 적힌 키만 비교한다(계약의 벡터 비교 규칙).
void _checkComposed(
  String id,
  ComposedRoute composed,
  Map<String, Object?> expected,
  bool dynamicExpected,
  Map<String, Object?> testCase,
) {
  expect(composed.dynamic, dynamicExpected, reason: '$id dynamic');
  final actual = <String, Object?>{
    'template': composed.template,
    'channelPrefix': composed.channelPrefix,
    'queryTailStripped': composed.queryTailStripped,
    'pathAnchor': composed.pathAnchor,
    'authority': composed.authority,
  };
  for (final key in expected.keys) {
    expect(actual[key], expected[key], reason: '$id $key');
  }
  final limitation = testCase['expectLimitation'];
  if (limitation != null) {
    expect(composed.limitation, limitation, reason: '$id limitation');
  }
}

List<UrlPart> _parts(List<Object?> values) => [
  for (final raw in values)
    switch (raw! as Map<String, Object?>) {
      {'literal': final String text} => LiteralUrlPart(text),
      {'value': String()} => const ValueUrlPart(),
      {'queryTail': String()} => const QueryTailUrlPart(),
      final other => throw StateError('unknown part shape $other'),
    },
];

UrlJoin _join(Map<String, Object?> input) => switch (input['join']) {
  'rfc3986' => const Rfc3986Join(),
  'slash-join' => const SlashJoin(),
  'dio-concat' => DioJoin(
    input['base'] == null
        ? null
        : DioBase.parseLiteral(input['base']! as String),
  ),
  final other => throw StateError('unknown join $other'),
};

void _checkMethod(
  String id,
  Map<String, Object?> input,
  Map<String, Object?> expected,
  bool dynamicExpected,
) {
  final declaration = input['declaration']! as Map<String, Object?>;
  final call = input['call']! as Map<String, Object?>;
  final arguments = <WrapperCallArgument>[
    for (final raw in call['args']! as List)
      (
        label: (raw as Map<String, Object?>)['label'] as String?,
        value: switch (raw['value']! as Map<String, Object?>) {
          {'literal': final String text} => LiteralArgumentValue(text),
          {'enumCase': final String name} => EnumCaseArgumentValue(name),
          _ => const OpaqueArgumentValue(),
        },
      ),
  ];
  final spec = declaration['methodArg'] as Map<String, Object?>?;
  final method = bindWrapperMethod(
    spec == null
        ? null
        : WrapperArgument(
            index: spec['index'] as int?,
            label: spec['label'] as String?,
          ),
    declaration['defaultMethod'] as String?,
    {
      for (final entry
          in ((declaration['methodEnum'] as Map<String, Object?>?) ??
                  const <String, Object?>{})
              .entries)
        entry.key: entry.value! as String,
    },
    arguments,
  );
  expect(method, dynamicExpected ? isNull : expected['method'], reason: id);
}
