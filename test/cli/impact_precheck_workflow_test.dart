import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// 예시 워크플로 `.github/workflows/impact-precheck.yml`의 캐시·원장 경계를
/// 고정한다.
///
/// 사용자는 이 예시를 복사해 쓴다. 증분 사실 캐시는 키가 맞는 사실을 다시
/// 해석하지 않고 쓰고, 원장은 기존 줄 뒤에 덧붙인다. 둘을 PR이 내용을 고르는
/// 워크스페이스 안에 두면 미리 커밋해 둔 캐시가 리포트와 게이트를 바꾸고, 위조한
/// 원장 줄이 아티팩트에 실린다. 그래서 둘 다 러너 임시 디렉터리에 두고, 분석
/// 단계가 모두 복원한 같은 사실 캐시를 재사용하는지 확인한다(단계마다 cold 전체
/// 분석을 하지 않는다).
void main() {
  late List<YamlMap> steps;

  setUp(() {
    final document =
        loadYaml(
              File('.github/workflows/impact-precheck.yml').readAsStringSync(),
            )
            as YamlMap;
    final job = (document['jobs'] as YamlMap)['impact'] as YamlMap;
    steps = (job['steps'] as YamlList).cast<YamlMap>();
  });

  test('every impact step reuses one fact cache outside the workspace', () {
    final impactSteps = _impactSteps(steps);
    // 리포트·SARIF·게이트 세 단계가 모두 검사 대상인지 먼저 확인한다.
    expect({
      for (final step in impactSteps) ..._optionValues(step, '--format'),
    }, containsAll(['markdown', 'sarif', 'github-actions']));
    final directories = {
      for (final step in impactSteps) ..._optionValues(step, '--incremental'),
    };
    for (final step in impactSteps) {
      expect(
        _optionValues(step, '--incremental'),
        hasLength(1),
        reason: '${step['name']} runs a cold full analysis',
      );
    }
    expect(directories, hasLength(1));
    final directory = directories.single;
    expect(directory, startsWith(_runnerTempShell));

    // 그 디렉터리를 이벤트 조건 없이 복원·저장한다 — 조건이 있으면 그 밖의
    // 이벤트(workflow_dispatch 등)의 단계가 빈 캐시로 cold 분석을 한다.
    final restored = _shellToExpression(directory);
    final cacheSteps = [
      for (final step in steps)
        if (_uses(step, 'actions/cache@') && _paths(step).contains(restored))
          step,
    ];
    expect(
      cacheSteps,
      hasLength(1),
      reason: 'no cache step restores $restored',
    );
    expect(cacheSteps.single.containsKey('if'), isFalse);
  });

  test('the ledger is recorded and uploaded outside the workspace', () {
    final directories = [
      for (final step in _impactSteps(steps))
        ..._optionValues(step, '--record'),
    ];
    expect(directories, isNotEmpty);
    final uploaded = {
      for (final step in steps)
        if (_uses(step, 'actions/upload-artifact@')) ..._paths(step),
    };
    for (final directory in directories) {
      expect(directory, startsWith(_runnerTempShell));
      expect(
        uploaded,
        contains('${_shellToExpression(directory)}/ledger.jsonl'),
      );
    }
  });
}

/// run 본문에서 러너 임시 디렉터리를 가리키는 형태다(따옴표로 감싼 환경 변수).
const _runnerTempShell = r'"$RUNNER_TEMP/';

/// `with:`에서 같은 디렉터리를 가리키는 표현식 형태다.
const _runnerTempExpression = r'${{ runner.temp }}/';

/// `dartograph impact`를 실행하는 단계다.
List<YamlMap> _impactSteps(List<YamlMap> steps) => [
  for (final step in steps)
    if (step['run'] case final String run
        when run.contains('dartograph impact'))
      step,
];

/// [step]의 run 본문에서 [option] 바로 뒤에 오는 값들이다.
List<String> _optionValues(YamlMap step, String option) => [
  for (final match in RegExp(
    '${RegExp.escape(option)}\\s+(\\S+)',
  ).allMatches(step['run'] as String))
    match.group(1)!,
];

/// [step]이 [action] 접두사의 액션을 쓰는지 여부다.
bool _uses(YamlMap step, String action) => switch (step['uses']) {
  final String uses => uses.startsWith(action),
  _ => false,
};

/// [step]의 `with.path` 줄들이다(여러 경로는 줄마다 하나).
List<String> _paths(YamlMap step) => switch (step['with']) {
  {'path': final String path} => [
    for (final line in path.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ],
  _ => const [],
};

/// run 본문의 `"$RUNNER_TEMP/<dir>"`를 `with:`의 표현식 경로로 바꾼다.
String _shellToExpression(String shell) =>
    '$_runnerTempExpression'
    '${shell.substring(_runnerTempShell.length, shell.length - 1)}';
