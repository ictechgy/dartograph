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
      'a public-libraries line reaches the findings it can explain',
      () async {
        // 루트 lib/testing.dart가 멤버 a의 src/ 함수를, 멤버 b의 testing.dart가 의존
        // 패키지 c의 src/ 함수를, 멤버 d의 testing.dart가 선언하지 않은 형제 e의 src/
        // 함수를 쓴다. 그 함수들은 그 공개 라이브러리 때문에 보고되므로 그 줄이 붙어야
        // 한다. 줄은 그 패키지와 그 패키지가 닿는 workspace 패키지(선언한 의존과 실제
        // import)의 finding에 붙고, 스캔 루트의 줄은 모든 finding에 붙는다
        // (origin/main과 같다). 관계없는 멤버 z와 게시하지 않는 멤버 zeta에는 루트
        // 줄만 붙는다. cf4f9ae는 자기 패키지의 줄만 붙여 원인 줄을 잃었다.
        await write('pubspec.yaml', '''
name: ws_root
environment:
  sdk: ^3.8.0
dependencies:
  a:
workspace:
  - apps/zeta
  - pkgs/a
  - pkgs/b
  - pkgs/c
  - pkgs/d
  - pkgs/e
  - pkgs/z
''');
        await write('lib/ws_root.dart', 'class Root {}\n');
        await write(
          'lib/testing.dart',
          "import 'package:a/src/impl.dart';\n\n"
              'class FakeRoot { void run() => implHelper(); }\n',
        );
        Future<void> member(
          String path,
          String name,
          Map<String, String> libraries, {
          String extra = '',
        }) async {
          await write(
            '$path/pubspec.yaml',
            'name: $name\n${extra}environment:\n  sdk: ^3.8.0\n'
                'resolution: workspace\n',
          );
          for (final MapEntry(:key, :value) in libraries.entries) {
            await write('$path/lib/$key', value);
          }
        }

        await member('pkgs/a', 'a', {
          'a.dart': 'class A {}\n',
          'extra.dart': 'class AExtra {}\n',
          'src/impl.dart': 'void implHelper() {}\n',
        });
        await member('pkgs/b', 'b', {
          'b.dart': 'class B {}\n',
          'testing.dart':
              "import 'package:c/src/cimpl.dart';\n\n"
              'class FakeB { void run() => cHelper(); }\n',
        }, extra: 'dependencies:\n  c:\n');
        await member('pkgs/c', 'c', {
          'c.dart': 'class C {}\n',
          'src/cimpl.dart': 'void cHelper() {}\n',
        });
        // d는 e를 pubspec에 선언하지 않고 import한다(workspace에서는 해석된다).
        await member('pkgs/d', 'd', {
          'd.dart': 'class D {}\n',
          'testing.dart':
              "import 'package:e/src/eimpl.dart';\n\n"
              'class FakeD { void run() => eHelper(); }\n',
        });
        await member('pkgs/e', 'e', {
          'e.dart': 'class E {}\n',
          'src/eimpl.dart': 'void eHelper() {}\n',
        });
        await member('pkgs/z', 'z', {
          'z.dart': 'class Z {}\n',
          'src/orphan.dart': 'void zOrphan() {}\n',
        });
        await member('apps/zeta', 'zeta', {
          'extra.dart': 'class ZetaExtra {}\n',
        }, extra: 'publish_to: none\n');
        await pubGet();

        final result = await run(['dead', '--workspace', '--format', 'json']);
        expect(result.error, isEmpty);
        final document = jsonDecode(result.output) as Map<String, Object?>;
        String line(String library, String entry) =>
            'public-libraries: $library is a public library outside $entry; '
            'its declarations are not retained as public API, so ones used '
            'only by package consumers are reported as unreachable (export it '
            'from $entry or retain it with retained_files)';
        final root = line('lib/testing.dart', 'lib/ws_root.dart');
        final a = line('pkgs/a/lib/extra.dart', 'pkgs/a/lib/a.dart');
        final b = line('pkgs/b/lib/testing.dart', 'pkgs/b/lib/b.dart');
        final d = line('pkgs/d/lib/testing.dart', 'pkgs/d/lib/d.dart');
        expect(document['limitations'], containsAll(<String>[root, a, b, d]));
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
            'declaration package:ws_root/testing.dart::FakeRoot': [root],
            'declaration package:ws_root/testing.dart::FakeRoot.run': [root],
            'file package:ws_root/testing.dart': [root],
            // 루트 testing.dart만 쓰는 a의 함수: 원인인 루트 줄과 a 자신의 줄.
            'declaration package:a/src/impl.dart::implHelper': [root, a],
            'file package:a/src/impl.dart': [root, a],
            'declaration package:a/extra.dart::AExtra': [root, a],
            'file package:a/extra.dart': [root, a],
            'declaration package:b/testing.dart::FakeB': [root, b],
            'declaration package:b/testing.dart::FakeB.run': [root, b],
            'file package:b/testing.dart': [root, b],
            // b가 선언한 의존 c의 함수.
            'declaration package:c/src/cimpl.dart::cHelper': [root, b],
            'file package:c/src/cimpl.dart': [root, b],
            'declaration package:d/testing.dart::FakeD': [root, d],
            'declaration package:d/testing.dart::FakeD.run': [root, d],
            'file package:d/testing.dart': [root, d],
            // d가 선언 없이 import한 e의 함수.
            'declaration package:e/src/eimpl.dart::eHelper': [root, d],
            'file package:e/src/eimpl.dart': [root, d],
            'declaration package:z/src/orphan.dart::zOrphan': [root],
            'file package:z/src/orphan.dart': [root],
            'declaration package:zeta/extra.dart::ZetaExtra': [root],
            'file package:zeta/extra.dart': [root],
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
