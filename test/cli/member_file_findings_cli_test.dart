import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 스캔 루트 밖 패키지(`--workspace` 멤버, `source_packages`)의 dead 파일 finding이
/// 그 파일의 실제 경로를 짚는지 실제 analyzer 색인으로 고정한다.
///
/// 수정 전에는 파일 finding의 source를 라이브러리 ID(`package:a/orphan.dart`)에서
/// 루트 패키지 규칙(`lib/<path>`)으로 만들었다. 그래서 `pkgs/a/lib/orphan.dart`가
/// `lib/orphan.dart`로 보고됐다(같은 실행의 선언 finding과 `query`는 실제 경로를
/// 실었다). 텍스트·GitHub Actions·SARIF 위치가 루트의 다른 파일을 가리켰고,
/// include/exclude glob과 `--since`도 그 잘못된 경로로 걸렀다.
void main() {
  late Directory root;

  Future<void> write(String relative, String content) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dartograph-member-files.');
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> pubGet() async {
    final result = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: root.path);
    expect(result.exitCode, 0, reason: result.stderr as String);
  }

  Future<({int code, String output, String error})> run(
    List<String> command,
  ) async {
    final output = StringBuffer();
    final error = StringBuffer();
    // 사용자 캐시를 쓰지 않는다(격리).
    final code = await runDartograph(
      [...command, root.path],
      output: output,
      error: error,
      userCacheEnvironment: const {},
    );
    return (code: code, output: output.toString(), error: error.toString());
  }

  /// `dead --format json`의 파일 finding ID와 source다.
  Future<Map<String, String>> fileSources(List<String> flags) async {
    final result = await run(['dead', ...flags, '--format', 'json']);
    expect(result.error, isEmpty);
    expect(result.code, 1);
    final document = jsonDecode(result.output) as Map<String, Object?>;
    final findings = (document['findings']! as List<Object?>)
        .cast<Map<String, Object?>>();
    return {
      for (final finding in findings)
        if (finding['kind'] == 'file')
          finding['id']! as String: finding['source']! as String,
    };
  }

  group('--workspace', () {
    /// 루트와 멤버 `pkgs/a`가 같은 이름의 고아 라이브러리 `lib/orphan.dart`를
    /// 가진 pub workspace를 만든다.
    Future<void> writeWorkspace() async {
      await write('pubspec.yaml', '''
name: ws_root
publish_to: none
environment:
  sdk: ^3.8.0
workspace:
  - pkgs/a
''');
      await write('lib/main.dart', 'void main() {}\n');
      await write('lib/orphan.dart', 'void rootOrphan() {}\n');
      await write('pkgs/a/pubspec.yaml', '''
name: a
publish_to: none
environment:
  sdk: ^3.8.0
resolution: workspace
''');
      await write('pkgs/a/bin/a.dart', 'void main() {}\n');
      await write('pkgs/a/lib/orphan.dart', 'void memberOrphan() {}\n');
      await pubGet();
    }

    test('a member file finding names the member file', () async {
      await writeWorkspace();

      expect(await fileSources(['--workspace']), {
        'package:a/orphan.dart': 'project:pkgs/a/lib/orphan.dart',
        'package:ws_root/orphan.dart': 'project:lib/orphan.dart',
      });
      final text = await run(['dead', '--workspace', '--format', 'text']);
      expect(
        text.output,
        contains(
          'pkgs/a/lib/orphan.dart: warning: file package:a/orphan.dart — ',
        ),
      );
      final actions = await run([
        'dead',
        '--workspace',
        '--format',
        'github-actions',
      ]);
      expect(
        actions.output,
        contains(
          '::warning file=pkgs/a/lib/orphan.dart,title=dartograph dead::'
          'file package:a/orphan.dart:',
        ),
      );
    });

    test('include/exclude globs match the member file path', () async {
      await writeWorkspace();
      await write('dartograph.yaml', 'exclude:\n  - "pkgs/**"\n');

      // 멤버 파일만 빠진다. 루트 파일은 남는다.
      expect(await fileSources(['--workspace']), {
        'package:ws_root/orphan.dart': 'project:lib/orphan.dart',
      });
    });

    test(
      'a public-libraries line rides only on its own package findings',
      () async {
        // 게시할 수 있는 루트와 멤버 pkgs/b, 게시하지 않는 멤버 apps/zeta다. 줄은 맨 위
        // limitations에 모두 남고, finding에는 자기 패키지의 줄만 붙는다. 수정 전에는
        // 모든 finding이 모든 패키지의 줄을 실었다(멤버 수 × finding 수로 커졌다).
        await write('pubspec.yaml', '''
name: ws_root
environment:
  sdk: ^3.8.0
workspace:
  - apps/zeta
  - pkgs/b
''');
        await write('lib/ws_root.dart', 'class Root {}\n');
        await write('lib/extra.dart', 'class RootExtra {}\n');
        await write('pkgs/b/pubspec.yaml', '''
name: b
environment:
  sdk: ^3.8.0
resolution: workspace
''');
        await write('pkgs/b/lib/b.dart', 'class B {}\n');
        await write('pkgs/b/lib/testing.dart', 'class FakeB {}\n');
        await write('apps/zeta/pubspec.yaml', '''
name: zeta
publish_to: none
environment:
  sdk: ^3.8.0
resolution: workspace
''');
        await write('apps/zeta/lib/extra.dart', 'class ZetaExtra {}\n');
        await pubGet();

        final result = await run(['dead', '--workspace', '--format', 'json']);
        expect(result.error, isEmpty);
        final document = jsonDecode(result.output) as Map<String, Object?>;
        const rootLine =
            'public-libraries: lib/extra.dart is a public library outside '
            'lib/ws_root.dart; its declarations are not retained as public API, '
            'so ones used only by package consumers are reported as unreachable '
            '(export it from lib/ws_root.dart or retain it with retained_files)';
        const memberLine =
            'public-libraries: pkgs/b/lib/testing.dart is a public library '
            'outside pkgs/b/lib/b.dart; its declarations are not retained as '
            'public API, so ones used only by package consumers are reported as '
            'unreachable (export it from pkgs/b/lib/b.dart or retain it with '
            'retained_files)';
        expect(
          document['limitations'],
          containsAll(<String>[rootLine, memberLine]),
        );
        final findings = (document['findings']! as List<Object?>)
            .cast<Map<String, Object?>>();
        expect(
          {
            for (final finding in findings)
              '${finding['kind']} ${finding['id']}': [
                for (final line in finding['limitations']! as List<Object?>)
                  if ((line! as String).startsWith('public-libraries:')) line,
              ],
          },
          {
            'declaration package:ws_root/extra.dart::RootExtra': [rootLine],
            'file package:ws_root/extra.dart': [rootLine],
            'declaration package:b/testing.dart::FakeB': [memberLine],
            'file package:b/testing.dart': [memberLine],
            // 게시하지 않는 멤버는 자기 줄이 없고 루트 줄도 받지 않는다.
            'declaration package:zeta/extra.dart::ZetaExtra': <String>[],
            'file package:zeta/extra.dart': <String>[],
          },
        );
      },
    );
  });

  test('a source_packages file finding names the local package file', () async {
    await write('pubspec.yaml', '''
name: app
publish_to: none
environment:
  sdk: ^3.8.0
dependencies:
  core:
    path: packages/core
''');
    await write(
      'lib/main.dart',
      "import 'package:core/used.dart';\n\nvoid main() => used();\n",
    );
    await write('lib/orphan.dart', 'void rootOrphan() {}\n');
    await write('packages/core/pubspec.yaml', '''
name: core
publish_to: none
environment:
  sdk: ^3.8.0
''');
    await write('packages/core/lib/used.dart', 'void used() {}\n');
    await write('packages/core/lib/orphan.dart', 'void coreOrphan() {}\n');
    await write('dartograph.yaml', 'source_packages:\n  - packages/core\n');
    await pubGet();

    expect(await fileSources(const []), {
      'package:app/orphan.dart': 'project:lib/orphan.dart',
      'package:core/orphan.dart': 'project:packages/core/lib/orphan.dart',
    });
  });
}
