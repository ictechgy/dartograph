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

  test('deps --kinds narrows the reported finding kinds', () async {
    final fixture = await copyFixture('dependency_audit');
    final output = StringBuffer();

    final status = await runDartograph([
      'deps',
      '--format',
      'json',
      '--kinds',
      'undeclared-dependency',
      fixture.path,
    ], output: output);

    expect(status, ExitStatus.findings.code);
    final findings =
        (jsonDecode(output.toString()) as Map<String, Object?>)['findings']!
            as List<Object?>;
    expect(
      findings.cast<Map<String, Object?>>().map((f) => f['kind']).toSet(),
      {'undeclared-dependency'},
    );

    final twoKinds = StringBuffer();
    expect(
      await runDartograph([
        'deps',
        '--format',
        'json',
        '--kinds',
        'unused-dependency,undeclared-dependency',
        fixture.path,
      ], output: twoKinds),
      ExitStatus.findings.code,
    );
    expect(
      (jsonDecode(twoKinds.toString()) as Map<String, Object?>)['findings']!
          as List<Object?>,
      hasLength(2),
    );

    final error = StringBuffer();
    expect(
      await runDartograph([
        'deps',
        '--kinds',
        'unused',
        'unused',
      ], error: error),
      ExitStatus.usage.code,
    );
    expect(error.toString(), contains('Unknown --kinds'));
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

  test('deps --workspace audits each member against its own pubspec', () async {
    final fixture = await copyFixture('workspace_audit');
    final output = StringBuffer();

    final status = await runDartograph([
      'deps',
      '--format',
      'json',
      '--workspace',
      fixture.path,
    ], output: output);

    expect(status, ExitStatus.findings.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    final findings = (document['findings']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final byKey = {
      for (final f in findings) '${f['manifest']}:${f['kind']}:${f['name']}': f,
    };

    // 각 발견은 자기 패키지의 pubspec에 귀속된다 — 루트 매니페스트를 멤버에
    // 적용하면 core·app의 선언이 전부 미선언으로 오판됐을 것이다.
    expect(byKey, hasLength(6));
    expect(
      byKey.containsKey('pubspec.yaml:unused-dependency:root_unused'),
      isTrue,
    );
    expect(
      byKey.containsKey('pubspec.yaml:undeclared-dependency:core'),
      isTrue,
      reason: 'root lib imports member core without declaring it',
    );
    expect(
      byKey.containsKey('pkgs/core/pubspec.yaml:unused-dependency:core_unused'),
      isTrue,
    );
    expect(
      byKey.containsKey('pkgs/core/pubspec.yaml:undeclared-dependency:ghost'),
      isTrue,
    );
    expect(
      byKey.containsKey('pkgs/app/pubspec.yaml:unused-dependency:app_unused'),
      isTrue,
    );
    final dev = byKey['pkgs/app/pubspec.yaml:dev-dependency-in-lib:app_dev'];
    expect(
      (dev?['sources']! as List<Object?>).cast<String>(),
      contains('project:pkgs/app/lib/app.dart'),
    );
    // 사용 중인 의존은 발견이 아니다 — shared_dep는 core가 쓰고 core는 app이 쓴다.
    expect(findings.where((f) => f['name'] == 'shared_dep'), isEmpty);
    expect(
      findings.where(
        (f) => f['name'] == 'core' && f['manifest'] != 'pubspec.yaml',
      ),
      isEmpty,
    );
    expect(
      (document['limitations']! as List<Object?>).cast<String>().any(
        (item) => item.startsWith('workspace-members-indexed:'),
      ),
      isTrue,
    );
  });

  test('deps without --workspace keeps the single-package contract', () async {
    final fixture = await copyFixture('workspace_audit');
    final output = StringBuffer();

    final status = await runDartograph([
      'deps',
      '--format',
      'json',
      fixture.path,
    ], output: output);

    expect(status, ExitStatus.findings.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    final findings = (document['findings']! as List<Object?>)
        .cast<Map<String, Object?>>();
    // 단일 패키지 실행은 manifest 키를 싣지 않고 멤버 선언을 감사하지 않는다.
    expect(findings.every((f) => !f.containsKey('manifest')), isTrue);
    expect(
      (document['limitations']! as List<Object?>).cast<String>().any(
        (item) => item.startsWith('workspace-members-not-indexed:'),
      ),
      isTrue,
    );
  });

  test(
    'deps --workspace fails the analysis without a workspace root',
    () async {
      final fixture = await copyFixture('dependency_audit');
      final output = StringBuffer();
      final error = StringBuffer();

      expect(
        await runDartograph(
          ['deps', '--workspace', fixture.path],
          output: output,
          error: error,
        ),
        ExitStatus.failure.code,
      );
      expect(
        await runDartograph(
          ['deps', '--workspace', '--workspace', fixture.path],
          output: output,
          error: error,
        ),
        ExitStatus.usage.code,
      );
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
