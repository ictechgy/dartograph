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
    tempDirectory = await Directory.systemTemp.createTemp('dartograph-deps.');
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

  test('deps reports hygiene findings with evidence and exit 1', () async {
    final fixture = await copyFixture('dependency_audit');
    final output = StringBuffer();

    final status = await runDartograph([
      'deps',
      '--format',
      'json',
      fixture.path,
    ], output: output);

    expect(status, ExitStatus.findings.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    expect(document['report'], 'deps');
    final findings = (document['findings']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final byName = {for (final f in findings) f['name']: f};

    expect(byName['declared_unused']?['kind'], 'unused-dependency');
    expect(byName['unused_dev']?['kind'], 'unused-dev-dependency');
    expect(byName['dev_pkg']?['kind'], 'dev-dependency-in-lib');
    expect(
      (byName['dev_pkg']?['sources']! as List).cast<String>(),
      contains('project:lib/main.dart'),
    );
    expect(byName['ghost_pkg']?['kind'], 'undeclared-dependency');
    // 사용 중·도구 계약(executables·build.yaml)은 발견이 아니다.
    expect(byName, isNot(contains('meta')));
    expect(byName, isNot(contains('tool_pkg')));
    expect(byName, isNot(contains('builder_pkg')));
    final limitations = (document['limitations']! as List<Object?>)
        .cast<String>();
    expect(
      limitations.any((item) => item.startsWith('package-usage:')),
      isTrue,
    );
  });

  test('deps exits 0 on a clean manifest and rejects bad usage', () async {
    final fixture = await copyFixture('closed_app');
    final output = StringBuffer();

    expect(
      await runDartograph(['deps', fixture.path], output: output),
      ExitStatus.success.code,
      reason: output.toString(),
    );
    expect(output.toString(), contains('deps: 0 finding(s)'));

    expect(
      await runDartograph(['deps', '--format', 'bogus', fixture.path]),
      ExitStatus.usage.code,
    );
    expect(await runDartograph(['deps']), ExitStatus.usage.code);
  });
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
