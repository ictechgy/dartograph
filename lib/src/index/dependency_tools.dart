import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core/config_source.dart';

/// 선언 패키지가 `package:` import 없이도 사용되는 도구 계약을 제공하는지 본다.
///
/// 네 가지 근거를 확인한다 — 패키지 pubspec의 `executables`(CLI 도구),
/// `build.yaml`의 `builders`·`post_process_builders`(build_runner 진입점),
/// analysis_options의 `include: package:<name>/`(lint 세트)와
/// `analyzer.plugins`(custom_lint 류 플러그인). 확인은 대상 저장소의
/// `.dart_tool/package_config.json`이 가리키는 의존 패키지 루트를 읽는다.
///
/// 반환값은 (tool-like으로 확인된 이름 집합, 관측 한계 문구 목록)이다.
/// package_config를 읽을 수 없으면 도구 인지를 건너뛰었다는 한계를 함께 담는다
/// — import가 전혀 해석되지 않는 상황에서의 미사용 발견은 근거가 약하다는 사실을
/// 숨기지 않는다.
({Set<String> toolLike, List<String> limitations}) detectToolLikeDependencies(
  String root,
  Set<String> declared,
) {
  final limitations = <String>[];
  if (declared.isEmpty) return (toolLike: const {}, limitations: limitations);
  final configFile = File(p.join(root, '.dart_tool', 'package_config.json'));
  final toolLike = <String>{};
  final packageRoots = <String, String>{};
  if (configFile.existsSync()) {
    try {
      final document = (jsonDecode(configFile.readAsStringSync()) as Map)
          .cast<String, Object?>();
      final configUri = configFile.uri;
      for (final entry in document['packages']! as List<Object?>) {
        final map = (entry! as Map).cast<String, Object?>();
        final name = map['name'];
        final rootUri = map['rootUri'];
        if (name is! String || rootUri is! String) continue;
        if (!declared.contains(name)) continue;
        final resolved = configUri.resolveUri(Uri.parse(rootUri));
        if (resolved.scheme != 'file') continue;
        packageRoots[name] = resolved.toFilePath();
      }
    } on Object {
      limitations.add(
        'package-config-unreadable: dependency tool detection was skipped',
      );
      return (toolLike: toolLike, limitations: limitations);
    }
  } else {
    limitations.add(
      'package-config-missing: dependency tool detection was skipped; '
      'run dart pub get',
    );
    return (toolLike: toolLike, limitations: limitations);
  }
  // analysis_options의 lint 계약(include·analyzer.plugins)을 한 번만 읽는다.
  final optionsNames = _analysisOptionPackages(root);
  for (final name in declared) {
    if (optionsNames.contains(name)) {
      toolLike.add(name);
      continue;
    }
    final packageRoot = packageRoots[name];
    if (packageRoot == null) continue;
    final pubspec = File(p.join(packageRoot, 'pubspec.yaml'));
    try {
      final document = loadYaml(readConfigurationSync(pubspec));
      if (document is YamlMap) {
        final executables = document['executables'];
        if (executables is YamlMap && executables.isNotEmpty) {
          toolLike.add(name);
          continue;
        }
      }
    } on Object {
      // 의존 패키지 pubspec을 못 읽어도 감사는 계속한다 — build.yaml과
      // analysis_options 근거가 남아 있다.
    }
    final buildYaml = File(p.join(packageRoot, 'build.yaml'));
    try {
      if (buildYaml.existsSync()) {
        final build = loadYaml(readConfigurationSync(buildYaml));
        if (build is YamlMap &&
            ((build['builders'] is YamlMap &&
                    (build['builders']! as YamlMap).isNotEmpty) ||
                (build['post_process_builders'] is YamlMap &&
                    (build['post_process_builders']! as YamlMap).isNotEmpty))) {
          toolLike.add(name);
        }
      }
    } on Object {
      // 위와 같다 — 한 근거의 읽기 실패가 다른 근거를 가리지 않는다.
    }
  }
  return (toolLike: toolLike, limitations: limitations);
}

/// analysis_options.yaml이 선언한 `package:` include와 analyzer plugin 이름이다.
Set<String> _analysisOptionPackages(String root) {
  final file = File(p.join(root, 'analysis_options.yaml'));
  if (!file.existsSync()) return const {};
  final Object? document;
  try {
    document = loadYaml(readConfigurationSync(file));
  } on Object {
    return const {};
  }
  if (document is! YamlMap) return const {};
  final names = <String>{};
  // include는 단일 URI 또는 URI 목록 둘 다 허용된다 — lint 세트 패키지는
  // `package:` import 없이 도구 계약으로만 쓰인다.
  final includes = switch (document['include']) {
    String single => [single],
    YamlList list => list.whereType<String>().toList(),
    _ => const <String>[],
  };
  for (final include in includes) {
    if (!include.startsWith('package:')) continue;
    final uri = Uri.tryParse(include);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      names.add(uri.pathSegments.first);
    }
  }
  final analyzer = document['analyzer'];
  if (analyzer is YamlMap) {
    final plugins = analyzer['plugins'];
    if (plugins is YamlList) {
      for (final plugin in plugins) {
        if (plugin is String) names.add(plugin);
        if (plugin is YamlMap && plugin.keys.isNotEmpty) {
          names.add('${plugin.keys.first}');
        }
      }
    }
    if (plugins is String) names.add(plugins);
  }
  return names;
}
