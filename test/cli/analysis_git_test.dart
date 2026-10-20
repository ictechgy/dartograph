import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/analysis_git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/hostile_git_support.dart';

/// `git config -z --name-only --list` 출력처럼 키마다 NUL로 끝낸다.
List<int> _listing(List<String> keys) =>
    utf8.encode([for (final key in keys) '$key\u0000'].join());

Matcher _refused(AnalysisGitRefusal refusal) => throwsA(
  isA<AnalysisGitException>().having(
    (exception) => exception.refusal,
    'refusal',
    refusal,
  ),
);

void main() {
  group('parseFilterDriverNames', () {
    test('takes everything between filter. and the last key as the name', () {
      expect(
        parseFilterDriverNames(
          _listing([
            'core.bare',
            'filter.lfs.clean',
            'filter.lfs.smudge',
            'filter.lfs.process',
            'filter.lfs.required',
            'filter.evil.name.clean',
            'filter.My Driver.smudge',
            'filter..process',
          ]),
        ),
        // 정렬·중복 제거한다. 대소문자·공백·점·빈 이름을 그대로 둔다.
        ['', 'My Driver', 'evil.name', 'lfs'],
      );
    });

    test('ignores keys that do not name a driver command', () {
      expect(
        parseFilterDriverNames(
          _listing([
            'filter.clean',
            'filter.x.required',
            'filter.x.cleaner',
            'filterx.y.clean',
            'user.name',
          ]),
        ),
        isEmpty,
      );
    });

    test('ignores invalid UTF-8 in other sections', () {
      expect(
        parseFilterDriverNames([
          ...utf8.encode('user.'),
          0xff,
          ...utf8.encode('.name'),
          0,
        ]),
        isEmpty,
      );
    });

    for (final (label, key) in [
      ("'='", utf8.encode('filter.a=b.clean')),
      (
        'invalid UTF-8',
        [...utf8.encode('filter.'), 0xff, 0xfe, ...utf8.encode('.smudge')],
      ),
    ]) {
      test('refuses a driver name with $label', () {
        expect(
          () => parseFilterDriverNames([...key, 0]),
          _refused(AnalysisGitRefusal.unneutralizableFilterDriver),
        );
      });
    }
  });

  group('namesPromisorRemote', () {
    test('finds every key that makes git use a promisor remote', () {
      for (final key in [
        'extensions.partialclone',
        'remote.origin.promisor',
        'remote.a.b.partialclonefilter',
        // 서브섹션 없는 키도 git은 이름이 빈 promisor 원격으로 받는다.
        'remote.promisor',
      ]) {
        expect(
          namesPromisorRemote(_listing(['core.bare', key])),
          isTrue,
          reason: key,
        );
      }
    });

    test('ignores keys that do not make a promisor remote', () {
      expect(
        namesPromisorRemote(
          _listing([
            'remote.origin.url',
            'remote.origin.fetch',
            'remote.x.promisor.url',
            'remotes.x.promisor',
            'core.partialclonefilter',
            'extensions.partialclonex',
          ]),
        ),
        isFalse,
      );
    });
  });

  group('AnalysisGit.run', () {
    late Directory workspace;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('analysis-git.');
    });
    tearDown(() => workspace.delete(recursive: true));

    test(
      'returns the exit code and raw stdout of the query',
      () async {
        final repository = await createHostileRepository(
          workspace,
          HostileGitSetting.committedAttributes,
        );

        final head = await AnalysisGit.run(repository.root, const [
          'rev-parse',
          'HEAD',
        ]);
        final missing = await AnalysisGit.run(repository.root, const [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/missing',
        ]);

        expect(head.exitCode, 0);
        expect(utf8.decode(head.stdout), '${repository.head}\n');
        expect(head.partialClone, isFalse);
        expect(missing.exitCode, 1);
        expect(missing.stdout, isEmpty);
      },
      skip: Platform.isWindows ? 'the fixture plants POSIX sh scripts' : false,
    );

    for (final transport in PromisorTransport.values) {
      test(
        'does not fetch an object missing from a partial clone '
        '(${transport.name})',
        () async {
          final repository = await createPartialCloneRepository(
            workspace,
            transport,
            MissingObject.baseCommit,
          );

          final result = await AnalysisGit.run(repository.root, const [
            'rev-parse',
            '--verify',
            '--end-of-options',
            'base^{commit}',
          ]);

          expect(repository.commandRan, isFalse);
          expect(result.exitCode, isNot(0));
          expect(result.partialClone, isTrue);
        },
        skip: Platform.isWindows
            ? 'the fixture plants POSIX sh scripts'
            : false,
      );
    }

    test(
      'runs nothing in a partial clone when git cannot skip the fetch',
      () async {
        // 2.45 미만 git은 --no-lazy-fetch도 GIT_NO_LAZY_FETCH도 모른다.
        final oldGit = await createGitWithoutNoLazyFetch(workspace);
        final repository = await createPartialCloneRepository(
          workspace,
          PromisorTransport.uploadPack,
          MissingObject.baseCommit,
        );

        await expectLater(
          AnalysisGit.run(repository.root, const [
            'rev-parse',
            '--verify',
            '--end-of-options',
            'base^{commit}',
          ], executable: oldGit),
          _refused(AnalysisGitRefusal.unavoidableLazyFetch),
        );
        expect(repository.commandRan, isFalse);
      },
      skip: Platform.isWindows ? 'the fixture plants POSIX sh scripts' : false,
    );

    test(
      'still runs with that git outside a partial clone',
      () async {
        final oldGit = await createGitWithoutNoLazyFetch(workspace);
        final repository = await createHostileRepository(
          workspace,
          HostileGitSetting.committedAttributes,
        );

        final head = await AnalysisGit.run(repository.root, const [
          'rev-parse',
          'HEAD',
        ], executable: oldGit);

        expect(head.exitCode, 0);
        expect(utf8.decode(head.stdout), '${repository.head}\n');
        expect(repository.commandRan, isFalse);
      },
      skip: Platform.isWindows ? 'the fixture plants POSIX sh scripts' : false,
    );

    test(
      'runs nothing when the configuration cannot be read',
      () async {
        // 설정에 어떤 드라이버가 있는지 모르면 끌 수도 없다.
        final repository = await createHostileRepository(
          workspace,
          HostileGitSetting.committedAttributes,
        );
        File(
          p.join(repository.root, '.git', 'config'),
        ).writeAsStringSync('[filter\n', mode: FileMode.append);

        await expectLater(
          AnalysisGit.run(repository.root, const ['status', '--porcelain']),
          _refused(AnalysisGitRefusal.configurationUnreadable),
        );
        expect(repository.commandRan, isFalse);
      },
      skip: Platform.isWindows ? 'the fixture plants POSIX sh scripts' : false,
    );

    test(
      'runs nothing for a driver name that cannot be overridden',
      () async {
        final repository = await createRepositoryWithFilterName(
          workspace,
          'a=b'.codeUnits,
        );

        await expectLater(
          AnalysisGit.run(repository.root, const ['status', '--porcelain']),
          _refused(AnalysisGitRefusal.unneutralizableFilterDriver),
        );
        expect(repository.commandRan, isFalse);
      },
      skip: Platform.isWindows ? 'the fixture plants POSIX sh scripts' : false,
    );
  });
}
