/// isthmus http 도메인의 호출 측 조립 규칙(`url-compose`)과 정규 경로 템플릿
/// 문법(`http-template`)이다.
///
/// analyzer와 분리한 순수 규칙이라 공유 적합성 벡터를 그대로 실행해 검증한다.
/// 규칙이 벡터와 다르면 벡터가 정본이다(isthmus `docs/HTTP-WRAPPERS.md`).
/// 모든 호출 측 생산자(cartograph·kartograph·dartograph)가 같은 규칙을 써야
/// 같은 API를 부르는 iOS·Android·Flutter 호출이 같은 키로 조인된다.
library;

import 'dart:convert';

/// 계약의 route-call 동사 집합이다. `ANY`는 route-decl 전용이라 없다.
const routeCallVerbs = {
  'GET',
  'HEAD',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'OPTIONS',
  'TRACE',
};

/// 정규 템플릿과 dynamic 원문의 길이 상한이다.
const maxRouteTemplateLength = 2048;

/// 경로 식을 이루는 조각이다. 소스 해석기가 리터럴·보간·증명된 query 꼬리로
/// 나눠 넘긴다.
sealed class UrlPart {
  const UrlPart();
}

/// 값이 확정된 문자열 조각이다(상수 치환 결과 포함).
final class LiteralUrlPart extends UrlPart {
  /// [text] 조각을 만든다.
  const LiteralUrlPart(this.text);

  /// 디코드된 문자열 값이다.
  final String text;
}

/// 값을 모르는 보간·연결 조각이다.
final class ValueUrlPart extends UrlPart {
  /// 값 조각을 만든다. 원문은 출력에 싣지 않으므로 보관하지 않는다.
  const ValueUrlPart({this.fromParameter = false});

  /// 감싸는 함수의 매개변수(또는 그 속성)에서 온 값인지다.
  final bool fromParameter;
}

/// 초기식이 `?`로 시작하거나 빈 값임을 증명한 지역 변수 보간이다
/// (`compose.suffix`).
final class QueryTailUrlPart extends UrlPart {
  /// query 꼬리 조각을 만든다.
  const QueryTailUrlPart();
}

/// base와 경로를 잇는 방식이다(`compose.base-join`).
sealed class UrlJoin {
  const UrlJoin();
}

/// 조각 전체가 경로다. 앞의 미해석 보간은 dynamic이다(보간 규칙만 적용할 때).
final class PathOnlyJoin extends UrlJoin {
  /// 경로 전용 결합을 만든다.
  const PathOnlyJoin();
}

/// `http-wrappers` 선언의 `pathAnchor`를 따르는 결합이다. 앞의 미해석 보간은
/// 단순 연결 base로 본다.
final class DeclaredJoin extends UrlJoin {
  /// 선언된 [anchor](`root`·`base`)로 결합을 만든다.
  const DeclaredJoin(this.anchor);

  /// 선언의 `pathAnchor`다.
  final String anchor;
}

/// RFC 3986 상대 해석이다. `/x`는 root, `x`는 base다.
final class Rfc3986Join extends UrlJoin {
  /// RFC 3986 결합을 만든다.
  const Rfc3986Join();
}

/// 슬래시 결합(chopper 런타임의 base 병합 등)이다. 항상 base다.
final class SlashJoin extends UrlJoin {
  /// 슬래시 결합을 만든다.
  const SlashJoin();
}

/// `Uri.parse`로 읽는 전체 URL 문자열이다(package:http).
///
/// scheme이 있으면 host 뒤 경로를 root로, 앞 보간(미상 base 식) 뒤에 `/`가
/// 오면 base로 본다. 점 세그먼트는 `Uri.parse`처럼 지운다.
final class UriStringJoin extends UrlJoin {
  /// 전체 URL 문자열 결합을 만든다.
  const UriStringJoin();
}

/// `Uri.https`·`Uri.http`의 경로 인자다. root이고 점 세그먼트를 지우며, 앞
/// 보간은 경로가 아니므로 dynamic이다.
final class UriPathJoin extends UrlJoin {
  /// 경로 인자 결합을 만든다.
  const UriPathJoin();
}

/// dio `RequestOptions.uri`의 단순 문자열 연결이다(dio 5.11.1 소스 확인).
///
/// `path`가 `http:`·`https:`로 시작하지 않으면 `baseUrl + path`를 만들고,
/// 결과에 `:/`가 정확히 하나면 그 뒤의 `//`를 `/`로 바꾼 다음
/// `Uri.parse(url).normalizePath()`로 점 세그먼트를 지운다.
final class DioJoin extends UrlJoin {
  /// [base]로 결합을 만든다. null이면 미상 base다.
  const DioJoin(this.base);

  /// 경로 앞에 붙는 base다.
  final DioBase? base;
}

/// dio 연결에 쓰는 base다. 알려진 경로 부분과 앵커를 담는다.
final class DioBase {
  /// 필드를 직접 받는다. [path]는 `/`로 시작한다.
  const DioBase({required this.path, required this.anchor, this.authority});

  /// `https://host/v1` 같은 리터럴 base URL을 읽는다.
  ///
  /// http(s) scheme이 없거나 host가 비었으면 null이다 — dio는 상대 base로
  /// 요청을 보낼 수 없어 결과를 주장하지 않는다.
  static DioBase? parseLiteral(String url) {
    final match = RegExp(r'^https?://([^/?#]*)([^?#]*)').firstMatch(url);
    if (match == null || match.group(1)!.isEmpty) return null;
    final rawAuthority = match.group(1)!.split('@').last.toLowerCase();
    return DioBase(
      path: match.group(2)!,
      anchor: 'root',
      authority: _authorityPattern.hasMatch(rawAuthority) ? rawAuthority : null,
    );
  }

  /// base의 host 뒤 경로다. 비어 있을 수 있다.
  final String path;

  /// base 경로가 서버 루트부터 확정됐는지(`root`) 미상 접두사 뒤인지(`base`)다.
  final String anchor;

  /// 리터럴 base의 소문자 `host[:port]`다.
  final String? authority;
}

/// 조립 결과다.
final class ComposedRoute {
  /// 결과 필드를 받는다.
  const ComposedRoute({
    required this.template,
    required this.dynamic,
    this.channelPrefix,
    this.pathAnchor,
    this.authority,
    this.queryTailStripped = false,
    this.maskedSegments = 0,
    this.limitation,
  });

  /// dynamic 결과를 만든다.
  const ComposedRoute.dynamicRoute({
    this.channelPrefix,
    this.pathAnchor,
    this.authority,
    this.limitation,
  }) : template = null,
       dynamic = true,
       queryTailStripped = false,
       maskedSegments = 0;

  /// dynamic이 아니면 정규 경로 템플릿이다.
  final String? template;

  /// 템플릿을 증명하지 못했다는 표시다.
  final bool dynamic;

  /// dynamic일 때 증명된 리터럴 접두사 템플릿이다(마스킹 적용).
  final String? channelPrefix;

  /// `root` 또는 `base`. dynamic이면 조립 중 확정된 값이거나 null이다.
  final String? pathAnchor;

  /// 전체 URL 리터럴에서 뗀 소문자 `host[:port]`다.
  final String? authority;

  /// query·fragment 꼬리를 떼어 냈다는 증거다.
  final bool queryTailStripped;

  /// `{}`로 가린 리터럴 세그먼트 수다.
  final int maskedSegments;

  /// 이 호출이 만든 호출 측 limitation 접두사다(`ambiguous-base-join:`).
  final String? limitation;
}

/// base 결합으로 앵커·authority와 `/`로 시작하는 경로 조각을 정한 중간 결과다.
final class _Located {
  const _Located(this.parts, this.anchor, this.authority, {this.dots = false});

  final List<UrlPart> parts;
  final String anchor;
  final String? authority;

  /// 점 세그먼트를 지우는 클라이언트인지다.
  final bool dots;
}

/// 모호한 base 결합 limitation 접두사다.
const ambiguousBaseJoinPrefix = 'ambiguous-base-join:';

/// 경로 조각을 정규 템플릿으로 조립한다.
///
/// 순서는 base 결합 → query·fragment 꼬리 → suffix 꼬리 → 세그먼트 보간 →
/// 정규화 → 점 세그먼트 → 마스킹이다. 증명하지 못한 단계는 결과를 dynamic으로
/// 내리고 그 앞까지의 템플릿을 channelPrefix로 남긴다.
ComposedRoute composeRoute(List<UrlPart> parts, UrlJoin join) {
  final merged = mergeUrlLiterals(parts);
  if (merged.isEmpty) return const ComposedRoute.dynamicRoute();
  final located = _locate(merged, join);
  if (located == null) {
    return ComposedRoute.dynamicRoute(
      limitation: _ambiguousJoin(merged, join) ? ambiguousBaseJoinPrefix : null,
    );
  }
  return _assemble(located);
}

/// 연속한 리터럴을 합치고 빈 리터럴을 버린다.
List<UrlPart> mergeUrlLiterals(List<UrlPart> parts) {
  final result = <UrlPart>[];
  for (final part in parts) {
    final last = result.isEmpty ? null : result.last;
    if (part is LiteralUrlPart && last is LiteralUrlPart) {
      result[result.length - 1] = LiteralUrlPart(last.text + part.text);
    } else if (!(part is LiteralUrlPart && part.text.isEmpty)) {
      result.add(part);
    }
  }
  return result;
}

/// base 결합을 적용한다. null은 증명할 수 없는 결합(dynamic)이다.
_Located? _locate(List<UrlPart> parts, UrlJoin join) {
  if (join is DioJoin) return _locateDio(parts, join.base);
  final first = parts.first;
  final dots = join is UriStringJoin || join is UriPathJoin;
  if (first is LiteralUrlPart && _hasScheme(first.text)) {
    return _locateAbsolute(parts, dots: dots);
  }
  if (first is LiteralUrlPart && first.text.startsWith('//')) {
    return _locateAbsolute(parts, dots: dots);
  }
  final second = parts.length > 1 ? parts[1] : null;
  if (first is! LiteralUrlPart &&
      second is LiteralUrlPart &&
      second.text.startsWith('//')) {
    return _locateAbsolute(parts.sublist(1), dots: dots);
  }
  if (first is! LiteralUrlPart) {
    return _locateAfterBase(parts.sublist(1), join);
  }
  final anchor = _literalAnchor(first.text.startsWith('/'), join);
  return _Located(_rootedParts(parts), anchor, null, dots: dots);
}

/// 첫 조각이 리터럴일 때 결합 방식이 정하는 앵커다.
String _literalAnchor(bool rooted, UrlJoin join) {
  if (join is DeclaredJoin) return join.anchor;
  if (join is Rfc3986Join) return rooted ? 'root' : 'base';
  return join is SlashJoin ? 'base' : 'root';
}

/// 앞의 미해석 base 식 뒤를 단순 연결로 본다 — `/`로 시작하면 base다.
_Located? _locateAfterBase(List<UrlPart> rest, UrlJoin join) {
  if (join is PathOnlyJoin || join is Rfc3986Join || join is UriPathJoin) {
    return null;
  }
  final next = rest.isEmpty ? null : rest.first;
  if (next is! LiteralUrlPart) return null;
  if (join is SlashJoin) return _Located(_rootedParts(rest), 'base', null);
  if (!next.text.startsWith('/')) return null;
  return _Located(rest, 'base', null, dots: join is UriStringJoin);
}

/// 첫 조각이 `/`로 시작하지 않으면 `/`를 붙여 템플릿 문법의 루트를 맞춘다.
List<UrlPart> _rootedParts(List<UrlPart> parts) {
  final first = parts.first as LiteralUrlPart;
  if (first.text.startsWith('/')) return parts;
  return [LiteralUrlPart('/${first.text}'), ...parts.skip(1)];
}

/// 전체 URL 리터럴(`scheme://…`)이나 network-path 참조(`//…`)에서 scheme·
/// userinfo를 떼고 host를 authority로 옮긴다(`compose.strip`).
_Located _locateAbsolute(List<UrlPart> parts, {required bool dots}) {
  final literal = (parts.first as LiteralUrlPart).text;
  final afterScheme = literal.startsWith('//')
      ? literal.substring(2)
      : literal.substring(literal.indexOf('://') + 3);
  final end = afterScheme.indexOf(RegExp(r'[/?#]'));
  if (end < 0 && parts.length > 1) {
    return _locateAfterDynamicHost(parts.sublist(1), dots: dots);
  }
  final rawAuthority = end < 0 ? afterScheme : afterScheme.substring(0, end);
  final remainder = end < 0 ? '' : afterScheme.substring(end);
  final path = remainder.startsWith('/') ? remainder : '/$remainder';
  final host = rawAuthority.split('@').last.toLowerCase();
  return _Located(
    mergeUrlLiterals([LiteralUrlPart(path), ...parts.skip(1)]),
    'root',
    _authorityPattern.hasMatch(host) ? host : null,
    dots: dots,
  );
}

/// host에 보간이 섞였다 — host를 모르므로 base 앵커다.
_Located _locateAfterDynamicHost(List<UrlPart> rest, {required bool dots}) {
  for (var index = 0; index < rest.length; index++) {
    final part = rest[index];
    if (part is! LiteralUrlPart) continue;
    final start = part.text.indexOf(RegExp(r'[/?#]'));
    if (start < 0) continue;
    final head = part.text.substring(start);
    final path = head.startsWith('/') ? head : '/$head';
    return _Located(
      mergeUrlLiterals([LiteralUrlPart(path), ...rest.skip(index + 1)]),
      'base',
      null,
      dots: dots,
    );
  }
  return _Located(const [LiteralUrlPart('/')], 'base', null, dots: dots);
}

/// 단순 연결의 미상 base 뒤 상대 경로만 `ambiguous-base-join:`으로 센다.
bool _ambiguousJoin(List<UrlPart> parts, UrlJoin join) {
  final first = parts.first;
  final second = parts.length > 1 ? parts[1] : null;
  // dio는 리터럴 경로가 상대·`//`일 때와, 앞 보간 뒤 리터럴이 그럴 때만 결합이
  // 모호하다. 경로 전체가 값이면 결합이 아니라 경로를 모르는 것이다.
  if (join is DioJoin) {
    return first is LiteralUrlPart || second is LiteralUrlPart;
  }
  return first is! LiteralUrlPart &&
      join is! PathOnlyJoin &&
      join is! Rfc3986Join &&
      join is! UriPathJoin &&
      second is LiteralUrlPart &&
      !second.text.startsWith('/');
}

/// dio 연결을 적용한다. null은 증명할 수 없는 결합이다.
_Located? _locateDio(List<UrlPart> parts, DioBase? base) {
  final first = parts.first;
  if (first is LiteralUrlPart && RegExp(r'^https?:').hasMatch(first.text)) {
    return _locateAbsolute(parts, dots: true);
  }
  // 경로 앞머리가 값이면 base를 알아도 그 값이 절대 URL·여러 세그먼트일 수
  // 있다. 값 뒤 `/` 리터럴의 꼬리만 증명된다.
  if (first is! LiteralUrlPart) return _dioAfterValue(parts);
  if (base != null) return _dioWithBase(parts, base);
  if (!first.text.startsWith('/') || first.text.startsWith('//')) return null;
  return _Located(_dioCollapse(parts), 'base', null, dots: true);
}

/// 리터럴·알려진 base 경로와 경로 조각을 이어 붙인다.
_Located _dioWithBase(List<UrlPart> parts, DioBase base) {
  final joined = mergeUrlLiterals([LiteralUrlPart(base.path), ...parts]);
  final collapsed = base.anchor == 'root' || !_startsWithDoubleSlash(joined)
      ? _dioCollapse(joined)
      : joined;
  final first = collapsed.first;
  final rooted = first is LiteralUrlPart && first.text.startsWith('/')
      ? collapsed
      : [const LiteralUrlPart('/'), ...collapsed];
  return _Located(
    mergeUrlLiterals(rooted),
    base.anchor,
    base.authority,
    dots: true,
  );
}

/// 앞 보간(값 모름) 뒤에 `/`가 오면 base다. 보간이 절대 URL이어도 host 뒤 경로가
/// 같은 꼬리로 끝나므로 base 앵커는 참이다.
_Located? _dioAfterValue(List<UrlPart> parts) {
  final next = parts.length > 1 ? parts[1] : null;
  if (next is! LiteralUrlPart || !next.text.startsWith('/')) return null;
  if (next.text.startsWith('//')) return null;
  return _Located(_dioCollapse(parts.sublist(1)), 'base', null, dots: true);
}

bool _startsWithDoubleSlash(List<UrlPart> parts) {
  final first = parts.first;
  return first is LiteralUrlPart && first.text.startsWith('//');
}

/// dio의 `//` → `/` 치환이다. 경로에 `:/`가 있으면 전체 URL의 `:/`가 둘 이상이
/// 되어 dio가 치환하지 않는다(base URL은 scheme 뒤 `:/` 하나라고 가정한다).
List<UrlPart> _dioCollapse(List<UrlPart> parts) {
  final hasColonSlash = parts.any(
    (part) => part is LiteralUrlPart && part.text.contains(':/'),
  );
  if (hasColonSlash) return parts;
  return [
    for (final part in parts)
      part is LiteralUrlPart
          ? LiteralUrlPart(part.text.replaceAll('//', '/'))
          : part,
  ];
}

/// query 꼬리·suffix·보간 규칙을 적용하고 정규화·마스킹한다.
ComposedRoute _assemble(_Located located) {
  final (parts, stripped) = _stripQueryTail(located.parts);
  final template = StringBuffer();
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    final offending = switch (part) {
      LiteralUrlPart(:final text) => () {
        template.write(normalizeRoutePath(text));
        return false;
      }(),
      QueryTailUrlPart() => true,
      ValueUrlPart() => !_fillsWholeSegment(parts, index),
    };
    if (offending) return _dynamicWithPrefix(template.toString(), located);
    if (part is ValueUrlPart) template.write('{}');
  }
  return _finish(template.toString(), located, stripped);
}

/// 점 세그먼트·마스킹·문법 검사를 마친 결과를 만든다.
ComposedRoute _finish(String raw, _Located located, bool stripped) {
  final resolved = located.dots ? removeDotSegments(raw, located.anchor) : raw;
  if (resolved == null) {
    return ComposedRoute.dynamicRoute(
      pathAnchor: located.anchor,
      authority: located.authority,
    );
  }
  final (masked, count) = maskRouteTemplate(resolved, located.authority);
  if (validateRouteTemplate(masked) != null) {
    return _dynamicWithPrefix('', located);
  }
  return ComposedRoute(
    template: masked,
    dynamic: false,
    pathAnchor: located.anchor,
    authority: located.authority,
    queryTailStripped: stripped,
    maskedSegments: count,
  );
}

/// 리터럴의 첫 `?`·`#`부터 끝까지와 그 뒤 조각을 떼고, 마지막 조각이 증명된
/// query 꼬리면 뗀다.
(List<UrlPart>, bool) _stripQueryTail(List<UrlPart> parts) {
  final kept = <UrlPart>[];
  for (final part in parts) {
    if (part is LiteralUrlPart) {
      final cut = part.text.indexOf(RegExp(r'[?#]'));
      if (cut >= 0) {
        if (cut > 0) kept.add(LiteralUrlPart(part.text.substring(0, cut)));
        return (kept, true);
      }
    }
    kept.add(part);
  }
  if (kept.isNotEmpty && kept.last is QueryTailUrlPart) {
    return (kept.sublist(0, kept.length - 1), true);
  }
  return (kept, false);
}

/// 보간이 세그먼트 전체를 채우는지 본다 — 앞이 `/`로 끝나고 뒤가 없거나 `/`로
/// 시작해야 한다.
bool _fillsWholeSegment(List<UrlPart> parts, int index) {
  final before = index > 0 ? parts[index - 1] : null;
  if (before is! LiteralUrlPart || !before.text.endsWith('/')) return false;
  final after = index + 1 < parts.length ? parts[index + 1] : null;
  return after == null ||
      (after is LiteralUrlPart && after.text.startsWith('/'));
}

/// dynamic 결과에 `/`로 시작하는 증명된 접두사를 마스킹해 싣는다.
ComposedRoute _dynamicWithPrefix(String prefix, _Located located) {
  final resolved = located.dots && prefix.startsWith('/')
      ? _resolvePrefixDots(prefix, located.anchor)
      : prefix;
  String? masked;
  if (resolved != null && resolved.startsWith('/')) {
    final candidate = maskRouteTemplate(resolved, located.authority).$1;
    if (validateRouteTemplate(candidate) == null) masked = candidate;
  }
  return ComposedRoute.dynamicRoute(
    channelPrefix: masked,
    pathAnchor: located.anchor,
    authority: located.authority,
  );
}

/// dynamic 접두사의 완결된 세그먼트만 점을 지운다. 뒤 보간과 이어지는 마지막
/// 조각이 점뿐이면 접두사를 증명하지 못한다.
String? _resolvePrefixDots(String prefix, String anchor) {
  final tail = prefix.substring(prefix.lastIndexOf('/') + 1);
  if (tail.isNotEmpty && tail.split('').every((c) => c == '.')) return null;
  final complete = removeDotSegments(
    prefix.substring(0, prefix.length - tail.length),
    anchor,
  );
  return complete == null ? null : '$complete$tail';
}

/// 경로 템플릿의 점 세그먼트를 RFC 3986 §5.2.4대로 지운다.
///
/// 끝의 `.`·`..`는 끝 슬래시를 남기고 root 위의 `..`는 root에 머문다. [anchor]가
/// `base`인데 `..`가 템플릿 앞(미상 base 경로)으로 올라가면 결과를 알 수 없어
/// null이다. `{}` 세그먼트는 점 세그먼트가 아니다.
String? removeDotSegments(String template, String anchor) {
  final segments = template.substring(1).split('/');
  final output = <String>[];
  for (var index = 0; index < segments.length; index++) {
    final last = index == segments.length - 1;
    final segment = segments[index];
    if (segment == '.') {
      if (last) output.add('');
    } else if (segment == '..') {
      if (output.isNotEmpty) {
        output.removeLast();
      } else if (anchor == 'base') {
        return null;
      }
      if (last) output.add('');
    } else {
      output.add(segment);
    }
  }
  return '/${output.join('/')}';
}

/// 리터럴 경로를 정규 표기로 바꾼다(`template.normalize`,
/// `compose.normalize`).
///
/// 퍼센트 인코딩은 대문자 hex로 쓰고 unreserved 문자는 디코드한다. 비ASCII·
/// 금지 문자·리터럴 중괄호는 UTF-8 퍼센트 인코딩하고, 형식이 깨진 `%`는 `%25`로
/// 인코딩한다. 중복·끝 슬래시와 대소문자는 보존한다. `Uri.parse`의 경로
/// 정규화와 같은 결과다.
String normalizeRoutePath(String path) {
  final output = StringBuffer();
  var index = 0;
  while (index < path.length) {
    final hex = _hexAt(path, index);
    if (hex != null) {
      final decoded = String.fromCharCode(int.parse(hex, radix: 16));
      output.write(
        _unreserved.contains(decoded) ? decoded : '%${hex.toUpperCase()}',
      );
      index += 3;
      continue;
    }
    index = _writeEncoded(path, index, output, keepSlash: true);
  }
  return output.toString();
}

/// `Uri.https`·`Uri.http`의 인코딩 전 경로(`unencodedPath`)를 정규 표기로
/// 바꾼다. `%`·`?`·`#`도 문자 그대로 인코딩한다(Dart SDK 동작 확인).
String encodeUnencodedPath(String path) {
  final output = StringBuffer();
  var index = 0;
  while (index < path.length) {
    index = _writeEncoded(path, index, output, keepSlash: true);
  }
  return output.toString();
}

/// [index]의 문자 하나(서러게이트 쌍 포함)를 pchar면 그대로, 아니면 UTF-8
/// 퍼센트 인코딩으로 쓰고 다음 위치를 돌려준다.
int _writeEncoded(
  String path,
  int index,
  StringBuffer output, {
  required bool keepSlash,
}) {
  final unit = path.codeUnitAt(index);
  final character = path[index];
  if ((keepSlash && character == '/') ||
      (unit < 128 && _pchar.contains(character))) {
    output.write(character);
    return index + 1;
  }
  final pair = unit >= 0xD800 && unit <= 0xDBFF && index + 1 < path.length
      ? 2
      : 1;
  for (final byte in utf8.encode(path.substring(index, index + pair))) {
    output.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
  }
  return index + pair;
}

/// [index]가 `%XX` 이스케이프의 시작이면 hex 두 자리를 돌려준다.
String? _hexAt(String path, int index) {
  if (path[index] != '%' || index + 3 > path.length) return null;
  final hex = path.substring(index + 1, index + 3);
  return RegExp(r'^[0-9A-Fa-f]{2}$').hasMatch(hex) ? hex : null;
}

/// 정규 템플릿의 고엔트로피·웹훅 세그먼트를 `{}`로 가린다(`compose.mask`).
///
/// 퍼센트 디코드한 리터럴 세그먼트가 16자 이상이고 ASCII 글자와 숫자를 모두
/// 담으면 가린다. 알려진 웹훅 host는 경로 세그먼트를 모두(`hooks.slack.com`)
/// 또는 `/api/webhooks` 뒤를(`discord.com`·`discordapp.com`) 가린다.
/// 가린 템플릿과 가린 세그먼트 수를 돌려준다.
(String, int) maskRouteTemplate(String template, String? authority) {
  final segments = template.split('/');
  final host = authority?.split(':').first;
  final discord =
      _discordHosts.contains(host) &&
      segments.length > 2 &&
      segments[1] == 'api' &&
      segments[2] == 'webhooks';
  var count = 0;
  final masked = <String>[];
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    final forced = host == 'hooks.slack.com' || (discord && index >= 3);
    final hide =
        index > 0 &&
        segment.isNotEmpty &&
        segment != '{}' &&
        (forced || _isHighEntropy(_percentDecode(segment)));
    if (hide) count++;
    masked.add(hide ? '{}' : segment);
  }
  return (masked.join('/'), count);
}

/// 정규 경로 템플릿 문법을 검사한다(`template.grammar`).
///
/// 적합하면 null, 아니면 계약의 거부 사유 코드를 돌려준다.
String? validateRouteTemplate(String template) {
  if (!template.startsWith('/')) return 'not-rooted';
  if (template.length > maxRouteTemplateLength) return 'too-long';
  final segments = template.substring(1).split('/');
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    if (segment == '{**}') {
      if (index != segments.length - 1) return 'catch-all-not-last';
      continue;
    }
    if (segment.contains('{**}')) return 'catch-all-partial';
    final problem = _validateSegment(segment);
    if (problem != null) return problem;
  }
  return null;
}

/// 세그먼트 하나의 pchar·퍼센트·중괄호 규칙을 검사한다.
String? _validateSegment(String segment) {
  var parameters = 0;
  var index = 0;
  while (index < segment.length) {
    final character = segment[index];
    if (character == '%') {
      final problem = _percentProblem(segment, index);
      if (problem != null) return problem;
      index += 3;
    } else if (character == '{') {
      if (index + 1 >= segment.length || segment[index + 1] != '}') {
        return 'stray-brace';
      }
      if (++parameters > 1) return 'multiple-parameters';
      index += 2;
    } else if (character == '}') {
      return 'stray-brace';
    } else if (segment.codeUnitAt(index) >= 128 ||
        !_pchar.contains(character)) {
      return 'invalid-character';
    } else {
      index++;
    }
  }
  return null;
}

/// `%XX` 하나의 형식 문제다.
String? _percentProblem(String segment, int index) {
  if (index + 3 > segment.length) return 'malformed-percent';
  final hex = segment.substring(index + 1, index + 3);
  if (!RegExp(r'^[0-9A-Fa-f]{2}$').hasMatch(hex)) return 'malformed-percent';
  if (hex != hex.toUpperCase()) return 'lowercase-percent-hex';
  final decoded = String.fromCharCode(int.parse(hex, radix: 16));
  return _unreserved.contains(decoded) ? 'encoded-unreserved' : null;
}

bool _isHighEntropy(String segment) =>
    segment.length >= 16 &&
    segment.contains(RegExp('[A-Za-z]')) &&
    segment.contains(RegExp('[0-9]'));

/// 마스킹 판정용 퍼센트 디코드다. 깨진 시퀀스는 그대로 둔다.
String _percentDecode(String segment) {
  if (!segment.contains('%')) return segment;
  final bytes = <int>[];
  var index = 0;
  while (index < segment.length) {
    final hex = _hexAt(segment, index);
    if (hex != null) {
      bytes.add(int.parse(hex, radix: 16));
      index += 3;
    } else {
      bytes.addAll(utf8.encode(segment[index]));
      index++;
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}

bool _hasScheme(String text) =>
    RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://').hasMatch(text);

/// isthmus 소비자의 authority 문법과 같다 — 맞지 않는 host는 싣지 않는다.
final _authorityPattern = RegExp(
  r'^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*'
  r'|\[[0-9a-f:.]+\])(?::[0-9]{1,5})?$',
);

/// `authority`로 실을 수 있는 소문자 `host[:port]`인지다.
bool isRouteAuthority(String value) => _authorityPattern.hasMatch(value);

const _discordHosts = {'discord.com', 'discordapp.com'};

const _unreservedCharacters =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
final _unreserved = _unreservedCharacters.split('').toSet();
final _pchar = {..._unreserved, ..."!\$&'()*+,;=:@".split('')};
