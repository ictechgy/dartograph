import 'package:dartograph/src/analysis/dependency_audit.dart';
import 'package:test/test.dart';

void main() {
  test('audit classifies each hygiene signal with evidence', () {
    final findings = DependencyAudit().audit(
      packageName: 'app',
      dependencies: const ['used', 'unused'],
      devDependencies: const ['dev_in_lib', 'unused_dev'],
      dependencyOverrides: const ['overridden'],
      packageImports: const {
        'used': ['project:lib/a.dart'],
        'dev_in_lib': ['project:lib/a.dart', 'project:test/a_test.dart'],
        'ghost': ['project:lib/b.dart'],
        'app': ['project:lib/self.dart'],
      },
      toolLike: const {'unused_tool'},
    );

    final byKey = {
      for (final finding in findings)
        '${finding.kind}:${finding.name}': finding,
    };
    expect(byKey.keys.toList(), [
      'dev-dependency-in-lib:dev_in_lib',
      'undeclared-dependency:ghost',
      'unused-dependency:unused',
      'unused-dev-dependency:unused_dev',
    ]);
    expect(byKey['dev-dependency-in-lib:dev_in_lib']!.sources, [
      'project:lib/a.dart',
    ], reason: 'test/ 안 참조는 발견 근거가 아니다');
    expect(byKey['undeclared-dependency:ghost']!.sources, [
      'project:lib/b.dart',
    ]);
    // 자기 패키지·override 선언·tool-like은 발견이 아니다.
    expect(findings.map((finding) => finding.name), isNot(contains('app')));
    expect(
      findings.map((finding) => finding.name),
      isNot(contains('overridden')),
    );
  });

  test('declared federated base exempts its platform imports', () {
    final findings = DependencyAudit().audit(
      packageName: 'app',
      dependencies: const ['url_launcher'],
      devDependencies: const [],
      dependencyOverrides: const [],
      packageImports: const {
        'url_launcher': ['project:lib/a.dart'],
        'url_launcher_android': ['project:lib/a.dart'],
        'url_launcher_platform_interface': ['project:lib/b.dart'],
      },
      toolLike: const {},
    );

    expect(findings, isEmpty);
  });

  test('tool-like declarations are not reported unused', () {
    final findings = DependencyAudit().audit(
      packageName: 'app',
      dependencies: const ['build_runner', 'some_lints'],
      devDependencies: const [],
      dependencyOverrides: const [],
      packageImports: const {},
      toolLike: const {'build_runner', 'some_lints'},
    );

    expect(findings, isEmpty);
  });
}
