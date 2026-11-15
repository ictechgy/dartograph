import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

/// 분석 SDK가 `environment.sdk` 하한보다 낮다는 한계가 발견·종료 코드를 바꾸지
/// 않고 limitations에만 실리는지 CLI 출력으로 고정한다.
void main() {
  late Directory root;

  Future<void> write(String relative, String content) async {
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<void> constraint(String sdk) => write(
    'pubspec.yaml',
    'name: floor_app\npublish_to: none\nenvironment:\n  sdk: $sdk\n',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dartograph-sdk-floor-cli.');
    await write('bin/main.dart', '''
// pub get 없이 해석되도록 상대 경로로 가져온다.
import '../lib/used.dart';

void main() => used();
''');
    await write('lib/used.dart', 'void used() {}\n');
    await write('lib/unused.dart', 'void unused() {}\n');
  });
  tearDown(() => root.delete(recursive: true));

  Future<(int, Map<String, Object?>)> run(List<String> command) async {
    final output = StringBuffer();
    // 사용자 캐시를 쓰지 않는다(격리).
    final status = await runDartograph(
      [...command, '--format', 'json', root.path],
      output: output,
      userCacheEnvironment: const {},
    );
    return (status, jsonDecode(output.toString()) as Map<String, Object?>);
  }

  bool isSdkFloor(Object? item) => '$item'.startsWith('sdk-below-minimum:');

  List<Object?> withoutSdkFloor(Object? items) => [
    for (final item in items! as List)
      if (!isSdkFloor(item)) item,
  ];

  /// 발견마다 붙는 전역 한계에서 sdk-below-minimum만 뺀 발견 목록이다.
  List<Object?> findingsWithoutSdkFloor(Map<String, Object?> document) => [
    for (final finding in document['findings']! as List)
      {
        for (final MapEntry(:key, :value)
            in (finding as Map<String, Object?>).entries)
          key: key == 'limitations' ? withoutSdkFloor(value) : value,
      },
  ];

  test(
    'dead keeps findings and the exit code, adding only the limitation',
    () async {
      await constraint('^3.0.0');
      final (satisfiedStatus, satisfied) = await run(['dead']);
      await constraint('^99.0.0');
      final (belowStatus, below) = await run(['dead']);

      expect(satisfiedStatus, ExitStatus.findings.code);
      expect(belowStatus, satisfiedStatus);
      // unused와 그 파일, 두 발견이 그대로다. 전역 한계라 발견마다 붙는다.
      expect(findingsWithoutSdkFloor(below), hasLength(2));
      expect(
        findingsWithoutSdkFloor(below),
        findingsWithoutSdkFloor(satisfied),
      );
      for (final finding in below['findings']! as List) {
        expect(
          ((finding as Map)['limitations'] as List).where(isSdkFloor),
          hasLength(1),
        );
      }
      expect((satisfied['limitations']! as List).where(isSdkFloor), isEmpty);
      expect(
        (below['limitations']! as List).where(isSdkFloor).single,
        startsWith(
          'sdk-below-minimum: Dart SDK ${Platform.version.split(' ').first} '
          'used for analysis is below the environment.sdk lower bound of 1 '
          'package(s): pubspec.yaml (>=99.0.0);',
        ),
      );
      expect(withoutSdkFloor(below['limitations']), satisfied['limitations']);
    },
  );

  test('a strict gate without findings still succeeds', () async {
    await File('${root.path}/lib/unused.dart').delete();
    await constraint('^99.0.0');

    final (deadStatus, dead) = await run(['dead']);
    final (cyclesStatus, cycles) = await run(['cycles', '--strict']);

    expect(deadStatus, ExitStatus.success.code);
    expect(cyclesStatus, ExitStatus.success.code);
    for (final document in [dead, cycles]) {
      expect(
        (document['limitations']! as List).where(isSdkFloor),
        hasLength(1),
      );
    }
  });
}
