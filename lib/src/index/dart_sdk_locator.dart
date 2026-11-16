import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// analyzer가 `dart:` 라이브러리를 읽을 Dart SDK 디렉터리를 찾지 못했다는 실패다.
///
/// 찾지 못한 채 analyzer 기본값에 맡기면 analyzer는 실행 파일의 두 단계 위를 SDK로
/// 간주한다. AOT 바이너리(`dart install`·`dart compile exe`)에서는 그 위치가 SDK가
/// 아니라서 `allowed_experiments.json`을 읽지 못하고, 그 예외가 원인을 알 수 없는
/// 색인 실패로 끝난다(#160). 그래서 추측하지 않고 이 실패로 멈춘다. 메시지와
/// 문자열 표현에는 경로를 담지 않는다(다른 색인 실패 진단과 같은 경계).
final class DartSdkNotFoundException implements Exception {
  /// 실패를 만든다.
  const DartSdkNotFoundException();

  @override
  String toString() => 'DartSdkNotFoundException: no Dart SDK was located';
}

/// SDK 디렉터리 판정에 쓰는 호스트 관측 주입점이다(기본값은 실제 파일 시스템).
final class DartSdkProbe {
  /// 관측 함수를 받는다. 주지 않으면 dart:io로 관측한다.
  const DartSdkProbe({
    this.fileExists = _fileExists,
    this.resolveLinks = _resolveLinks,
  });

  /// [path]가 존재하는 파일인지다. 관측 실패는 false다.
  final bool Function(String path) fileExists;

  /// [path]의 링크를 끝까지 해석한 경로다. 해석할 수 없으면 null이다.
  final String? Function(String path) resolveLinks;

  /// [directory]가 analyzer가 읽을 수 있는 SDK 레이아웃인지다.
  ///
  /// 기존 인덱서와 같은 표지 파일(`sdk_library_metadata`의 `libraries.dart`)로 본다.
  bool isSdk(String directory) => fileExists(
    p.join(
      directory,
      'lib',
      '_internal',
      'sdk_library_metadata',
      'lib',
      'libraries.dart',
    ),
  );
}

/// analyzer에 넘길 Dart SDK 디렉터리를 찾는다. 찾지 못하면 null이다.
///
/// 순서는 다음과 같고, 각 후보는 [DartSdkProbe.isSdk]로 검증한다.
///
/// 1. 실행 중인 실행 파일(VM이면 그 SDK).
/// 2. `DART_SDK` 환경변수.
/// 3. `FLUTTER_ROOT/bin/cache/dart-sdk`.
/// 4. `PATH`의 각 디렉터리. 링크를 해석한 `dart`(`dart.exe`)의 두 단계 위, 그리고
///    Flutter 레이아웃(`<bin>/cache/dart-sdk`). Flutter의 `bin/dart`는 셸 래퍼라서
///    두 단계 위가 SDK가 아니다. Windows의 Flutter는 `dart.bat`만 둔다.
/// 5. 실행 파일 옆의 `dart-sdk`와 실행 파일 디렉터리 자체. 0.17.0까지 탐색이 실패하면
///    analyzer 기본값이 이 두 후보를 봤으므로, 그 배치가 계속 동작하도록 마지막에
///    유지한다. analyzer가 함께 보던 작업 디렉터리 기준 후보(`third_party/...`)는
///    분석 대상 저장소가 SDK를 바꿔치기할 수 있어 보지 않는다.
///
/// [resolvedExecutable]·[environment]·[windows]·[probe]는 테스트 주입점이다.
String? locateDartSdk({
  String? resolvedExecutable,
  Map<String, String>? environment,
  bool? windows,
  DartSdkProbe probe = const DartSdkProbe(),
}) {
  final variables = environment ?? Platform.environment;
  return _sdkAboveExecutable(
        resolvedExecutable ?? Platform.resolvedExecutable,
        probe,
      ) ??
      _sdkAt(variables['DART_SDK'], probe) ??
      _sdkAt(_flutterCacheSdk(variables['FLUTTER_ROOT']), probe) ??
      _sdkOnPath(variables['PATH'], windows ?? Platform.isWindows, probe) ??
      _sdkBesideExecutable(
        resolvedExecutable ?? Platform.resolvedExecutable,
        probe,
      );
}

/// [directory]가 비어 있지 않은 SDK면 그 경로다.
String? _sdkAt(String? directory, DartSdkProbe probe) =>
    directory != null && directory.isNotEmpty && probe.isSdk(directory)
    ? directory
    : null;

/// Flutter 루트 [flutterRoot] 안에 Flutter가 내려받아 두는 Dart SDK 경로다.
String? _flutterCacheSdk(String? flutterRoot) =>
    flutterRoot == null || flutterRoot.isEmpty
    ? null
    : p.join(flutterRoot, 'bin', 'cache', 'dart-sdk');

/// 실행 파일 [executable]의 링크를 해석한 뒤 두 단계 위가 SDK면 그 경로다.
String? _sdkAboveExecutable(String executable, DartSdkProbe probe) {
  if (!probe.fileExists(executable)) return null;
  final resolved = probe.resolveLinks(executable);
  return resolved == null
      ? null
      : _sdkAt(p.dirname(p.dirname(resolved)), probe);
}

/// 실행 파일 [executable] 옆의 `dart-sdk`, 또는 그 디렉터리 자체가 SDK면 그 경로다.
String? _sdkBesideExecutable(String executable, DartSdkProbe probe) {
  if (!probe.fileExists(executable)) return null;
  final resolved = probe.resolveLinks(executable);
  if (resolved == null) return null;
  final directory = p.dirname(resolved);
  return _sdkAt(p.join(directory, 'dart-sdk'), probe) ??
      _sdkAt(directory, probe);
}

/// `PATH` 값 [pathValue]의 디렉터리를 앞에서부터 훑어 처음 찾은 SDK다.
String? _sdkOnPath(String? pathValue, bool windows, DartSdkProbe probe) {
  if (pathValue == null || pathValue.isEmpty) return null;
  for (final directory in pathValue.split(windows ? ';' : ':')) {
    if (directory.isEmpty) continue;
    final sdk = _sdkForPathDirectory(directory, windows, probe);
    if (sdk != null) return sdk;
  }
  return null;
}

/// `PATH` 디렉터리 하나에서 dart 실행 파일·래퍼가 가리키는 SDK다.
String? _sdkForPathDirectory(
  String directory,
  bool windows,
  DartSdkProbe probe,
) {
  for (final name
      in windows ? const ['dart.exe', 'dart.bat'] : const ['dart']) {
    final candidate = p.join(directory, name);
    if (!probe.fileExists(candidate)) continue;
    final resolved = probe.resolveLinks(candidate);
    if (resolved == null) continue;
    final sdk =
        _sdkAt(p.dirname(p.dirname(resolved)), probe) ??
        _sdkAt(p.join(p.dirname(resolved), 'cache', 'dart-sdk'), probe);
    if (sdk != null) return sdk;
  }
  return null;
}

/// 분석 SDK가 패키지 `environment.sdk` 하한보다 낮다는 limitation의 접두사다.
const sdkBelowMinimumPrefix = 'sdk-below-minimum:';

/// 분석에 쓰는 SDK 버전 [sdkVersion]이 `environment.sdk` 하한보다 낮은 패키지를
/// 센 limitation 문구다. 그런 패키지가 없으면 null이다.
///
/// [pubspecs]는 분석한 패키지의 루트 상대 pubspec 경로 → 내용이다(내용이 없으면
/// null). 경로순으로 앞의 세 개만 싣고 나머지는 개수로 적는다.
///
/// 오류가 아니라 관측이다. SDK의 `dart:` 라이브러리와 언어 기능이 패키지가 요구하는
/// 것보다 오래돼 일부 참조가 해석되지 않을 수 있다는 뜻일 뿐, 실제로 해석이
/// 실패했다는 증명이 아니다. 실제 실패는 기존 소스 단위 한계가 따로 센다.
///
/// 비교하지 않는 경우는 세지 않는다. SDK 버전이나 제약을 읽지 못한 경우,
/// `environment.sdk`가 없는 경우, 하한이 없는 제약(`any`, `<4.0.0`)과 만족할 수
/// 없는 제약이 그렇다. 하한 비교는 pub과 같은 `pub_semver` 의미를 쓴다 — 사전
/// 릴리스 SDK(`3.14.0-1.0.dev`)는 `^3.14.0`보다 낮고 `>=3.14.0-0`은 충족한다.
String? sdkBelowMinimumLimitation(
  String sdkVersion,
  Map<String, String?> pubspecs,
) {
  final Version sdk;
  try {
    sdk = Version.parse(sdkVersion.trim());
  } on FormatException {
    return null;
  }
  final below = [
    for (final path in pubspecs.keys.toList()..sort())
      if (_lowerBoundAbove(sdk, pubspecs[path]) case final bound?)
        '$path ($bound)',
  ];
  if (below.isEmpty) return null;
  const shown = 3;
  final listed = below.take(shown).join(', ');
  final more = below.length > shown ? ' and ${below.length - shown} more' : '';
  return '$sdkBelowMinimumPrefix Dart SDK $sdk used for analysis is below the '
      'environment.sdk lower bound of ${below.length} package(s): '
      '$listed$more; SDK libraries and language features newer than $sdk may '
      'not resolve, so reachability can be incomplete (analyze with a Dart SDK '
      'that satisfies environment.sdk)';
}

/// pubspec [content]의 `environment.sdk` 하한이 [sdk]보다 높으면 그 하한 표기
/// (`>=3.13.0`·`>3.13.0`)다. 하한이 없거나 읽지 못하면 null이다.
///
/// 표기는 원문이 아니라 파싱한 버전으로 만든다. 저장소가 쓴 문자열을 그대로
/// 반향하지 않는다.
String? _lowerBoundAbove(Version sdk, String? content) {
  if (content == null) return null;
  final Object? document;
  try {
    document = loadYaml(content);
  } on YamlException {
    return null;
  }
  if (document is! Map) return null;
  final environment = document['environment'];
  if (environment is! Map) return null;
  final text = environment['sdk'];
  if (text is! String) return null;
  final VersionConstraint constraint;
  try {
    constraint = VersionConstraint.parse(text);
  } on FormatException {
    return null;
  }
  // 만족할 수 없는 제약(`VersionConstraint.empty`)은 범위가 아니다.
  if (constraint is! VersionRange) return null;
  final minimum = constraint.min;
  if (minimum == null) return null;
  final below = constraint.includeMin ? sdk < minimum : sdk <= minimum;
  if (!below) return null;
  return '${constraint.includeMin ? '>=' : '>'}$minimum';
}

/// dart:io로 [path]가 파일인지 본다. 권한 등 관측 실패는 없는 것으로 다룬다.
bool _fileExists(String path) {
  try {
    return File(path).existsSync();
  } on FileSystemException {
    return false;
  }
}

/// dart:io로 [path]의 링크를 해석한다. 끊긴 링크·권한 실패는 null이다.
String? _resolveLinks(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
}
