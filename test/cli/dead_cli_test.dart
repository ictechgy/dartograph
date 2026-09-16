import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  late Directory repositoryRoot;
  late Directory corpusDirectory;

  setUpAll(() async {
    final libraryUri = await Isolate.resolvePackageUri(
      Uri.parse('package:dartograph/dartograph.dart'),
    );
    if (libraryUri == null) {
      throw StateError('Could not resolve the dartograph package root.');
    }
    repositoryRoot = File.fromUri(libraryUri).parent.parent;
    corpusDirectory = await Directory.systemTemp.createTemp(
      'dartograph-corpus.',
    );
    await _copyCorpus(
      Directory('${repositoryRoot.path}/fixtures/false_positive_corpus'),
      corpusDirectory,
    );
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: corpusDirectory.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
  });

  tearDownAll(() => corpusDirectory.delete(recursive: true));

  test('dead emits deterministic JSON findings for the corpus', () async {
    final first = StringBuffer();
    final second = StringBuffer();

    final firstStatus = await runDartograph([
      'dead',
      '--format',
      'json',
      corpusDirectory.path,
    ], output: first);
    final secondStatus = await runDartograph([
      'dead',
      '--format',
      'json',
      corpusDirectory.path,
    ], output: second);

    expect(firstStatus, ExitStatus.findings.code);
    expect(secondStatus, firstStatus);
    expect(second.toString(), first.toString());
    final document = jsonDecode(first.toString()) as Map<String, Object?>;
    final findings = document['findings']! as List<Object?>;
    final ids = findings
        .cast<Map<String, Object?>>()
        .map((finding) => finding['id'])
        .join('\n');
    expect(ids, contains('intentionallyDead'));
    expect(ids, contains('NotAnEntryPoint.main'));
    expect(ids, contains('falselyAnnotated'));
    expect(ids, contains('falsePragma'));
    expect(ids, contains('unused_file.dart'));
    expect(ids, isNot(contains('keptForTesting')));
    expect(ids, isNot(contains('nativeEntry')));
    expect(ids, isNot(contains('CorpusPluginLinux')));
    expect(ids, isNot(contains('CorpusWebPlugin')));
    expect(jsonEncode(findings), isNot(contains('delete')));
    final limitations = (document['limitations']! as List<Object?>)
        .cast<String>();
    expect(
      limitations,
      contains('generated declarations are conservative retention roots'),
    );
    expect(
      limitations,
      contains(
        'tests and visibleForTesting declarations are conservative retention roots',
      ),
    );
    expect(
      limitations,
      contains(
        'multiple declarations matched a plugin entry point; all were retained',
      ),
    );
  });

  test(
    'dead explain reports a preservation path or unreachable evidence',
    () async {
      final preserved = StringBuffer();
      final dead = StringBuffer();
      final memberRetained = StringBuffer();

      expect(
        await runDartograph([
          'dead',
          '--explain',
          'package:false_positive_corpus/main.dart::routeFactory',
          '--format',
          'json',
          corpusDirectory.path,
        ], output: preserved),
        ExitStatus.success.code,
      );
      expect(
        await runDartograph([
          'dead',
          '--explain',
          'package:false_positive_corpus/unused.dart::intentionallyDead',
          '--format',
          'json',
          corpusDirectory.path,
        ], output: dead),
        ExitStatus.findings.code,
      );

      // 멤버만 도달 가능한 컨테이너다. dead가 발견에서 제외하는 선언이므로
      // explain도 같은 결론과 종료 코드를 내야 한다. 계약은 종료 코드와
      // reachable까지이고, witness·reason 문구는 고정하지 않는다.
      expect(
        await runDartograph([
          'dead',
          '--explain',
          'package:false_positive_corpus/traits.dart::Decoration',
          '--format',
          'json',
          corpusDirectory.path,
        ], output: memberRetained),
        ExitStatus.success.code,
      );

      expect(jsonDecode(preserved.toString()), containsPair('reachable', true));
      expect(
        jsonDecode(memberRetained.toString()),
        containsPair('reachable', true),
      );
      expect(
        jsonDecode(preserved.toString()),
        containsPair('path', isNotEmpty),
      );
      expect(jsonDecode(dead.toString()), containsPair('reachable', false));
      expect(
        jsonDecode(dead.toString()),
        containsPair('reason', 'unreachable from all retention roots'),
      );
    },
  );

  test('dead --kinds narrows the reported finding kinds', () async {
    final filesOnly = StringBuffer();
    final declarationsOnly = StringBuffer();

    expect(
      await runDartograph([
        'dead',
        '--format',
        'json',
        '--kinds',
        'file',
        corpusDirectory.path,
      ], output: filesOnly),
      ExitStatus.findings.code,
    );
    expect(
      await runDartograph([
        'dead',
        '--format',
        'json',
        '--kinds',
        'declaration',
        corpusDirectory.path,
      ], output: declarationsOnly),
      ExitStatus.findings.code,
    );

    final fileKinds =
        (jsonDecode(filesOnly.toString()) as Map<String, Object?>)['findings']!
            as List<Object?>;
    expect(fileKinds, isNotEmpty);
    expect(
      fileKinds.cast<Map<String, Object?>>().map((f) => f['kind']).toSet(),
      {'file'},
    );
    final declarationKinds =
        (jsonDecode(declarationsOnly.toString())
                as Map<String, Object?>)['findings']!
            as List<Object?>;
    expect(declarationKinds, isNotEmpty);
    expect(
      declarationKinds
          .cast<Map<String, Object?>>()
          .map((f) => f['kind'])
          .toSet(),
      {'declaration'},
    );
  });

  test('dead rejects unknown kinds and --kinds with --explain', () async {
    final error = StringBuffer();

    expect(
      await runDartograph([
        'dead',
        '--format',
        'json',
        '--kinds',
        'bogus',
        'unused',
      ], error: error),
      ExitStatus.usage.code,
    );
    expect(error.toString(), contains('Unknown --kinds'));

    expect(
      await runDartograph([
        'dead',
        '--explain',
        'some::id',
        '--format',
        'json',
        '--kinds',
        'file',
        'unused',
      ]),
      ExitStatus.usage.code,
    );
  });

  test('dead honors dartograph.yaml include/exclude globs', () async {
    final fixture = await Directory.systemTemp.createTemp('dartograph-scope.');
    addTearDown(() => fixture.delete(recursive: true));
    await _copyCorpus(
      Directory('${repositoryRoot.path}/fixtures/closed_app'),
      fixture,
    );
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: fixture.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);

    // public_api.dart는 어떤 내부 참조도 없어 dead-file로 보고된다.
    final full = StringBuffer();
    expect(
      await runDartograph([
        'dead',
        '--format',
        'json',
        fixture.path,
      ], output: full),
      ExitStatus.findings.code,
    );
    final fullFindings =
        (jsonDecode(full.toString()) as Map<String, Object?>)['findings']!
            as List<Object?>;
    expect(
      fullFindings.join(' '),
      contains('closed_app_fixture/public_api.dart'),
    );

    await File('${fixture.path}/dartograph.yaml').writeAsString('''
exclude:
  - 'closed_app_fixture/public_api.dart'
''');
    final excluded = StringBuffer();
    await runDartograph([
      'dead',
      '--format',
      'json',
      fixture.path,
    ], output: excluded);
    final excludedDoc = jsonDecode(excluded.toString()) as Map<String, Object?>;
    // 발견의 id·source에 public_api.dart가 남지 않는다 — 다른 발견의 근거
    // (retentionRootsChecked)에 이름이 나타나는 것은 정당한 증거다.
    final excludedIds = [
      for (final finding
          in (excludedDoc['findings']! as List<Object?>)
              .cast<Map<String, Object?>>())
        '${finding['id']} ${finding['source']}',
    ].join(' ');
    expect(excludedIds, isNot(contains('public_api.dart')));
    expect(
      (excludedDoc['limitations']! as List<Object?>).join(' '),
      contains('include-exclude:'),
    );

    // include는 지정한 범위 밖 발견을 전부 거른다 — used.dart 밖의
    // 발견이 사라지므로 종료 코드가 0이 된다.
    await File('${fixture.path}/dartograph.yaml').writeAsString('''
include:
  - 'closed_app_fixture/used.dart'
''');
    final included = StringBuffer();
    final includedStatus = await runDartograph([
      'dead',
      '--format',
      'json',
      fixture.path,
    ], output: included);
    expect(includedStatus, ExitStatus.success.code);
    expect(
      (jsonDecode(included.toString()) as Map<String, Object?>)['findings']!
          as List<Object?>,
      isEmpty,
    );
  });
}

Future<void> _copyCorpus(Directory source, Directory destination) async {
  final canonicalSource = Directory(await source.resolveSymbolicLinks());
  await for (final entity in canonicalSource.list(
    recursive: true,
    followLinks: false,
  )) {
    final relativePath = entity.path.substring(canonicalSource.path.length + 1);
    if (relativePath.startsWith('.dart_tool/') ||
        relativePath == 'pubspec.lock') {
      continue;
    }
    final targetPath = '${destination.path}/$relativePath';
    if (entity is Directory) {
      await Directory(targetPath).create(recursive: true);
    } else if (entity is File) {
      await File(targetPath).parent.create(recursive: true);
      await entity.copy(targetPath);
    }
  }
}
