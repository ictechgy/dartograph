import 'dart:io';

import 'package:dartograph/src/cli/changed_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
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
