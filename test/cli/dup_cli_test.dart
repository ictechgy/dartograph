import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  late Directory repositoryRoot;
  late Directory tempDirectory;

  setUpAll(() async {
    final libraryUri = await Isolate.resolvePackageUri(
      Uri.parse('package:dartograph/dartograph.dart'),
    );
    if (libraryUri == null) {
      throw StateError('Could not resolve the dartograph package root.');
    }
    repositoryRoot = File.fromUri(libraryUri).parent.parent;
    tempDirectory = await Directory.systemTemp.createTemp('dartograph-dup.');
  });

  tearDownAll(() => tempDirectory.delete(recursive: true));

  /// fixture를 임시 복사본으로 옮기고 offline pub get을 실행한다.
  Future<Directory> copyFixture(String name) async {
    final target = Directory(
      '${tempDirectory.path}/$name-${DateTime.now().microsecondsSinceEpoch}',
    );
    await _copyTree(Directory('${repositoryRoot.path}/fixtures/$name'), target);
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: target.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
    return target;
  }

  test(
    'dup reports token-identical blocks with locations and exit 1',
    () async {
      final fixture = await copyFixture('duplication');
      final output = StringBuffer();

      final status = await runDartograph([
        'dup',
        '--format',
        'json',
        '--min-tokens',
        '20',
        fixture.path,
      ], output: output);

      expect(status, ExitStatus.findings.code);
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(document['report'], 'dup');
      final findings = (document['findings']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(findings, hasLength(1));
      final finding = findings.single;
      expect(finding['kind'], 'duplicate-block');
      // 두 함수의 본문은 토큰 수십 개를 넘어 확장된다.
      expect(finding['tokenCount'] as int, greaterThan(50));
      final sources = [
        for (final instance in finding['instances']! as List<Object?>)
          (instance! as Map)['source'],
      ];
      expect(sources, ['project:lib/alpha.dart', 'project:lib/beta.dart']);
      // 스코프 한계가 보고에 남는다.
      expect(
        (document['limitations']! as List).join(' '),
        contains('duplication-scope'),
      );
    },
  );

  test('dup exits 0 when no window repeats', () async {
    final fixture = await copyFixture('duplication');
    final output = StringBuffer();

    // 두 함수가 공유하는 블록(약 80토큰)보다 큰 윈도는 반복을 만들지 않는다.
    final status = await runDartograph([
      'dup',
      '--min-tokens',
      '200',
      fixture.path,
    ], output: output);

    expect(status, ExitStatus.success.code);
    expect(output.toString(), contains('0 finding(s)'));
  });

  test('dup --format github-actions gates with workflow commands', () async {
    // 도움말·USAGE·MCP가 광고하는 철자다. enum 이름만 비교하던 파서는 이 값을
    // usage(64)로 거부했다.
    final fixture = await copyFixture('duplication');
    final findings = StringBuffer();
    expect(
      await runDartograph([
        'dup',
        '--format',
        'github-actions',
        '--min-tokens',
        '20',
        fixture.path,
      ], output: findings),
      ExitStatus.findings.code,
    );
    final lines = const LineSplitter().convert(findings.toString());
    expect(lines, everyElement(startsWith('::')));
    expect(lines, anyElement(startsWith('::warning file=lib/alpha.dart,')));
    // 문서 밖 enum 이름도 이전 릴리스부터 받아 온 값이라 같은 보고로 받는다.
    final legacy = StringBuffer();
    expect(
      await runDartograph([
        'dup',
        '--format',
        'githubActions',
        '--min-tokens',
        '20',
        fixture.path,
      ], output: legacy),
      ExitStatus.findings.code,
    );
    expect(legacy.toString(), findings.toString());

    final clean = StringBuffer();
    expect(
      await runDartograph([
        'dup',
        '--format',
        'github-actions',
        '--min-tokens',
        '200',
        fixture.path,
      ], output: clean),
      ExitStatus.success.code,
      reason: clean.toString(),
    );
    expect(clean.toString(), isNot(contains('::warning')));
  });

  test('dup rejects invalid and duplicate valued options', () async {
    final output = StringBuffer();
    final error = StringBuffer();

    final invalid = await runDartograph(
      ['dup', '--min-tokens', 'x', 'unused'],
      output: output,
      error: error,
    );
    expect(invalid, ExitStatus.usage.code);
    expect(error.toString(), contains('--min-tokens'));

    final duplicated = await runDartograph(
      ['dup', '--format', 'json', '--format', 'text', 'unused'],
      output: output,
      error: error,
    );
    expect(duplicated, ExitStatus.usage.code);

    final badKinds = await runDartograph(
      ['dup', '--kinds', 'declaration', 'unused'],
      output: output,
      error: error,
    );
    expect(badKinds, ExitStatus.usage.code);
    expect(error.toString(), contains('Unknown --kinds'));
  });

  test('dup --kinds keeps matching findings', () async {
    final fixture = await copyFixture('duplication');
    final output = StringBuffer();

    final status = await runDartograph([
      'dup',
      '--format',
      'json',
      '--min-tokens',
      '20',
      '--kinds',
      'duplicate-block',
      fixture.path,
    ], output: output);

    expect(status, ExitStatus.findings.code);
    final findings =
        (jsonDecode(output.toString()) as Map<String, Object?>)['findings']!
            as List<Object?>;
    expect(findings, hasLength(1));
  });
}

Future<void> _copyTree(Directory source, Directory target) async {
  await for (final entity in source.list(recursive: true)) {
    final relative = entity.path.substring(source.path.length + 1);
    if (relative.startsWith('.dart_tool')) continue;
    final destination = '${target.path}/$relative';
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
    }
  }
}
