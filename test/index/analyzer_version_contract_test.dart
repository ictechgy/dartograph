import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// `doc/DECISION-analyzer.md`가 element/AST 호환성을 직접 검증한 analyzer
/// 마이너 버전들이다.
///
/// analyzer는 major마다 element model과 AST에 breaking change가 있어서
/// index 어댑터는 이 집합에서만 검증됐다. 마이너를 추가하거나 major를 올리려면
/// 그 문서의 절차대로 API 표면을 다시 검증하고 이 상수들을 함께 갱신해야 한다.
const _validatedMajor = 14;
const _validatedMinors = {3, 4};

/// 검증 범위의 pubspec 제약 문자열이다. 위 major에서 도출해 제약과 집합이
/// 서로 어긋나지 않도록 단일 사실 출처를 유지한다.
// 하한은 집합의 최소 마이너에서 파생해 두 상수가 어긋나는 사고를 구조적으로
// 막는다. 집합과 doc/DECISION-analyzer.md 부록의 동기화는 검증 절차의 규율에
// 의존한다 — 이 테스트가 강제하지 않는 유일한 연결이다.
final _validatedConstraint =
    '>=$_validatedMajor.${_validatedMinors.reduce(min)}.0 '
    '<${_validatedMajor + 1}.0.0';

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
    final path = resolved!.toFilePath();
    // hosted 캐시의 `analyzer-X.Y.Z` 디렉터리 세그먼트만 대상으로 읽어
    // 경로 앞부분의 무관한 부분 문자열을 잡지 않는다.
    final segment = path
        .split(Platform.pathSeparator)
        .lastWhere((part) => part.startsWith('analyzer-'), orElse: () => '');
    final match = RegExp(r'^analyzer-(\d+)\.(\d+)\.(\d+)').firstMatch(segment);
    expect(match, isNotNull, reason: '해석된 analyzer 경로에서 버전을 읽지 못했다: $path');

    final major = int.parse(match!.group(1)!);
    final minor = int.parse(match.group(2)!);
    expect(major, _validatedMajor, reason: '설치된 analyzer의 major가 검증 범위 밖이다.');
    expect(
      _validatedMinors,
      contains(minor),
      reason:
          '설치된 analyzer 14.$minor는 검증 집합 $_validatedMinors 밖이다. '
          'doc/DECISION-analyzer.md 절차로 호환성을 다시 확인한다.',
    );
  });
}
