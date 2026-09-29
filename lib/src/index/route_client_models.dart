/// HTTP 클라이언트 라이브러리 API의 신원 판정이다.
///
/// 이름이 같은 사용자 선언을 라이브러리 호출로 오인하지 않도록 analyzer가 해석한
/// element의 라이브러리 URI(`package:dio/…`)와 소유 타입 계층으로만 판정한다.
/// 각 라이브러리의 의미(dio 연결, retrofit.dart·chopper 생성 규칙)는 해당 버전의
/// 공식 소스에서 확인했다(doc/HTTP-ROUTES.md).
library;

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';

/// package:http 최상위 함수·`Client` 메서드 이름 → 동사다(`read`는 GET).
const httpClientVerbs = {
  'get': 'GET',
  'head': 'HEAD',
  'post': 'POST',
  'put': 'PUT',
  'patch': 'PATCH',
  'delete': 'DELETE',
  'read': 'GET',
  'readBytes': 'GET',
};

/// dio `Dio` 메서드 이름 → 고정 동사다(`checkOptions`가 동사를 덮어쓴다).
const dioFixedVerbs = {
  'get': 'GET',
  'getUri': 'GET',
  'head': 'HEAD',
  'headUri': 'HEAD',
  'post': 'POST',
  'postUri': 'POST',
  'put': 'PUT',
  'putUri': 'PUT',
  'patch': 'PATCH',
  'patchUri': 'PATCH',
  'delete': 'DELETE',
  'deleteUri': 'DELETE',
};

/// dio에서 동사를 `Options.method`나 base 설정에서 읽는 메서드다.
const dioRequestMethods = {'request', 'requestUri'};

/// 모델링하지 않은 dio 요청 API다(`route-call-coverage:`로 센다).
const dioUnmodelledMethods = {'fetch', 'download', 'downloadUri'};

/// dart:io `HttpClient`의 요청 메서드다. 모델링하지 않고 개수만 센다.
const ioHttpClientMethods = {
  'open',
  'openUrl',
  'get',
  'getUrl',
  'post',
  'postUrl',
  'put',
  'putUrl',
  'patch',
  'patchUrl',
  'delete',
  'deleteUrl',
  'head',
  'headUrl',
};

/// 직접 호출을 모델링하지 않은 chopper `ChopperClient` 메서드다.
const chopperClientMethods = {
  'get',
  'post',
  'put',
  'patch',
  'delete',
  'head',
  'options',
  'send',
};

/// 라이브러리 [element]가 [package]의 것인지다(`package:<package>/`).
bool isFromPackage(Element? element, String package) {
  final uri = element?.library?.uri;
  return uri != null &&
      uri.scheme == 'package' &&
      uri.pathSegments.isNotEmpty &&
      uri.pathSegments.first == package;
}

/// [type] 자신이나 상위 타입 중 [package]의 [names] 타입이 있는지다.
bool hasPackageSupertype(
  InterfaceElement? type,
  String package,
  Set<String> names,
) {
  if (type == null) return false;
  if (isFromPackage(type, package) && names.contains(type.name)) return true;
  return type.allSupertypes.any(
    (supertype) =>
        isFromPackage(supertype.element, package) &&
        names.contains(supertype.element.name),
  );
}

/// [element]가 package:http 최상위 요청 함수면 동사를 돌려준다.
String? httpTopLevelVerb(Element? element) {
  if (element is! TopLevelFunctionElement) return null;
  if (!isFromPackage(element, 'http')) return null;
  return httpClientVerbs[element.name];
}

/// [element]가 package:http `Client` 계열 메서드면 동사를 돌려준다.
///
/// `IOClient`·`RetryClient`·`CupertinoClient`처럼 `Client`를 구현한 타입의
/// 상속 메서드도 같다. 프로젝트가 `get`을 재정의한 하위 타입은 라이브러리
/// 의미를 보장하지 않으므로 신원을 주장하지 않는다.
String? httpClientMethodVerb(Element? element) {
  if (element is! MethodElement || !isFromPackage(element, 'http')) return null;
  final owner = element.enclosingElement;
  if (owner is! InterfaceElement) return null;
  if (!hasPackageSupertype(owner, 'http', const {'Client'})) return null;
  return httpClientVerbs[element.name];
}

/// [element]가 package:http 요청 객체(`Request`·`StreamedRequest`·
/// `MultipartRequest` 등 `BaseRequest` 하위 타입)의 생성자인지다.
bool isHttpRequestConstructor(Element? element) {
  if (element is! ConstructorElement || !isFromPackage(element, 'http')) {
    return false;
  }
  return hasPackageSupertype(element.enclosingElement, 'http', const {
    'BaseRequest',
  });
}

/// [element]가 dio `Dio` 메서드(구현 믹스인 포함)면 그 이름을 돌려준다.
String? dioMethodName(Element? element) {
  if (element is! MethodElement || !isFromPackage(element, 'dio')) return null;
  final owner = element.enclosingElement;
  if (owner is! InterfaceElement) return null;
  if (!hasPackageSupertype(owner, 'dio', const {'Dio', 'DioMixin'})) {
    return null;
  }
  return element.name;
}

/// [element]가 dart:io `HttpClient` 요청 메서드인지다.
bool isIoHttpClientRequest(Element? element) {
  if (element is! MethodElement) return false;
  final library = element.library.uri.toString();
  final owner = element.enclosingElement;
  return (library == 'dart:io' || library == 'dart:_http') &&
      owner is InterfaceElement &&
      owner.name == 'HttpClient' &&
      ioHttpClientMethods.contains(element.name);
}

/// [element]가 chopper `ChopperClient`의 직접 요청 메서드인지다.
bool isChopperClientRequest(Element? element) {
  if (element is! MethodElement || !isFromPackage(element, 'chopper')) {
    return false;
  }
  final owner = element.enclosingElement;
  return owner is InterfaceElement &&
      owner.name == 'ChopperClient' &&
      chopperClientMethods.contains(element.name);
}

/// 상수 객체가 [package]의 [name] 타입(또는 그 하위 타입)의 인스턴스인지다.
bool isPackageConstant(DartObject? value, String package, String name) {
  final type = value?.type?.element;
  return type is InterfaceElement && hasPackageSupertype(type, package, {name});
}

/// 상수 객체의 필드를 상위 클래스 사슬(`(super)`)까지 따라 읽는다.
DartObject? constantField(DartObject? value, String name) {
  var current = value;
  for (var depth = 0; current != null && depth < 8; depth++) {
    final field = current.getField(name);
    if (field != null) return field;
    current = current.getField('(super)');
  }
  return null;
}
