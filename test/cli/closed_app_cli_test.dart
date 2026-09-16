import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  late Directory fixtureDirectory;

  setUpAll(() async {
    final libraryUri = await Isolate.resolvePackageUri(
      Uri.parse('package:dartograph/dartograph.dart'),
    );
    if (libraryUri == null) {
      throw StateError('Could not resolve the dartograph package root.');
    }
    final repositoryRoot = File.fromUri(libraryUri).parent.parent;
    fixtureDirectory = await Directory.systemTemp.createTemp(
      'dartograph-closed-app.',
    );
    await _copyTree(
      Directory('${repositoryRoot.path}/fixtures/closed_app'),
      fixtureDirectory,
    );
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: fixtureDirectory.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
  });

  tearDownAll(() => fixtureDirectory.delete(recursive: true));

  Future<Map<String, Object?>> deadJson(List<String> extra) async {
    final output = StringBuffer();
    final status = await runDartograph([
      'dead',
      '--format',
      'json',
      ...extra,
      fixtureDirectory.path,
    ], output: output);
    return {
      'status': status,
      'document': jsonDecode(output.toString()) as Map<String, Object?>,
    };
  }

  test('closed-app drops publicApi retention; library mode keeps it', () async {
    final open = await deadJson(const []);
    final openIds = ((open['document'] as Map)['findings']! as List)
        .cast<Map<String, Object?>>()
        .map((finding) => finding['id'])
        .join('\n');
    // 라이브러리 모드: 공개 API 보존 → PublicOnly는 발견이 아니다. 배럴 파일
    // 자체는 내부 import가 없어 dead-file로 남는다(기존 의미).
    expect(openIds, isNot(contains('PublicOnly')));
    expect(openIds, isNot(contains('public_api.dart')));
    expect(openIds, contains('closed_app_fixture.dart'));

    final closed = await deadJson(const ['--closed-app']);
    expect(closed['status'], ExitStatus.findings.code);
    final document = closed['document'] as Map<String, Object?>;
    final ids = (document['findings']! as List)
        .cast<Map<String, Object?>>()
        .map((finding) => finding['id'])
        .join('\n');
    expect(ids, contains('PublicOnly'));
    expect(ids, contains('public_api.dart'));
    // main이 참조하는 used()는 두 모드 모두 살아 있다.
    expect(ids, isNot(contains('used')));
    final limitations = (document['limitations']! as List<Object?>)
        .cast<String>();
    expect(limitations.any((item) => item.startsWith('closed-app:')), isTrue);
  });

  test('closed-app rejects contradictory report combinations', () async {
    final output = StringBuffer();
    expect(
      await runDartograph([
        'dead',
        '--report-redundant-public',
        '--format',
        'json',
        '--closed-app',
        fixtureDirectory.path,
      ], output: output),
      ExitStatus.usage.code,
    );
  });

  test(
    'duplicate valued options are usage errors, not silent last-wins',
    () async {
      for (final repeated in const [
        ['--format', 'json', '--format', 'text'],
        ['--baseline', 'a.json', '--baseline', 'b.json'],
        ['--since', 'HEAD~1', '--since', 'HEAD~2'],
        ['--codeowners', 'A', '--codeowners', 'B'],
        ['--explain', 'x', '--explain', 'y'],
      ]) {
        final output = StringBuffer();
        expect(
          await runDartograph(
            ['dead', ...repeated, fixtureDirectory.path],
            output: output,
            error: StringBuffer(),
          ),
          ExitStatus.usage.code,
          reason: 'repeated: $repeated',
        );
      }
    },
  );

  test(
    'baseline written with --closed-app suppresses closed-app findings',
    () async {
      final baselineFile = File(
        '${Directory.systemTemp.path}/dartograph-closed-baseline-${DateTime.now().microsecondsSinceEpoch}.json',
      );
      addTearDown(() async {
        if (baselineFile.existsSync()) await baselineFile.delete();
      });
      final writeOutput = StringBuffer();
      expect(
        await runDartograph([
          'baseline',
          '--write',
          baselineFile.path,
          '--closed-app',
          fixtureDirectory.path,
        ], output: writeOutput),
        ExitStatus.success.code,
      );

      final filtered = await deadJson([
        '--closed-app',
        '--baseline',
        baselineFile.path,
      ]);
      expect(filtered['status'], ExitStatus.success.code);
      final findings = (filtered['document'] as Map)['findings']! as List;
      expect(findings, isEmpty);
    },
  );
}

Future<void> _copyTree(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entity in source.list()) {
    final name = entity.path.split('/').last;
    if (name == '.dart_tool' || name == 'pubspec.lock' || name == '.omc') {
      continue;
    }
    if (entity is Directory) {
      await _copyTree(entity, Directory('${target.path}/$name'));
    } else if (entity is File) {
      await entity.copy('${target.path}/$name');
    }
  }
}
