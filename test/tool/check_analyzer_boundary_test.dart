import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('analyzer boundary check fails when its scanner fails', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'dartograph-boundary-test.',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    // 최상위 확인은 통과시키고 grep만 실패시켜 스캐너 실패 경로를 본다.
    final fakeGit = File('${temporaryDirectory.path}/git');
    await fakeGit.writeAsString(
      '#!/usr/bin/env bash\n'
      'if [[ "\$1" == rev-parse ]]; then pwd -P; exit 0; fi\n'
      'exit 128\n',
    );
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
    expect(
      result.stderr,
      contains('Analyzer boundary scan failed: git grep exited 128'),
    );
  });

  test('analyzer boundary check reports imports outside the index', () async {
    // 스크립트는 자기 위치의 상위를 저장소 루트로 본다. 임시 Git 저장소에 복사해
    // 실제 git grep이 추적·미추적 위반을 모두 잡고 index 안 import는 허용하는지 본다.
    final repository = await _BoundaryRepository.create();
    addTearDown(repository.delete);

    final clean = await repository.scan();
    expect(clean.exitCode, 0, reason: '${clean.stdout}${clean.stderr}');

    // 아직 추적하지 않은 깊은 경로와 bin/의 위반도 잡는다.
    await repository.write(
      'lib/src/analysis/deep/leak.dart',
      "import 'package:analyzer/dart/element/element.dart';\n",
    );
    await repository.write(
      'bin/tool.dart',
      "import 'package:analyzer/error/error.dart';\n",
    );
    final violated = await repository.scan();
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

  test('pathspec environment variables do not hide violations', () async {
    // 사용자 환경의 pathspec 해석 변수는 `lib/*.dart`를 리터럴·glob 규칙으로
    // 바꿔 깊은 경로를 놓치게 할 수 있다. 스크립트는 그 영향을 받지 않아야 한다.
    final repository = await _BoundaryRepository.create();
    addTearDown(repository.delete);
    await repository.write(
      'lib/src/analysis/deep/leak.dart',
      "import 'package:analyzer/dart/element/element.dart';\n",
    );
    for (final variable in const [
      'GIT_GLOB_PATHSPECS',
      'GIT_LITERAL_PATHSPECS',
      'GIT_NOGLOB_PATHSPECS',
      'GIT_ICASE_PATHSPECS',
    ]) {
      final result = await repository.scan(environment: {variable: '1'});
      expect(result.exitCode, 1, reason: variable);
      expect(
        result.stderr,
        contains('lib/src/analysis/deep/leak.dart:1:'),
        reason: variable,
      );
    }
  });

  test('a package that is not the repository top level fails closed', () async {
    // 자기 .git이 없는 패키지가 그 경로를 무시하는 상위 저장소 안에 있으면 git grep은
    // 아무 파일도 보지 않는다. 통과(0) 대신 검사 실패(2)로 끝나야 한다.
    final parent = await Directory.systemTemp.createTemp(
      'dartograph-boundary-parent.',
    );
    addTearDown(() => parent.delete(recursive: true));
    expect(
      (await Process.run('git', [
        'init',
        '--quiet',
      ], workingDirectory: parent.path)).exitCode,
      0,
    );
    await File('${parent.path}/.gitignore').writeAsString('pkg/\n');
    final package = Directory('${parent.path}/pkg');
    final repository = await _BoundaryRepository.create(
      directory: package,
      initialize: false,
    );
    await repository.write(
      'lib/src/analysis/leak.dart',
      "import 'package:analyzer/dart/element/element.dart';\n",
    );

    final result = await repository.scan();
    expect(result.exitCode, 2, reason: '${result.stdout}${result.stderr}');
    expect(result.stderr, contains('Analyzer boundary scan failed'));
  });
}

/// 경계 검사 스크립트를 복사한 임시 패키지다.
final class _BoundaryRepository {
  _BoundaryRepository._(this.directory);

  /// 패키지 루트다.
  final Directory directory;

  /// [directory](기본은 새 임시 디렉터리)에 스크립트와 index 안 import를 둔다.
  /// [initialize]면 그 디렉터리를 Git 저장소로 만들고 파일을 추적한다.
  static Future<_BoundaryRepository> create({
    Directory? directory,
    bool initialize = true,
  }) async {
    final root =
        directory ??
        await Directory.systemTemp.createTemp('dartograph-boundary-repo.');
    final repository = _BoundaryRepository._(root);
    await Directory('${root.path}/tool').create(recursive: true);
    await File(
      'tool/check-analyzer-boundary.sh',
    ).copy('${root.path}/tool/check-analyzer-boundary.sh');
    await repository.write(
      'lib/src/index/adapter.dart',
      "import 'package:analyzer/dart/ast/ast.dart';\n",
    );
    await repository.write('lib/src/core/model.dart', 'final model = 1;\n');
    if (initialize) {
      for (final arguments in const [
        ['init', '--quiet'],
        ['add', '.'],
      ]) {
        final result = await Process.run(
          'git',
          arguments,
          workingDirectory: root.path,
        );
        expect(result.exitCode, 0, reason: result.stderr as String);
      }
    }
    return repository;
  }

  /// 패키지 상대 경로에 파일을 쓴다.
  Future<void> write(String relative, String content) async {
    final file = File('${directory.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  /// 패키지 루트에서 경계 검사를 실행한다.
  Future<ProcessResult> scan({Map<String, String> environment = const {}}) =>
      Process.run(
        'bash',
        ['tool/check-analyzer-boundary.sh'],
        workingDirectory: directory.path,
        environment: {...Platform.environment, ...environment},
      );

  /// 임시 디렉터리를 지운다.
  Future<void> delete() => directory.delete(recursive: true);
}
