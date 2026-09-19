import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// 루트 `action.yml` 합성 액션의 셸 경계를 고정한다.
///
/// `${{ }}`는 bash가 스크립트를 받기 전에 GitHub 러너가 확장한다 — `run:`
/// 본문 안에 입력 보간이 있으면 호출자가 넘긴 값이 셸 구문이 되는 스크립트
/// 인젝션 경로다. 입력은 `env:`로만 넘기고 본문은 `"$VAR"` 확장만 쓴다.
void main() {
  test('action.yml keeps expressions out of run script bodies', () {
    final document = loadYaml(File('action.yml').readAsStringSync());
    final steps = document['runs']['steps'] as YamlList;
    var shellSteps = 0;
    for (final step in steps) {
      final map = step as YamlMap;
      final run = map['run'];
      if (run is! String) continue;
      shellSteps++;
      expect(
        run,
        isNot(contains(r'${{')),
        reason: '${map['name']} interpolates an expression in run:',
      );
    }
    expect(shellSteps, greaterThan(0));
  });
}
