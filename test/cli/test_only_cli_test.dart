import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  // dep-free 픽스처(relative import만)라 pub get이 필요 없다. 실제 analyzer가
  // 저장소 픽스처를 변경하지 않게 임시 디렉터리로 복사해 분석한다(PR #17 교훈).
  late Directory fixture;

  setUpAll(() async {
    final libraryUri = await Isolate.resolvePackageUri(
      Uri.parse('package:dartograph/dartograph.dart'),
    );
    if (libraryUri == null) {
      throw StateError('Could not resolve the dartograph package root.');
    }
    final repositoryRoot = File.fromUri(libraryUri).parent.parent;
    final source = Directory(
      '${repositoryRoot.path}/fixtures/test_only_corpus',
    );
    fixture = await Directory.systemTemp.createTemp('dartograph-test-only.');
    await _copy(source, fixture);
  });

  tearDownAll(() => fixture.delete(recursive: true));

  List<Object?> idsOf(String json) =>
      ((jsonDecode(json) as Map)['findings'] as List)
          .cast<Map<String, Object?>>()
          .map((finding) => finding['id'])
          .toList();

  test('test-only reachability is info and does not fail the build', () async {
    // 일반 dead는 테스트가 도달하는 onlyReachedByTest를 죽었다고 보지 않는다.
    final normal = StringBuffer();
    expect(
      await runDartograph([
        'dead',
        '--format',
        'json',
        fixture.path,
      ], output: normal),
      ExitStatus.findings.code,
    );
    expect(
      idsOf(normal.toString()),
      contains('project:lib/prod.dart::deadEverywhere'),
    );
    expect(
      idsOf(normal.toString()),
      isNot(contains('project:lib/prod.dart::onlyReachedByTest')),
    );

    // --report-test-only는 onlyReachedByTest만 info로 내고 빌드를 깨지 않는다.
    final testOnly = StringBuffer();
    expect(
      await runDartograph([
        'dead',
        '--report-test-only',
        '--format',
        'json',
        fixture.path,
      ], output: testOnly),
      ExitStatus.success.code,
    );
    final document = jsonDecode(testOnly.toString()) as Map<String, Object?>;
    final findings = (document['findings']! as List)
        .cast<Map<String, Object?>>();
    expect(findings.map((finding) => finding['id']), [
      'project:lib/prod.dart::onlyReachedByTest',
    ]);
    expect(findings.single['reason'], 'reached only from test code');
    // 근거는 실제 analyzer가 만든 project:test/ 루트다(접두어 계약 고정).
    expect((findings.single['evidence'] as Map)['retentionRootsChecked'], [
      'project:test/prod_test.dart::main',
    ]);
  });

  test('test-only report renders info severity, never warning', () async {
    final text = StringBuffer();
    expect(
      await runDartograph([
        'dead',
        '--report-test-only',
        '--format',
        'text',
        fixture.path,
      ], output: text),
      ExitStatus.success.code,
    );
    expect(text.toString(), contains(': info: declaration'));
    expect(text.toString(), contains('test-only: 1 finding(s)'));
    expect(text.toString(), isNot(contains('warning')));
  });

  test('test-only does not combine with --explain or --baseline', () async {
    // 둘 다 인덱싱 전에 usage(64)로 거부된다.
    expect(
      await runDartograph([
        'dead',
        '--report-test-only',
        '--explain',
        'project:lib/prod.dart::onlyReachedByTest',
        '--format',
        'json',
        fixture.path,
      ], error: StringBuffer()),
      ExitStatus.usage.code,
    );
    expect(
      await runDartograph([
        'dead',
        '--report-test-only',
        '--baseline',
        'missing-baseline.json',
        '--format',
        'json',
        fixture.path,
      ], error: StringBuffer()),
      ExitStatus.usage.code,
    );
  });
}

Future<void> _copy(Directory source, Directory destination) async {
  final canonical = Directory(await source.resolveSymbolicLinks());
  await for (final entity in canonical.list(
    recursive: true,
    followLinks: false,
  )) {
    final relative = entity.path.substring(canonical.path.length + 1);
    if (relative.startsWith('.dart_tool/') || relative == 'pubspec.lock') {
      continue;
    }
    final target = '${destination.path}/$relative';
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      await File(target).parent.create(recursive: true);
      await entity.copy(target);
    }
  }
}
