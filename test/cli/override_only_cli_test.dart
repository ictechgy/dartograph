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
      '${repositoryRoot.path}/fixtures/override_only_corpus',
    );
    fixture = await Directory.systemTemp.createTemp(
      'dartograph-override-only.',
    );
    await _copy(source, fixture);
  });

  tearDownAll(() => fixture.delete(recursive: true));

  Future<(int, Map<String, Object?>)> deadJson(List<String> extra) async {
    final output = StringBuffer();
    final status = await runDartograph([
      'dead',
      ...extra,
      '--format',
      'json',
      fixture.path,
    ], output: output);
    return (status, jsonDecode(output.toString()) as Map<String, Object?>);
  }

  List<Object?> idsOf(Map<String, Object?> document) =>
      (document['findings']! as List)
          .cast<Map<String, Object?>>()
          .map((finding) => finding['id'])
          .toList();

  const expected = [
    'project:lib/shapes.dart::Circle',
    'project:lib/shapes.dart::Circle.area',
    'project:lib/widgets.dart::OrphanValue',
    'project:lib/widgets.dart::OrphanValue.toString',
    'project:lib/widgets.dart::OrphanWidget',
    'project:lib/widgets.dart::OrphanWidget.build',
    'project:lib/widgets.dart::Widget',
    'project:lib/widgets.dart::Widget.build',
  ];

  test('default dead keeps every override member as a root', () async {
    final (status, document) = await deadJson(const ['--closed-app']);
    expect(status, ExitStatus.success.code);
    expect(idsOf(document), isEmpty);
    expect(document['report'], 'dead');
  });

  test(
    'override-only reports types kept alive only by their overrides',
    () async {
      for (final extra in const [
        ['--report-override-only'],
        ['--report-override-only', '--closed-app'],
      ]) {
        final (status, document) = await deadJson(extra);
        // info 리포트라 finding이 있어도 빌드를 실패시키지 않는다.
        expect(status, ExitStatus.success.code, reason: '$extra');
        expect(document['report'], 'override-only');
        // 인스턴스화되는 Square와 상위 Shape, pragma로 보존된 NativeHook은
        // 보고하지 않는다.
        expect(idsOf(document), expected, reason: '$extra');
        final findings = (document['findings']! as List)
            .cast<Map<String, Object?>>();
        expect(findings.map((finding) => finding['reason']).toSet(), {
          'retained only by override members of otherwise unreached types',
        });
        // 근거는 기본 분석에서 그 선언을 살린 재정의 루트 하나다.
        final circle = findings.firstWhere(
          (finding) => finding['id'] == 'project:lib/shapes.dart::Circle',
        );
        expect((circle['evidence']! as Map)['retentionRootsChecked'], [
          'project:lib/shapes.dart::Circle.area',
        ]);
      }
    },
  );

  test('a pragma on an override member outranks the override root', () async {
    final output = StringBuffer();
    expect(
      await runDartograph([
        'dead',
        '--explain',
        'project:lib/widgets.dart::NativeHook.toString',
        '--format',
        'json',
        fixture.path,
      ], output: output),
      ExitStatus.success.code,
    );
    expect(
      (jsonDecode(output.toString()) as Map)['retentionReason'],
      'vmEntryPoint',
    );
  });

  test('override-only renders at info severity', () async {
    final text = StringBuffer();
    expect(
      await runDartograph([
        'dead',
        '--report-override-only',
        '--format',
        'text',
        fixture.path,
      ], output: text),
      ExitStatus.success.code,
    );
    expect(text.toString(), contains(': info: declaration'));
    expect(text.toString(), contains('override-only: 8 finding(s)'));
    expect(text.toString(), isNot(contains('warning')));
  });

  test('override-only rejects conflicting report options', () async {
    for (final extra in const [
      ['--report-override-only', '--report-override-only'],
      ['--report-override-only', '--report-test-only'],
      ['--report-override-only', '--report-redundant-public'],
      ['--report-override-only', '--baseline', 'missing-baseline.json'],
      [
        '--report-override-only',
        '--explain',
        'project:lib/shapes.dart::Circle',
      ],
    ]) {
      expect(
        await runDartograph([
          'dead',
          ...extra,
          '--format',
          'json',
          fixture.path,
        ], error: StringBuffer()),
        ExitStatus.usage.code,
        reason: '$extra',
      );
    }
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
