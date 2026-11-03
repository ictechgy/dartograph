import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'the released package has no unreachable product declarations',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'dartograph',
        'dead',
        '--format',
        'json',
        '.',
      ]);

      // project:test/ 아래 노드는 index·cli 테스트의 의도된 fixture 입력이다 —
      // 선언이 없는 조건부 export 배럴 같은 파일 발견으로 종료 1이 올 수 있다.
      // 실제 계약은 아래의 "제품(findings from lib/·package:)이 없다"는 검증이다.
      expect(result.exitCode, anyOf(0, 1), reason: result.stderr as String);
      final document =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      final productFindings = (document['findings']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .where(
            (finding) => !(finding['id'] as String).startsWith('project:test/'),
          )
          .toList();
      expect(productFindings, isEmpty);
    },
    // 저장소 전체 자기 분석이라 느린 CI 러너에서 기본 30초를 넘을 수 있다.
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // lib/AGENTS.md의 모듈 의존 방향을 규칙으로 검사한다. analyzer import 경계는
  // tool/check-analyzer-boundary.sh가 따로 본다.
  test('product modules depend only in the documented direction', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'dartograph',
      'rules',
      '--config',
      'tool/module_layers.yaml',
      '--strict',
      '--format',
      'json',
      '.',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final document =
        jsonDecode(result.stdout as String) as Map<String, Object?>;
    expect(document['violations'], isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // 같은 모듈 안의 상호 참조(예: CLI와 MCP 서버가 서로의 명령을 부르는 것)는
  // 허용하지만, 모듈 사이를 가로지르는 라이브러리 순환은 계층을 무너뜨린다.
  test('no library cycle spans more than one product module', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'dartograph',
      'cycles',
      '--level',
      'file',
      '--format',
      'json',
      '.',
    ]);
    expect(result.exitCode, 0, reason: result.stderr as String);
    final document =
        jsonDecode(result.stdout as String) as Map<String, Object?>;
    const productPrefix = 'package:dartograph/src/';
    for (final cycle
        in (document['cycles']! as List<Object?>)
            .cast<Map<String, Object?>>()) {
      final modules = {
        for (final library in (cycle['component']! as List).cast<String>())
          if (library.startsWith(productPrefix))
            library.substring(productPrefix.length).split('/').first,
      };
      expect(modules.length, lessThan(2), reason: '${cycle['component']}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
