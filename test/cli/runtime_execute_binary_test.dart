/// setUpAll의 컴파일이 기본 회귀 제한(30초)을 넘을 수 있으므로 스위트
/// 타임아웃을 늘려둔다.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dart compile exe` 배포본에서도 `--execute`가 dart VM을 띄우는지 확인한다.
///
/// 컴파일 배포본의 `Platform.resolvedExecutable`은 그 바이너리 자신이다. 이 경로를
/// dart VM으로 가정하면 `--execute`가 dartograph를 `run <entrypoint>`로 다시 띄워
/// 종료 코드 64와 dartograph 도움말을 실행 증거로 남긴다 — 이 테스트가 고정하는
/// 회귀다. 컴파일은 10초 이상 걸리므로 이 파일 하나에만 둔다.
void main() {
  late Directory directory;
  late String binary;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'runtime-execute-binary.',
    );
    binary = p.join(directory.path, 'dartograph');
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/dartograph.dart',
      '-o',
      binary,
    ]);
    expect(
      compile.exitCode,
      0,
      reason: 'dart compile failed: ${compile.stdout}\n${compile.stderr}',
    );
    // 분석 대상 패키지다. dart VM을 찾는 PATH는 상속한다.
    final root = p.join(directory.path, 'probe_package');
    Directory(root).createSync();
    File(p.join(root, 'pubspec.yaml')).writeAsStringSync(
      "name: probe_package\nenvironment:\n  sdk: '>=3.0.0 <4.0.0'\n",
    );
    File(p.join(root, 'bin', 'probe.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync("void main() { print('probe output'); }\n");
  });

  tearDownAll(() => directory.delete(recursive: true));

  test('컴파일 배포본의 --execute는 진입점을 실행한다', () async {
    final result = await Process.run(
      binary,
      [
        'runtime',
        '--execute',
        'bin/probe.dart',
        '--format',
        'json',
        p.join(directory.path, 'probe_package'),
      ],
      // dart가 PATH에 없는 환경에서도 결정적으로 찾게 현재 테스트 러너의
      // SDK를 명시한다(`<sdk>/bin/dart` 관례).
      environment: {
        'DART_SDK': p.dirname(p.dirname(Platform.resolvedExecutable)),
      },
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    final report = jsonDecode(result.stdout as String) as Map<String, Object?>;
    final execution = report['execution']! as Map<String, Object?>;
    expect(
      execution['exitCode'],
      0,
      reason: 'stderr: ${execution['stderrSummary']}',
    );
    expect(execution['ok'], isTrue);
    expect(execution['stderrSummary'], isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
