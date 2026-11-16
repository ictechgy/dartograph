import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core/config_source.dart';

/// 옵션 파일에서 `include:`를 읽으려고 파싱하는 최대 크기다.
///
/// 옵션 파일은 보통 몇 KiB다. 이보다 큰 파일은 키에는 넣되 그 안의 include는 따라가지
/// 않는다. 키 해시 쪽은 분석 입력 상한으로 따로 막는다.
const _optionsParseLimit = 1024 * 1024;

/// [options]에서 시작해 `include:`로 닿는 옵션 파일들이다([options] 자신은 빼고,
/// 처음 만난 순서).
///
/// analyzer는 include한 파일의 `analyzer: exclude:`도 적용하므로 이 파일들은 분석
/// 결과의 입력이다. 그래서 전체 결과 캐시 키가 이 파일들을 해시해야 한다.
///
/// - `include:`는 문자열 하나나 문자열 목록이다. 상대 경로는 include한 파일의
///   디렉터리 기준이고 루트 밖 경로도 따라간다.
/// - `package:` URI는 [packageConfig]로 푼다(analyzer가 분석 컨텍스트의 package
///   config로 푸는 것과 같다). 없거나 그 패키지가 없으면 그 include는 건너뛴다 —
///   package config 자체가 키 입력이라 나중에 생기면 키가 바뀐다.
/// - 이미 본 파일은 다시 따라가지 않는다(순환 include).
/// - 없는 파일·읽지 못한 파일·YAML이 아닌 파일은 따라가지 않는다. 존재하는 비정규
///   파일(장치·FIFO)은 열지 않고 [NonRegularFileException]으로 실패한다.
List<File> includedOptionsFiles(File options, {File? packageConfig}) {
  final packages = packageConfig == null
      ? const <String, Uri>{}
      : _packageLibraries(packageConfig);
  final seen = <String>{p.normalize(options.absolute.path)};
  final found = <File>[];
  final pending = [options];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    for (final value in _includeValues(current)) {
      final target = _resolveInclude(value, current, packages);
      if (target == null || !seen.add(p.normalize(target.path))) continue;
      if (!regularFileExistsSync(target)) continue;
      found.add(target);
      pending.add(target);
    }
  }
  return found;
}

/// 옵션 파일 [file]의 `include:` 값들이다. 읽지 못하면 비어 있다.
List<String> _includeValues(File file) {
  final Object? document;
  try {
    if (!regularFileExistsSync(file)) return const [];
    if (file.lengthSync() > _optionsParseLimit) return const [];
    document = loadYaml(file.readAsStringSync());
  } on FileSystemException {
    return const [];
  } on YamlException {
    return const [];
  }
  if (document is! Map) return const [];
  return switch (document['include']) {
    final String value => [value],
    final List<Object?> values => [
      for (final value in values)
        if (value is String) value,
    ],
    _ => const [],
  };
}

/// include 값 [value]를 [from] 기준으로 푼 파일이다. 풀 수 없으면 null이다.
File? _resolveInclude(String value, File from, Map<String, Uri> packages) {
  if (!value.startsWith('package:')) {
    return File(p.normalize(p.join(from.parent.absolute.path, value)));
  }
  final Uri uri;
  try {
    uri = Uri.parse(value);
  } on FormatException {
    return null;
  }
  if (uri.pathSegments.length < 2) return null;
  final library = packages[uri.pathSegments.first];
  if (library == null) return null;
  try {
    return File.fromUri(library.resolve(uri.pathSegments.skip(1).join('/')));
  } on UnsupportedError {
    return null;
  }
}

/// package config [file]의 패키지 이름 → `packageUri` 디렉터리 URI다.
///
/// 문서를 읽지 못하거나 모양이 기대와 다르면 비어 있다. analyzer도 그런 문서는
/// 버리고 패키지 없이 해석한다.
Map<String, Uri> _packageLibraries(File file) {
  final Object? document;
  try {
    document = jsonDecode(file.readAsStringSync());
  } on FileSystemException {
    return const {};
  } on FormatException {
    return const {};
  }
  if (document is! Map<String, Object?>) return const {};
  final packages = document['packages'];
  if (packages is! List<Object?>) return const {};
  final libraries = <String, Uri>{};
  for (final package in packages) {
    if (package is! Map<String, Object?>) return const {};
    final library = _packageLibrary(file, package);
    if (library != null) libraries[package['name']! as String] = library;
  }
  return libraries;
}

/// package config 항목 [package]의 `packageUri` 디렉터리 URI다.
Uri? _packageLibrary(File configuration, Map<String, Object?> package) {
  final name = package['name'];
  final rootUri = package['rootUri'];
  final packageUri = package['packageUri'] ?? '';
  if (name is! String || rootUri is! String || packageUri is! String) {
    return null;
  }
  try {
    final root = configuration.parent.absolute.uri.resolve(
      rootUri.endsWith('/') ? rootUri : '$rootUri/',
    );
    final library = root.resolve(packageUri);
    if (library.scheme != 'file') return null;
    return library.path.endsWith('/')
        ? library
        : library.replace(path: '${library.path}/');
  } on FormatException {
    return null;
  }
}
