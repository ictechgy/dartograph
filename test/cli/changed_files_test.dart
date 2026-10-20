import 'dart:io';

import 'package:dartograph/src/cli/changed_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/hostile_git_support.dart';

void main() {
  test(
    'git output decoding folds non-UTF8 bytes into ChangedFilesException',
    () {
      // 비-UTF8 파일명은 Linux에서 가능하다(macOS APFS는 거부해 재현 불가) —
      // 순수 함수로 플랫폼 무관하게 고정한다.
      expect(
        () => decodeChangedFilesOutput(const [0x61, 0xff, 0x00]),
        throwsA(isA<ChangedFilesException>()),
      );
      expect(decodeChangedFilesOutput(const [0x61, 0x00, 0x62, 0x00]), [
        'a',
        'b',
      ]);
      expect(
        decodeChangedFilesOutput(const [
          0x61,
          0x0a,
          0x62,
          0x0a,
        ], nulSeparated: false),
        ['a', 'b'],
      );
    },
  );

  test(
    'since combines committed, worktree, staged, and NUL-safe untracked paths',
    () async {
      final repository = await Directory.systemTemp.createTemp(
        'changed-files.',
      );
      addTearDown(() => repository.delete(recursive: true));
      await _git(repository, ['init', '-q']);
      await _git(repository, ['config', 'user.email', 'test@example.invalid']);
      await _git(repository, ['config', 'user.name', 'Test']);
      File(
        p.join(repository.path, 'tracked.dart'),
      ).writeAsStringSync('initial');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-qm', 'initial']);
      final reference = (await _git(repository, ['rev-parse', 'HEAD'])).trim();

      File(
        p.join(repository.path, 'committed.dart'),
      ).writeAsStringSync('committed');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-qm', 'later']);
      File(
        p.join(repository.path, 'tracked.dart'),
      ).writeAsStringSync('worktree');
      File(p.join(repository.path, 'staged.dart')).writeAsStringSync('staged');
      await _git(repository, ['add', 'staged.dart']);
      const unusual = 'lib/한글\nfile.dart';
      final unusualFile = File(p.join(repository.path, unusual));
      unusualFile.parent.createSync(recursive: true);
      unusualFile.writeAsStringSync('untracked');

      final changed = await ChangedFiles.since(reference, repository.path);

      final root = await repository.resolveSymbolicLinks();
      expect(changed, {
        p.normalize(p.join(root, 'committed.dart')),
        p.normalize(p.join(root, 'staged.dart')),
        p.normalize(p.join(root, 'tracked.dart')),
        p.normalize(p.join(root, unusual)),
      });
    },
  );

  test('since resolves a reference before passing it to diff', () async {
    final repository = await Directory.systemTemp.createTemp(
      'changed-files-ref.',
    );
    addTearDown(() => repository.delete(recursive: true));
    await _git(repository, ['init', '-q']);
    await _git(repository, ['config', 'user.email', 'test@example.invalid']);
    await _git(repository, ['config', 'user.name', 'Test']);
    File(p.join(repository.path, 'tracked.dart')).writeAsStringSync('initial');
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-qm', 'initial']);

    await expectLater(
      ChangedFiles.since('--output=unexpected', repository.path),
      throwsA(isA<ChangedFilesException>()),
    );
    expect(
      File(p.join(repository.path, 'unexpected...HEAD')).existsSync(),
      isFalse,
    );
  });

  test(
    'since keeps repository-root paths when diff.relative is set and the package is nested',
    () async {
      final repository = await Directory.systemTemp.createTemp(
        'changed-files-relative.',
      );
      addTearDown(() => repository.delete(recursive: true));
      await _git(repository, ['init', '-q']);
      await _git(repository, ['config', 'user.email', 'test@example.invalid']);
      await _git(repository, ['config', 'user.name', 'Test']);
      // 패키지 루트를 저장소 루트 아래 하위 디렉터리에 둔다.
      final packageRoot = p.join(repository.path, 'package');
      final tracked = File(p.join(packageRoot, 'lib', 'tracked.dart'));
      tracked.createSync(recursive: true);
      tracked.writeAsStringSync('initial');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-qm', 'initial']);
      final reference = (await _git(repository, ['rev-parse', 'HEAD'])).trim();

      File(
        p.join(packageRoot, 'lib', 'committed.dart'),
      ).writeAsStringSync('committed');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-qm', 'later']);
      File(
        p.join(packageRoot, 'lib', 'staged.dart'),
      ).writeAsStringSync('staged');
      await _git(repository, ['add', 'package/lib/staged.dart']);
      // diff.relative=true면 cwd(패키지 루트) 기준 상대 경로로 출력이 바뀐다.
      await _git(repository, ['config', 'diff.relative', 'true']);

      final changed = await ChangedFiles.since(reference, packageRoot);

      final root = await repository.resolveSymbolicLinks();
      expect(changed, {
        p.normalize(p.join(root, 'package', 'lib', 'committed.dart')),
        p.normalize(p.join(root, 'package', 'lib', 'staged.dart')),
      });
    },
  );

  group('since in a repository whose git settings name commands', () {
    for (final setting in HostileGitSetting.values) {
      test(
        '${setting.name} runs nothing and still lists the edited file',
        () async {
          final workspace = await Directory.systemTemp.createTemp(
            'changed-files-hostile.',
          );
          addTearDown(() => workspace.delete(recursive: true));
          final repository = await createHostileRepository(workspace, setting);
          File(
            repository.path('lib/edited.dart'),
          ).writeAsStringSync('class Edited {\n  int value = 0;\n}\n');

          final changed = await ChangedFiles.since('HEAD', repository.root);

          expect(repository.commandRan, isFalse);
          expect(changed, {
            repository.path('lib/edited.dart'),
            // 내용은 그대로이고 stat만 낡은 파일도 변경으로 센다. git이 내용을
            // 다시 읽어 index를 새로 고치지 않기 때문이다(보수적 상위집합).
            repository.path('lib/fx.dart'),
          });
        },
        skip: Platform.isWindows
            ? 'the fixture plants POSIX sh scripts'
            : false,
      );
    }

    test(
      'an empty driver name is still disabled',
      () async {
        // `* filter=`는 이름이 빈 드라이버를 고르고 git은 `filter..clean`을 실행한다.
        final workspace = await Directory.systemTemp.createTemp(
          'changed-files-empty-driver.',
        );
        addTearDown(() => workspace.delete(recursive: true));
        final repository = await createRepositoryWithFilterName(
          workspace,
          const [],
        );

        final changed = await ChangedFiles.since('HEAD', repository.root);

        expect(repository.commandRan, isFalse);
        expect(changed, {repository.path('lib/fx.dart')});
      },
      skip: Platform.isWindows ? 'the fixture plants POSIX sh scripts' : false,
    );

    for (final (label, rawName) in [
      ("'='", 'a=b'.codeUnits),
      ('invalid UTF-8', const [0xff, 0xfe]),
    ]) {
      test(
        'a driver name with $label that git cannot be told to skip fails closed',
        () async {
          // git은 `-c` 값을 첫 `=`에서 나누고, 프로세스 인자는 UTF-8로만 넘어간다.
          final workspace = await Directory.systemTemp.createTemp(
            'changed-files-unsafe-driver.',
          );
          addTearDown(() => workspace.delete(recursive: true));
          final repository = await createRepositoryWithFilterName(
            workspace,
            rawName,
          );

          await expectLater(
            ChangedFiles.since('HEAD', repository.root),
            throwsA(isA<ChangedFilesException>()),
          );
          expect(repository.commandRan, isFalse);
        },
        skip: Platform.isWindows
            ? 'the fixture plants POSIX sh scripts'
            : false,
      );
    }
  });

  group('since in a partial clone', () {
    late Directory workspace;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp(
        'changed-files-partial.',
      );
    });
    tearDown(() => workspace.delete(recursive: true));

    for (final transport in PromisorTransport.values) {
      test('missing base history fails closed instead of being fetched '
          '(${transport.name})', () async {
        final repository = await createPartialCloneRepository(
          workspace,
          transport,
          MissingObject.baseCommit,
        );

        await expectLater(
          ChangedFiles.since('base', repository.root),
          throwsA(
            isA<ChangedFilesException>()
                .having((failure) => failure.partialClone, 'partial', isTrue)
                .having((failure) => failure.refusal, 'refusal', isNull),
          ),
        );
        expect(repository.commandRan, isFalse);
      }, skip: partialCloneSkip);

      test('a renamed file whose old blob is absent is listed by its new path '
          '(${transport.name})', () async {
        // blob 없는 클론의 흔한 모양이다. 이름 변경 감지만 옛 blob을 읽는다.
        final repository = await createPartialCloneRepository(
          workspace,
          transport,
          MissingObject.renamedFileBaseBlob,
        );

        final changed = await ChangedFiles.since('base', repository.root);

        expect(repository.commandRan, isFalse);
        expect(changed, {repository.path('lib/moved.dart')});
      }, skip: partialCloneSkip);

      test(
        'a staged rename whose HEAD blob is absent is listed by its new path '
        '(${transport.name})',
        () async {
          final repository = await createPartialCloneRepository(
            workspace,
            transport,
            MissingObject.stagedRenameHeadBlob,
          );

          final changed = await ChangedFiles.since('HEAD', repository.root);

          expect(repository.commandRan, isFalse);
          expect(changed, {repository.path('lib/staged.dart')});
        },
        skip: partialCloneSkip,
      );
    }
  });
}

Future<String> _git(Directory directory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: directory.path,
  );
  expect(result.exitCode, 0, reason: result.stderr as String);
  return result.stdout as String;
}
