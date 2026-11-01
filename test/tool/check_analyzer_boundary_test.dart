import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('analyzer boundary check fails when its scanner fails', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'dartograph-boundary-test.',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final fakeGit = File('${temporaryDirectory.path}/git');
    await fakeGit.writeAsString('#!/usr/bin/env bash\nexit 128\n');
    final chmod = await Process.run('chmod', ['+x', fakeGit.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr as String);

    final result = await Process.run(
      'bash',
      ['tool/check-analyzer-boundary.sh'],
      environment: {
        ...Platform.environment,
        'PATH': '${temporaryDirectory.path}:/usr/bin:/bin',
      },
    );

    expect(result.exitCode, 2);
    expect(result.stderr, contains('Analyzer boundary scan failed'));
  });

  test('analyzer boundary check reports imports outside the index', () async {
    // 스크립트는 자기 위치의 상위를 저장소 루트로 본다. 임시 Git 저장소에 복사해
    // 실제 git grep이 추적·미추적 위반을 모두 잡고 index 안 import는 허용하는지 본다.
    final repository = await Directory.systemTemp.createTemp(
      'dartograph-boundary-repo.',
    );
    addTearDown(() => repository.delete(recursive: true));
    Future<void> write(String relative, String content) async {
      final file = File('${repository.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    await Directory('${repository.path}/tool').create();
    await File(
      'tool/check-analyzer-boundary.sh',
    ).copy('${repository.path}/tool/check-analyzer-boundary.sh');
    await write(
      'lib/src/index/adapter.dart',
      "import 'package:analyzer/dart/ast/ast.dart';\n",
    );
    await write('lib/src/core/model.dart', 'final model = 1;\n');
    final init = await Process.run('git', [
      'init',
      '--quiet',
    ], workingDirectory: repository.path);
    expect(init.exitCode, 0, reason: init.stderr as String);
    final add = await Process.run('git', [
      'add',
      '.',
    ], workingDirectory: repository.path);
    expect(add.exitCode, 0, reason: add.stderr as String);

    Future<ProcessResult> scan() => Process.run('bash', [
      'tool/check-analyzer-boundary.sh',
    ], workingDirectory: repository.path);

    final clean = await scan();
    expect(clean.exitCode, 0, reason: '${clean.stdout}${clean.stderr}');

    // 아직 추적하지 않은 깊은 경로와 bin/의 위반도 잡는다.
    await write(
      'lib/src/analysis/deep/leak.dart',
      "import 'package:analyzer/dart/element/element.dart';\n",
    );
    await write(
      'bin/tool.dart',
      "import 'package:analyzer/error/error.dart';\n",
    );
    final violated = await scan();
    expect(violated.exitCode, 1);
    expect(
      violated.stderr,
      allOf(
        contains('lib/src/analysis/deep/leak.dart:1:'),
        contains('bin/tool.dart:1:'),
        isNot(contains('lib/src/index/adapter.dart')),
      ),
    );
  });
}
