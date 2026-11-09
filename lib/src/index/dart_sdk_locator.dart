import 'dart:io';

import 'package:path/path.dart' as p;

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
