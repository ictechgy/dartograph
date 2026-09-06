import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// `doc/DECISION-analyzer.md`가 element/AST 호환성을 직접 검증한 analyzer 범위다.
///
/// analyzer는 major마다 element model과 AST에 breaking change가 있어서
/// index 어댑터는 이 범위에서만 검증됐다. 범위를 넓히거나 다른 버전으로 올리려면
/// 그 문서의 절차대로 API 표면을 다시 검증하고 이 상수를 함께 갱신해야 한다.
const _validatedMajor = 14;
const _validatedMinor = 3;
const _validatedConstraint = '>=14.3.0 <14.4.0';

void main() {
  test(
    'pubspec pins the analyzer range validated in DECISION-analyzer.md',
    () async {
      final pubspec =
          loadYaml(await File('pubspec.yaml').readAsString()) as YamlMap;
      final dependencies = pubspec['dependencies'] as YamlMap;

      expect(
        dependencies['analyzer'],
        _validatedConstraint,
        reason:
            'analyzer 제약을 바꾸려면 doc/DECISION-analyzer.md의 API 표면을 '
            '다시 검증하고 이 테스트의 상수를 함께 갱신한다.',
      );
    },
  );

  test('the resolved analyzer version is inside the validated range', () async {
    final resolved = await Isolate.resolvePackageUri(
      Uri.parse('package:analyzer/dart/element/element.dart'),
    );

    expect(resolved, isNotNull, reason: 'package:analyzer를 해석하지 못했다.');
    final match = RegExp(
      r'analyzer-(\d+)\.(\d+)\.(\d+)',
    ).firstMatch(resolved!.toFilePath());
    expect(
      match,
      isNotNull,
      reason: '해석된 analyzer 경로에서 버전을 읽지 못했다: ${resolved.toFilePath()}',
    );

    final major = int.parse(match!.group(1)!);
    final minor = int.parse(match.group(2)!);
    expect(
      (major, minor),
      (_validatedMajor, _validatedMinor),
      reason:
          '설치된 analyzer가 검증 범위 $_validatedConstraint 밖이다. '
          'doc/DECISION-analyzer.md 절차로 호환성을 다시 확인한다.',
    );
  });
}
