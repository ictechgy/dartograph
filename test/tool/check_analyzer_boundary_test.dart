import 'dart:io';

import 'package:test/test.dart';

const _violation = "import 'package:analyzer/dart/element/element.dart';\n";

void main() {
  test('analyzer boundary check fails when its scanner fails', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'dartograph-boundary-test.',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    // 최상위 확인은 통과시키고(빈 prefix) grep만 실패시켜 스캐너 실패 경로를 본다.
    final fakeGit = File('${temporaryDirectory.path}/git');
    await fakeGit.writeAsString(
      '#!/usr/bin/env bash\n'
      'if [[ "\$1" == rev-parse ]]; then exit 0; fi\n'
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

    // 아직 추적하지 않은 깊은 경로, lib/ 바로 아래 파일, bin/의 위반도 잡는다.
    await repository.write('lib/src/analysis/deep/leak.dart', _violation);
    await repository.write('lib/top_level.dart', _violation);
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
        contains('lib/top_level.dart:1:'),
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
    await repository.write('lib/src/analysis/deep/leak.dart', _violation);
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
    await _git(parent.path, ['init', '--quiet']);
    await File('${parent.path}/.gitignore').writeAsString('pkg/\n');
    final package = Directory('${parent.path}/pkg');
    final repository = await _BoundaryRepository.create(
      directory: package,
      initialize: false,
    );
    await repository.write('lib/src/analysis/leak.dart', _violation);

    final result = await repository.scan();
    expect(result.exitCode, 2, reason: '${result.stdout}${result.stderr}');
    expect(result.stderr, contains('is not the top level of a Git work tree'));
  });

  test('a package outside any Git work tree fails closed', () async {
    final repository = await _BoundaryRepository.create(initialize: false);
    addTearDown(repository.delete);
    await repository.write('lib/leak.dart', _violation);

    // 임시 디렉터리 위쪽의 저장소를 찾지 않게 막는다.
    final result = await repository.scan(
      environment: {
        'GIT_CEILING_DIRECTORIES': repository.directory.parent.path,
      },
    );
    expect(result.exitCode, 2, reason: '${result.stdout}${result.stderr}');
    expect(result.stderr, contains('is not the top level of a Git work tree'));
  });

  test('the top-level check does not depend on how git prints paths', () async {
    // Git for Windows는 `--show-toplevel`을 `C:/…`로, MSYS bash의 `pwd -P`는
    // `/c/…`로 쓴다. 두 경로 문자열을 비교하면 정상 checkout도 2로 끝난다.
    // `--show-toplevel`만 Windows 형식으로 바꾸는 래퍼로 그 차이를 재현한다.
    final repository = await _BoundaryRepository.create();
    addTearDown(repository.delete);
    final shim = await Directory.systemTemp.createTemp(
      'dartograph-boundary-shim.',
    );
    addTearDown(() => shim.delete(recursive: true));
    final which = await Process.run('bash', ['-c', 'command -v git']);
    expect(which.exitCode, 0, reason: which.stderr as String);
    final realGit = (which.stdout as String).trim();
    final wrapper = File('${shim.path}/git');
    await wrapper.writeAsString(
      '#!/usr/bin/env bash\n'
      'if [[ "\$1" == rev-parse && "\$2" == --show-toplevel ]]; then\n'
      '  echo C:/Users/dev/checkout\n'
      '  exit 0\n'
      'fi\n'
      'exec "$realGit" "\$@"\n',
    );
    final chmod = await Process.run('chmod', ['+x', wrapper.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr as String);
    final environment = {
      'PATH': '${shim.path}:${Platform.environment['PATH']}',
    };

    final clean = await repository.scan(environment: environment);
    expect(clean.exitCode, 0, reason: '${clean.stdout}${clean.stderr}');
    await repository.write('lib/top_level.dart', _violation);
    final violated = await repository.scan(environment: environment);
    expect(violated.exitCode, 1, reason: '${violated.stdout}');
    expect(violated.stderr, contains('lib/top_level.dart:1:'));
  });

  test(
    'worktrees, symlinked paths, and submodules scan their own tree',
    () async {
      final repository = await _BoundaryRepository.create();
      addTearDown(repository.delete);
      await repository.commit();
      final layouts = await Directory.systemTemp.createTemp(
        'dartograph-boundary-layouts.',
      );
      addTearDown(() => layouts.delete(recursive: true));

      Future<void> expectScans(String root, String leak) async {
        final clean = await _scanAt(root);
        expect(clean.exitCode, 0, reason: '$root: ${clean.stderr}');
        await File('$root/$leak').writeAsString(_violation);
        final violated = await _scanAt(root);
        expect(violated.exitCode, 1, reason: '$root: ${violated.stderr}');
        expect(violated.stderr, contains('$leak:1:'));
      }

      // 연결된 worktree는 자기 최상위에서 검사한다.
      final worktree = '${layouts.path}/worktree';
      await _git(repository.directory.path, [
        'worktree',
        'add',
        '--quiet',
        worktree,
      ]);
      await expectScans(worktree, 'lib/worktree_leak.dart');

      // 심볼릭 링크를 거친 checkout 경로도 그 저장소의 최상위다.
      final linked = '${layouts.path}/linked';
      await Link(linked).create(repository.directory.path);
      await expectScans(linked, 'lib/linked_leak.dart');

      // 상위 저장소 안의 서브모듈 checkout은 자기 저장소의 최상위다.
      final superproject = Directory('${layouts.path}/super');
      await superproject.create();
      await _git(superproject.path, ['init', '--quiet']);
      await _git(superproject.path, [
        // 로컬 경로 서브모듈 복제는 최신 git에서 명시적 허용이 필요하다.
        '-c',
        'protocol.file.allow=always',
        'submodule',
        'add',
        '--quiet',
        repository.directory.path,
        'pkg',
      ]);
      await expectScans('${superproject.path}/pkg', 'lib/submodule_leak.dart');
    },
  );
}

/// [workingDirectory]에서 git을 실행하고 성공을 확인한다.
Future<void> _git(String workingDirectory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: workingDirectory,
  );
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
}

/// [root]를 현재 디렉터리로 경계 검사를 실행한다.
Future<ProcessResult> _scanAt(
  String root, {
  Map<String, String> environment = const {},
}) => Process.run(
  'bash',
  ['tool/check-analyzer-boundary.sh'],
  workingDirectory: root,
  environment: {...Platform.environment, ...environment},
);

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
      await _git(root.path, ['init', '--quiet']);
      await _git(root.path, ['add', '.']);
    }
    return repository;
  }

  /// 추적한 파일을 커밋한다. 사용자 git 설정(서명·훅)에 기대지 않는다.
  Future<void> commit() => _git(directory.path, [
    '-c',
    'user.name=dartograph-test',
    '-c',
    'user.email=dartograph-test@example.invalid',
    '-c',
    'commit.gpgsign=false',
    'commit',
    '--quiet',
    '--no-verify',
    '-m',
    'fixture',
  ]);

  /// 패키지 상대 경로에 파일을 쓴다.
  Future<void> write(String relative, String content) async {
    final file = File('${directory.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  /// 패키지 루트에서 경계 검사를 실행한다.
  Future<ProcessResult> scan({Map<String, String> environment = const {}}) =>
      _scanAt(directory.path, environment: environment);

  /// 임시 디렉터리를 지운다.
  Future<void> delete() => directory.delete(recursive: true);
}
