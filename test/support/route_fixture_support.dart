import 'dart:convert';
import 'dart:io';

/// 저장소의 HTTP 클라이언트 스텁 패키지 이름이다(fixtures/http_client_stubs).
const routeStubPackages = ['http', 'dio', 'retrofit', 'chopper'];

/// [root]에 [name] 패키지를 쓰고 스텁을 가리키는 package_config를 만든다.
///
/// pub get 없이(네트워크 없이) analyzer가 `package:dio/…` 같은 URI를 스텁으로
/// 해석하게 한다. [files]는 패키지 루트 기준 상대 경로 → 내용이다.
Future<void> writeRoutePackage(
  Directory root,
  String name,
  Map<String, String> files,
) async {
  await File(
    '${root.path}/pubspec.yaml',
  ).writeAsString('name: $name\nenvironment:\n  sdk: ^3.11.0\n');
  for (final entry in files.entries) {
    final file = File('${root.path}/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  await writeStubPackageConfig(root, name);
}

/// [root]의 `.dart_tool/package_config.json`을 스텁과 [name] 패키지로 쓴다.
Future<void> writeStubPackageConfig(Directory root, String name) async {
  final stubs = Directory('fixtures/http_client_stubs').absolute.path;
  final config = {
    'configVersion': 2,
    'packages': [
      for (final stub in routeStubPackages)
        {
          'name': stub,
          'rootUri': Uri.directory('$stubs/$stub').toString(),
          'packageUri': 'lib/',
          'languageVersion': '3.11',
        },
      {
        'name': name,
        'rootUri': '../',
        'packageUri': 'lib/',
        'languageVersion': '3.11',
      },
    ],
  };
  final file = File('${root.path}/.dart_tool/package_config.json');
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(config));
}

/// 오라클 fixture(fixtures/http_routes)를 임시 디렉터리에 복사하고 스텁으로
/// 해석되게 한다. 분석 제외 설정(analysis_options.yaml)은 지운다.
Future<Directory> copyRouteFixture() async {
  final target = await Directory.systemTemp.createTemp('dartograph-routes');
  await _copy(Directory('fixtures/http_routes'), target);
  final options = File('${target.path}/analysis_options.yaml');
  if (options.existsSync()) await options.delete();
  await writeStubPackageConfig(target, 'http_routes_fixture');
  return target;
}

Future<void> _copy(Directory source, Directory target) async {
  await for (final entity in source.list(followLinks: false)) {
    final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (name == '.dart_tool') continue;
    if (entity is Directory) {
      final child = Directory('${target.path}/$name');
      await child.create();
      await _copy(entity, child);
    } else if (entity is File) {
      await entity.copy('${target.path}/$name');
    }
  }
}
