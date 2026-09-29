/// isthmus `http-wrappers` v1 선언과 인자 바인딩 규칙이다
/// (isthmus `docs/HTTP-WRAPPERS.md`).
///
/// 모르는 필드·잘못된 값은 선언 오류로 문서 전체를 거부한다 — 선언을 조용히
/// 무시하면 낡은 선언이 호출 0건을 내어 "호출 없음"으로 읽힌다. 오류 문구에는
/// 선언 원문 값을 넣지 않고 위치(`wrappers[3].pathArg`)와 고칠 방향만 싣는다.
///
/// Dart `owner` 규칙: 생성자·메서드는 소유 타입의 dartograph 선언 ID
/// (`package:app/api.dart::ApiClient`), 최상위 함수는 라이브러리 ID
/// (`package:app/net.dart`, `lib/` 밖이면 `project:bin/x.dart`)다. 생성자
/// `name`은 생성자 이름이며 이름 없는 생성자는 `new`다(`ApiClient.new`와 같은
/// Dart 표기).
library;

import 'dart:convert';
import 'route_url_rules.dart';

/// 래퍼 인자 지정자다. 둘 중 하나 이상이 있다.
final class WrapperArgument {
  /// 필드를 받는다.
  const WrapperArgument({this.index, this.label});

  /// 0부터 시작하는 인자 위치다(이름 붙은 인자도 센다).
  final int? index;

  /// Dart 이름 붙은 인자의 이름이다.
  final String? label;
}

/// `http-wrappers` v1 선언 한 건이다.
final class HttpWrapperDeclaration {
  /// 필드를 받는다.
  const HttpWrapperDeclaration({
    required this.position,
    required this.language,
    required this.kind,
    required this.owner,
    required this.name,
    required this.pathArg,
    required this.pathAnchor,
    this.methodArg,
    this.defaultMethod,
    this.methodEnum = const {},
    this.service,
  });

  /// 파일 안의 0부터 시작하는 순번이다(한계 문구의 `wrappers[n]`).
  final int position;

  /// 호출 측 생산자 언어다. `routes`는 `dart`만 적용한다.
  final String language;

  /// `constructor` 또는 `function`이다.
  final String kind;

  /// 소유 타입 ID나 라이브러리 ID다.
  final String owner;

  /// 함수·메서드 이름이나 생성자 이름(`new`)이다.
  final String name;

  /// 동사 인자다.
  final WrapperArgument? methodArg;

  /// 경로 인자다.
  final WrapperArgument pathArg;

  /// 동사 인자를 생략했을 때의 기본 동사다.
  final String? defaultMethod;

  /// enum case·상수 이름 → 동사다.
  final Map<String, String> methodEnum;

  /// `root` 또는 `base`다.
  final String pathAnchor;

  /// 이 래퍼 호출에 싣는 service다.
  final String? service;
}

/// 선언 파일이 계약에 맞지 않는다는 오류다. [message]는 원문 값을 담지 않는다.
final class HttpWrappersFormatException implements Exception {
  /// 사유로 오류를 만든다.
  const HttpWrappersFormatException(this.message);

  /// 위치와 고칠 방향을 담은 사유다.
  final String message;

  @override
  String toString() => message;
}

/// 선언 파일 내용을 선언 목록으로 바꾼다. 모든 언어의 선언을 검증하고
/// 파일 순서대로 돌려준다(언어 필터링은 호출자가 한다).
List<HttpWrapperDeclaration> parseHttpWrappers(String content) {
  if (content.length > 1024 * 1024) _fail('the file exceeds 1 MiB');
  final Object? document;
  try {
    document = jsonDecode(content);
  } on FormatException {
    _fail('the file is not valid JSON');
  }
  if (document is! Map<String, Object?>) {
    _fail('the top level must be an object');
  }
  _rejectUnknown(document, _documentFields, 'the document');
  if (document['format'] != 'http-wrappers') {
    _fail('format must be "http-wrappers"');
  }
  if (document['version'] != 1) _fail('version must be 1');
  final entries = document['wrappers'];
  if (entries is! List) _fail('wrappers must be an array');
  if (entries.length > 1000) _fail('more than 1000 wrappers');
  return [
    for (var index = 0; index < entries.length; index++)
      _declaration(entries[index], index),
  ];
}

HttpWrapperDeclaration _declaration(Object? value, int index) {
  final where = 'wrappers[$index]';
  if (value is! Map<String, Object?>) _fail('$where must be an object');
  _rejectUnknown(value, _wrapperFields, where);
  final language = _choice(value['language'], _languages, '$where.language');
  final kind = _choice(value['kind'], _kinds, '$where.kind');
  final owner = _text(value['owner'], '$where.owner');
  final name = _text(value['name'], '$where.name');
  if (language == 'dart') _checkDartSymbol(kind, owner, name, where);
  final methodArg = value['methodArg'] == null
      ? null
      : _argument(value['methodArg'], '$where.methodArg');
  final pathValue = value['pathArg'];
  if (pathValue == null) _fail('$where.pathArg is required');
  final defaultMethod = value['defaultMethod'] == null
      ? null
      : _choice(value['defaultMethod'], routeCallVerbs, '$where.defaultMethod');
  if (methodArg == null && defaultMethod == null) {
    _fail('$where needs methodArg or defaultMethod');
  }
  return HttpWrapperDeclaration(
    position: index,
    language: language,
    kind: kind,
    owner: owner,
    name: name,
    methodArg: methodArg,
    pathArg: _argument(pathValue, '$where.pathArg'),
    defaultMethod: defaultMethod,
    methodEnum: _methodEnum(value['methodEnum'], '$where.methodEnum'),
    pathAnchor: _choice(value['pathAnchor'], _anchors, '$where.pathAnchor'),
    service: value['service'] == null
        ? null
        : _text(value['service'], '$where.service'),
  );
}

/// Dart 선언의 owner·name 모양을 검사한다. 어떤 선언과도 맞을 수 없는 모양을
/// 먼저 거부해 오타가 조용히 `http-wrapper-unresolved:`로만 남지 않게 한다.
void _checkDartSymbol(String kind, String owner, String name, String where) {
  final library = RegExp(r'^(package|project):[^\s:]+\.dart$');
  final type = RegExp(r'^(package|project):[^\s:]+\.dart::[A-Za-z_$][\w$]*$');
  if (!library.hasMatch(owner) && !type.hasMatch(owner)) {
    _fail(
      '$where.owner must be a dartograph library id (package:app/net.dart) '
      'or type id (package:app/api.dart::ApiClient)',
    );
  }
  if (kind == 'constructor' && !type.hasMatch(owner)) {
    _fail('$where.owner must be a type id for a dart constructor');
  }
  if (!RegExp(r'^[A-Za-z_$][\w$]*$').hasMatch(name)) {
    _fail(
      '$where.name must be a dart identifier (new for an unnamed constructor)',
    );
  }
}

WrapperArgument _argument(Object? value, String where) {
  if (value is! Map<String, Object?>) _fail('$where must be an object');
  _rejectUnknown(value, const {'index', 'label'}, where);
  final index = value['index'];
  if (index != null && (index is! int || index < 0 || index > 255)) {
    _fail('$where.index must be an integer from 0 to 255');
  }
  final label = value['label'] == null
      ? null
      : _text(value['label'], '$where.label');
  if (index == null && label == null) _fail('$where requires index or label');
  return WrapperArgument(index: index as int?, label: label);
}

Map<String, String> _methodEnum(Object? value, String where) {
  if (value == null) return const {};
  if (value is! Map<String, Object?>) _fail('$where must be an object');
  return {
    for (final entry in value.entries)
      _text(entry.key, '$where key'): _choice(
        entry.value,
        routeCallVerbs,
        '$where value',
      ),
  };
}

void _rejectUnknown(
  Map<String, Object?> entry,
  Set<String> allowed,
  String where,
) {
  final unknown = entry.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isEmpty) return;
  _fail(
    '$where has unknown field(s); allowed fields are ${allowed.toList()..sort()}',
  );
}

String _choice(Object? value, Set<String> allowed, String where) {
  if (value is String && allowed.contains(value)) return value;
  _fail('$where must be one of ${allowed.toList()..sort()}');
}

String _text(Object? value, String where) {
  final valid =
      value is String &&
      value.trim().isNotEmpty &&
      value.length <= 512 &&
      !RegExp(r'[\x00-\x1F\x7F-\x9F  ]').hasMatch(value);
  if (valid) return value;
  _fail('$where must be a non-empty string without control characters');
}

Never _fail(String reason) => throw HttpWrappersFormatException(
  'invalid http-wrappers v1 declaration: $reason; fix the file to match the '
  'http-wrappers v1 schema',
);

const _documentFields = {'format', 'version', 'wrappers'};
const _wrapperFields = {
  'language',
  'kind',
  'owner',
  'name',
  'methodArg',
  'pathArg',
  'defaultMethod',
  'methodEnum',
  'pathAnchor',
  'service',
};
const _languages = {'swift', 'kotlin', 'dart', 'js'};
const _kinds = {'constructor', 'function'};
const _anchors = {'root', 'base'};

/// 동사 인자로 쓰일 수 있는 값의 모양이다.
sealed class WrapperArgumentValue {
  const WrapperArgumentValue();
}

/// 문자열 리터럴(또는 상수의 값)이다.
final class LiteralArgumentValue extends WrapperArgumentValue {
  /// [text] 값을 만든다.
  const LiteralArgumentValue(this.text);

  /// 문자열 값이다.
  final String text;
}

/// enum case·상수 이름이다(`HttpMethod.get`의 `get`).
final class EnumCaseArgumentValue extends WrapperArgumentValue {
  /// [name] 값을 만든다.
  const EnumCaseArgumentValue(this.name);

  /// case 이름이다.
  final String name;
}

/// 값을 증명할 수 없는 식이다.
final class OpaqueArgumentValue extends WrapperArgumentValue {
  /// 모르는 값을 만든다.
  const OpaqueArgumentValue();
}

/// 호출 인자 하나다. [label]은 Dart 이름 붙은 인자의 이름이다.
typedef WrapperCallArgument = ({String? label, WrapperArgumentValue value});

/// 래퍼 호출의 인자 위치를 찾는다(`wrapper.method`의 인자 찾기).
///
/// `label`이 있으면 같은 이름의 인자를 먼저 찾는다. 없으면 `index` 위치의
/// 인자를 쓰되 그 인자가 이름을 달고 있으면 쓰지 않는다 — 다른 매개변수에 붙은
/// 이름 인자를 위치로 오인하지 않기 위해서다.
int? findWrapperArgument(WrapperArgument? spec, List<String?> labels) {
  if (spec == null) return null;
  final label = spec.label;
  if (label != null) {
    final found = labels.indexOf(label);
    if (found >= 0) return found;
  }
  final index = spec.index;
  if (index == null || index >= labels.length) return null;
  return labels[index] == null ? index : null;
}

/// 래퍼 호출의 동사를 정한다(`wrapper.method`). 증명하지 못하면 null
/// (`methodDynamic: true`)이다.
String? bindWrapperMethod(
  WrapperArgument? spec,
  String? defaultMethod,
  Map<String, String> methodEnum,
  List<WrapperCallArgument> arguments,
) {
  final index = findWrapperArgument(spec, [
    for (final argument in arguments) argument.label,
  ]);
  if (index == null) return defaultMethod;
  final value = arguments[index].value;
  // 문자열 리터럴은 계약 동사와 정확히 같을 때만 동사다 — "get"은 아니다.
  if (value is LiteralArgumentValue) {
    return routeCallVerbs.contains(value.text) ? value.text : null;
  }
  return value is EnumCaseArgumentValue ? methodEnum[value.name] : null;
}
