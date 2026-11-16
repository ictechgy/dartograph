import 'dart:io';
import 'dart:isolate';

import 'package:yaml/yaml.dart';

/// 이 프로세스가 링크한 `package:analyzer`의 신원이다. 분석 캐시 키의 성분이다.
///
/// analyzer 마이너마다 같은 입력의 해석이 다를 수 있다(14.6의 include exclude
/// 변경). 분석 대상의 package config는 dartograph 자신이 쓰는 analyzer를 담지
/// 않으므로(전역 설치·AOT·저장소 소스 실행) 이 신원을 따로 키에 넣는다.
///
/// - JIT(`dart run`, `dart pub global activate`): 해석된 `package:analyzer/`의
///   pubspec 버전과 그 경로다.
/// - AOT(`dart install`, `dart compile exe`): 패키지 해석이 없다. analyzer는 컴파일할
///   때 정해지므로 실행 파일 자체의 경로·크기·수정 시각을 쓴다. 다시 빌드하거나
///   설치하면 바뀐다.
///
/// [resolvePackageUri]와 [executable]은 테스트 주입점이다(기본은 실제 isolate의
/// 패키지 해석과 [Platform.resolvedExecutable]).
String analyzerPackageIdentity({
  Uri? Function(Uri uri)? resolvePackageUri,
  String? executable,
}) {
  final library = (resolvePackageUri ?? _resolvePackageUri)(
    Uri.parse('package:analyzer/'),
  );
  if (library != null) return _packageIdentity(library);
  return _executableIdentity(executable ?? Platform.resolvedExecutable);
}

/// isolate의 패키지 해석이다. AOT처럼 해석할 수 없으면 null이다.
Uri? _resolvePackageUri(Uri uri) {
  try {
    return Isolate.resolvePackageUriSync(uri);
  } on UnsupportedError {
    return null;
  }
}

/// `lib/` 디렉터리 URI [library]가 속한 패키지의 버전과 경로다.
String _packageIdentity(Uri library) {
  String? version;
  try {
    final pubspec = loadYaml(
      File.fromUri(library.resolve('../pubspec.yaml')).readAsStringSync(),
    );
    if (pubspec is Map && pubspec['version'] is String) {
      version = pubspec['version'] as String;
    }
  } on FileSystemException {
    // 버전을 읽지 못해도 경로가 신원이 된다(hosted 경로에는 버전이 들어 있다).
  } on YamlException {
    // 위와 같다.
  } on UnsupportedError {
    // file:이 아닌 URI다.
  }
  return 'analyzer ${version ?? 'unknown'} $library';
}

/// AOT 실행 파일 [path]의 경로·크기·수정 시각이다.
String _executableIdentity(String path) {
  final stat = FileStat.statSync(path);
  if (stat.type == FileSystemEntityType.notFound) return 'aot $path';
  return 'aot $path ${stat.size} ${stat.modified.microsecondsSinceEpoch}';
}
