import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  // dep-free 픽스처(relative import만)라 pub get이 필요 없다. 실제 analyzer가
  // 저장소 픽스처를 변경하지 않게 임시 디렉터리로 복사해 분석한다.
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
    fixture = await Directory.systemTemp.createTemp('dartograph-redundant.');
    await _copy(source, fixture);
  });

  tearDownAll(() => fixture.delete(recursive: true));

  test(
    'redundant public is info, exact, and does not fail the build',
    () async {
      final output = StringBuffer();
      expect(
        await runDartograph([
          'dead',
          '--report-redundant-public',
          '--format',
          'json',
          fixture.path,
        ], output: output),
        ExitStatus.success.code,
      );
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(document['report'], 'redundant-public');
      final findings = (document['findings']! as List)
          .cast<Map<String, Object?>>();
      // 같은 라이브러리 안에서만 쓰는 공개 헬퍼 하나. main이 쓰는
      // runInternal(다른 라이브러리 사용), 테스트가 쓰는 onlyReachedByTest,
      // 비공개 이름, 죽은 선언은 나오지 않는다.
      expect(findings.map((finding) => finding['id']), [
        'project:lib/internal_helpers.dart::internalScale',
      ]);
      expect(
        findings.single['reason'],
        'public but only referenced within its own library',
      );
      expect((findings.single['evidence'] as Map)['retentionRootsChecked'], []);
    },
  );

  test('redundant public renders info severity in text', () async {
    final output = StringBuffer();
    expect(
      await runDartograph([
        'dead',
        '--report-redundant-public',
        '--format',
        'text',
        fixture.path,
      ], output: output),
      ExitStatus.success.code,
    );
    expect(output.toString(), contains(': info: declaration'));
    expect(output.toString(), contains('redundant-public: 1 finding(s)'));
    expect(output.toString(), isNot(contains('warning')));
  });

  test('redundant public does not combine with other report modes', () async {
    // 둘 다 인덱싱 전에 usage(64)로 거부된다.
    expect(
      await runDartograph([
        'dead',
        '--report-redundant-public',
        '--report-test-only',
        '--format',
        'json',
        fixture.path,
      ], error: StringBuffer()),
      ExitStatus.usage.code,
    );
    expect(
      await runDartograph([
        'dead',
        '--report-redundant-public',
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
