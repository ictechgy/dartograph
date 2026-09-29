/// isthmus http limitation 스코프의 생산자 쪽 규칙이다(GRAPH-EXCHANGE "http
/// limitation 스코프", `http-limitation-scope` 벡터).
///
/// 생산자는 잘못된 스코프를 내지 않는다 — isthmus가 문서 전체를 입력 오류로
/// 거부하기 때문이다. `routes`는 현재 스코프를 증명할 수 있는 호출 측 한계가
/// 없어 스코프를 내지 않지만, 벡터의 생산자 케이스를 같은 규칙으로 통과해 두
/// 소비자·생산자 해석이 갈라지지 않게 한다.
library;

import 'route_url_rules.dart';

const _pathFields = ['templates', 'templatePrefixes', 'templateSuffixes'];
const _allowedKeys = {'limitationIndex', ..._pathFields, 'methods'};

/// 스코프 항목 하나(`limitationIndex` 생략 가능)를 검증한다.
///
/// 위반 사유 문구를 돌려주며(입력 원문을 담지 않는다) 통과하면 null이다.
String? routeScopeProblem(Map<String, Object?> entry) {
  if (entry.containsKey('channels')) {
    return 'http limitation scopes use path fields instead of channels';
  }
  if (entry.keys.any((key) => !_allowedKeys.contains(key))) {
    return 'http limitation scopes accept only limitationIndex, path fields '
        'and methods';
  }
  if (!_pathFields.any(entry.containsKey)) {
    return 'http limitation scopes require a path field';
  }
  for (final field in _pathFields) {
    final problem = _pathFieldProblem(field, entry[field]);
    if (problem != null) return problem;
  }
  return _methodsProblem(entry['methods']);
}

String? _pathFieldProblem(String field, Object? value) {
  if (value == null) return null;
  if (value is! List || value.isEmpty) {
    return '$field must be a non-empty array';
  }
  for (final element in value) {
    if (element is! String) return '$field must contain path template strings';
    if (validateRouteTemplate(element) != null) {
      return '$field contains a non-canonical template';
    }
    if (field == 'templates') continue;
    if (element.split('/').contains('{**}')) {
      return '$field must not contain {**}';
    }
    if (field == 'templatePrefixes' &&
        element != '/' &&
        element.endsWith('/')) {
      return 'templatePrefixes must not end with / except the root prefix';
    }
    if (field == 'templateSuffixes' && element == '/') {
      return 'templateSuffixes must not be /';
    }
  }
  return null;
}

String? _methodsProblem(Object? value) {
  if (value == null) return null;
  final valid =
      value is List &&
      value.isNotEmpty &&
      value.every((m) => m is String && routeCallVerbs.contains(m)) &&
      value.toSet().length == value.length;
  return valid
      ? null
      : 'methods must be a non-empty array of distinct HTTP methods';
}

/// 경로 형태 스코프 하나다.
final class RouteLimitationScope {
  /// 필드를 받는다. 빈 목록은 생략한 필드다.
  const RouteLimitationScope({
    this.templates = const [],
    this.templatePrefixes = const [],
    this.templateSuffixes = const [],
    this.methods = const [],
  });

  /// 정확한 정규 템플릿이다.
  final List<String> templates;

  /// 세그먼트 경계 root 접두사다.
  final List<String> templatePrefixes;

  /// 알 수 없는 앞부분 뒤의 세그먼트 경계 접미사다.
  final List<String> templateSuffixes;

  /// 적용 동사다. 비면 모든 동사다.
  final List<String> methods;
}

/// 스코프가 사실 하나에 적용되는지(두 경로 집합이 겹칠 수 있는지)다.
///
/// 겹친다고 잘못 보면 error 하나가 `-unverified`로 내려갈 뿐이지만, 반대면
/// 거짓 error가 되므로 넓게 근사한다. [method]는 호출 동사(동적이면 null)나
/// 선언 method(`ANY` 가능)이고, [anchor]가 `base`면 알 수 없는 앞부분 뒤의
/// 템플릿이다. [declaration]이면 선언 측 `methods` 해석을 쓴다.
bool routeScopeApplies(
  RouteLimitationScope scope,
  String template,
  String? method,
  String anchor, {
  bool declaration = false,
}) {
  if (!_methodApplies(scope.methods.toSet(), method, declaration)) return false;
  final trimmed = _trimTrailingEmpty(_tokens(template));
  final base = [if (anchor == 'base') const _Star(), ...trimmed];
  final variants = base.isNotEmpty && base.last is _Star
      ? [base]
      : [
          base,
          [...base, const _Literal('')],
        ];
  final elements = [
    for (final t in scope.templates) _trimTrailingEmpty(_tokens(t)),
    for (final t in scope.templatePrefixes)
      [..._trimTrailingEmpty(_tokens(t)), const _Star()],
    for (final t in scope.templateSuffixes)
      [const _Star(), ..._trimTrailingEmpty(_tokens(t))],
  ];
  return elements.any(
    (element) => variants.any((variant) => _overlaps(element, variant)),
  );
}

/// method 조건이다(조인의 head-as-get·options-any와 같은 방향).
bool _methodApplies(Set<String> methods, String? method, bool declaration) {
  if (methods.isEmpty ||
      method == null ||
      method == 'ANY' ||
      methods.contains(method)) {
    return true;
  }
  if (declaration) {
    return methods.contains('OPTIONS') ||
        (method == 'GET' && methods.contains('HEAD'));
  }
  return method == 'OPTIONS' || (method == 'HEAD' && methods.contains('GET'));
}

/// 비교 토큰이다.
sealed class _Token {
  const _Token();
}

/// ASCII 소문자로 접은 리터럴 세그먼트다.
final class _Literal extends _Token {
  const _Literal(this.value);
  final String value;
}

/// 부분 세그먼트 `p{}s`다.
final class _Partial extends _Token {
  const _Partial(this.prefix, this.suffix);
  final String prefix;
  final String suffix;
}

/// 빈 값을 포함한 세그먼트 하나다.
final class _AnyValue extends _Token {
  const _AnyValue();
}

/// 0개 이상 세그먼트다.
final class _Star extends _Token {
  const _Star();
}

List<_Token> _tokens(String template) => [
  for (final segment in template.substring(1).split('/'))
    if (segment == '{**}')
      const _Star()
    else if (segment == '{}')
      const _AnyValue()
    else if (segment.contains('{}'))
      _Partial(
        _fold(segment.substring(0, segment.indexOf('{}'))),
        _fold(segment.substring(segment.indexOf('{}') + 2)),
      )
    else
      _Literal(_fold(segment)),
];

String _fold(String value) => value.replaceAllMapped(
  RegExp('[A-Z]'),
  (match) => match.group(0)!.toLowerCase(),
);

/// 끝의 빈 리터럴 세그먼트 하나를 뗀다(끝 슬래시 무관 비교).
List<_Token> _trimTrailingEmpty(List<_Token> tokens) {
  final last = tokens.isEmpty ? null : tokens.last;
  return last is _Literal && last.value.isEmpty
      ? tokens.sublist(0, tokens.length - 1)
      : tokens;
}

/// 두 토큰열이 같은 구체 경로를 하나라도 가질 수 있는지다. 뒤에서부터 채우는
/// 표로 계산한다(칸 수는 두 길이의 곱 이하).
bool _overlaps(List<_Token> left, List<_Token> right) {
  final table = List.generate(
    left.length + 1,
    (_) => List.filled(right.length + 1, false),
  );
  for (var i = left.length; i >= 0; i--) {
    for (var j = right.length; j >= 0; j--) {
      table[i][j] = _cell(left, right, table, i, j);
    }
  }
  return table[0][0];
}

bool _cell(
  List<_Token> left,
  List<_Token> right,
  List<List<bool>> table,
  int i,
  int j,
) {
  if (i < left.length && left[i] is _Star) {
    return table[i + 1][j] || (j < right.length && table[i][j + 1]);
  }
  if (j < right.length && right[j] is _Star) {
    return table[i][j + 1] || (i < left.length && table[i + 1][j]);
  }
  if (i == left.length || j == right.length) {
    return i == left.length && j == right.length;
  }
  return _segmentsOverlap(left[i], right[j]) && table[i + 1][j + 1];
}

/// 세그먼트 토큰 둘이 같은 값을 가질 수 있는지다. 부분 세그먼트끼리는 항상
/// 겹친다고 본다.
bool _segmentsOverlap(_Token left, _Token right) => switch ((left, right)) {
  (_AnyValue(), _) || (_, _AnyValue()) => true,
  (_Literal(:final value), _Literal(value: final other)) => value == other,
  (_Literal(:final value), final _Partial partial) => _accepts(partial, value),
  (final _Partial partial, _Literal(:final value)) => _accepts(partial, value),
  _ => true,
};

bool _accepts(_Partial partial, String value) =>
    value.length >= partial.prefix.length + partial.suffix.length &&
    value.startsWith(partial.prefix) &&
    value.endsWith(partial.suffix);
