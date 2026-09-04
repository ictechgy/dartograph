import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  late Directory corpusDirectory;

  setUpAll(() async {
    final libraryUri = await Isolate.resolvePackageUri(
      Uri.parse('package:dartograph/dartograph.dart'),
    );
    if (libraryUri == null) {
      throw StateError('Could not resolve the dartograph package root.');
    }
    final repositoryRoot = File.fromUri(libraryUri).parent.parent;
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

      expect(jsonDecode(preserved.toString()), containsPair('reachable', true));
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
