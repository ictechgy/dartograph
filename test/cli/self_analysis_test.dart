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
}
