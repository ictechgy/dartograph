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
  test(
    'product modules depend only in the documented direction',
    _expectDocumentedModuleDirection,
    timeout: _selfAnalysisTimeout,
  );

  // 같은 모듈 안의 상호 참조(예: CLI와 MCP 서버가 서로의 명령을 부르는 것)는
  // 허용하지만, 모듈 사이를 가로지르는 라이브러리 순환은 계층을 무너뜨린다.
  test(
    'no library cycle spans more than one product module',
    _expectNoCrossModuleLibraryCycle,
    timeout: _selfAnalysisTimeout,
  );
}

/// 저장소 전체를 다시 분석하는 자기 분석 테스트의 제한 시간이다.
///
/// 느린 CI 러너에서 기본 30초를 넘을 수 있다.
const _selfAnalysisTimeout = Timeout(Duration(minutes: 3));

/// 제품 라이브러리가 모듈로 묶이는 패키지 경로 접두사다.
const _productLibraryPrefix = 'package:dartograph/src/';

/// `tool/module_layers.yaml`의 모듈 방향 규칙을 어기는 의존이 없는지 확인한다.
Future<void> _expectDocumentedModuleDirection() async {
  final result = await _runDartograph(const [
    'rules',
    '--config',
    'tool/module_layers.yaml',
    '--strict',
    '--format',
    'json',
    '.',
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  final document = _decodeObject(result.stdout as String);
  expect(document['violations'], isEmpty);
}

/// 파일 수준 순환 가운데 둘 이상의 제품 모듈에 걸친 것이 없는지 확인한다.
Future<void> _expectNoCrossModuleLibraryCycle() async {
  final result = await _runDartograph(const [
    'cycles',
    '--level',
    'file',
    '--format',
    'json',
    '.',
  ]);
  expect(result.exitCode, 0, reason: result.stderr as String);
  final cycles = _decodeObject(result.stdout as String)['cycles']! as List;
  for (final cycle in cycles.cast<Map<String, Object?>>()) {
    final libraries = (cycle['component']! as List).cast<String>();
    final modules = _productModulesOf(libraries);
    expect(modules.length, lessThan(2), reason: '$libraries');
  }
}

/// 이 저장소의 dartograph CLI를 [arguments]로 실행한다.
Future<ProcessResult> _runDartograph(List<String> arguments) {
  final command = ['run', 'dartograph', ...arguments];
  return Process.run(Platform.resolvedExecutable, command);
}

/// JSON 객체 문서를 디코드한다.
Map<String, Object?> _decodeObject(String json) {
  return jsonDecode(json) as Map<String, Object?>;
}

/// [libraries] 가운데 제품 라이브러리가 속한 최상위 모듈 이름들이다.
Set<String> _productModulesOf(List<String> libraries) {
  return {
    for (final library in libraries)
      if (library.startsWith(_productLibraryPrefix))
        library.substring(_productLibraryPrefix.length).split('/').first,
  };
}
