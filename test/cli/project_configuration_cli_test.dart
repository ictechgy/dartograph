import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 프로젝트 설정 오류가 고칠 파일과 키를 짚는 진단과 종료 2로 끝나는지 실제
/// analyzer 색인으로 고정한다.
///
/// 수정 전에는 `dartograph.yaml`·`pubspec.yaml`·`--workspace`의 오류가 모든 그래프
/// 명령에서 `Analysis failed: unable to index the package.`로만 보였다(#160과 같은
/// 문구). `impact`는 `--symbol`·올바른 `--changed`에도 'Invalid changed list'와
/// 종료 64로, `schema`·`routes`는 '제어문자 포함'으로 원인을 반대로 짚었다.
void main() {
  late Directory root;

  Future<void> write(String relative, String content) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dartograph-config-cli.');
    // pub get 없이 해석되는 최소 패키지다.
    await write(
      'pubspec.yaml',
      'name: config_app\npublish_to: none\nenvironment:\n  sdk: ^3.0.0\n',
    );
    await write('lib/config_app.dart', 'void run() {}\n');
  });
  tearDown(() => root.delete(recursive: true));

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

  /// [command]가 출력 없이 종료 2와 진단 [diagnostic] 한 줄로 끝나는지 본다.
  Future<void> expectDiagnostic(List<String> command, String diagnostic) async {
    final result = await run(command);
    final reason = '${command.join(' ')}: ${result.error}';
    expect(result.code, ExitStatus.failure.code, reason: reason);
    expect(result.output, isEmpty, reason: reason);
    expect(result.error, '$diagnostic\n', reason: reason);
  }

  test('an invalid dartograph.yaml value is named by every graph command, '
      'impact included', () async {
    await write('dartograph.yaml', 'entry_points:\n  - bin/missing.dart\n');
    // 형식이 올바른 변경 목록이다. 수정 전에는 이 목록이 잘못됐다고 답했다.
    final changed = File(p.join(root.path, 'changed.json'))
      ..writeAsStringSync('["lib/config_app.dart"]');
    const diagnostic =
        'Analysis failed: invalid dartograph.yaml: entry_points file does not '
        'exist: bin/missing.dart';

    for (final command in [
      ['cycles', '--strict'],
      ['dead', '--format', 'text'],
      ['graph', '--format', 'json'],
      ['query', 'run'],
      ['impact', '--symbol', 'project:lib/config_app.dart::run'],
      ['impact', '--changed', changed.path],
      // --before도 같은 바깥 분기 때문에 64였다.
      ['impact', '--before', root.path],
    ]) {
      await expectDiagnostic(command, diagnostic);
    }
  });

  test('a YAML syntax error in dartograph.yaml carries its position', () async {
    await write('dartograph.yaml', 'entry_points: [\n');

    final result = await run(['cycles', '--strict']);

    expect(result.code, ExitStatus.failure.code);
    expect(result.output, isEmpty);
    expect(
      result.error,
      allOf(
        startsWith('Analysis failed: invalid dartograph.yaml: '),
        endsWith(' (line 2, column 1)\n'),
      ),
    );
  });

  test(
    'configuration values are echoed with control characters escaped',
    () async {
      // 저장소가 쓴 값이 둘째 진단줄을 위조하거나 ANSI 시퀀스를 넣지 못한다.
      // YAML 큰따옴표 문자열의 `\e`는 ESC, `\n`은 개행이다.
      await write(
        'dartograph.yaml',
        'entry_points:\n  - "bin/\\e[31mx\\ny.dart"\n',
      );

      await expectDiagnostic(
        ['cycles'],
        r'Analysis failed: invalid dartograph.yaml: entry_points file does not '
        r'exist: bin/\x1b[31mx\ny.dart',
      );
    },
  );

  test('--workspace on a root that declares no members says so', () async {
    const diagnostic =
        'Analysis failed: --workspace requires a pub workspace root: '
        'pubspec.yaml declares no workspace members';

    for (final command in [
      ['cycles', '--workspace'],
      ['impact', '--workspace', '--symbol', 'project:lib/config_app.dart::run'],
      ['runtime', '--workspace'],
    ]) {
      await expectDiagnostic(command, diagnostic);
    }
  });

  test('an invalid pubspec package name is named', () async {
    await write(
      'pubspec.yaml',
      'name: config-app\npublish_to: none\nenvironment:\n  sdk: ^3.0.0\n',
    );

    await expectDiagnostic(
      ['cycles', '--strict'],
      'Analysis failed: invalid pubspec.yaml: name must be a valid package name',
    );
  });

  test('schema and routes report source_packages errors, not control '
      'characters', () async {
    // source_packages는 package config가 있어야 항목 검증까지 간다.
    await write(
      '.dart_tool/package_config.json',
      '{"configVersion": 2, "packages": []}',
    );
    await write('dartograph.yaml', 'source_packages:\n  - ../outside\n');
    // 두 명령은 사실이 난 파일만 해석하므로, 그래프 신원을 찾게 할 사실을 둔다.
    await write('lib/repo.dart', '''
import 'package:sqflite/sqflite.dart';
import 'package:http/http.dart' as http;

void run(Database db) => db.rawQuery('SELECT * FROM users');
Future<void> fetch() => http.get(Uri.parse('https://api.example.test/a'));
''');
    const diagnostic =
        'Analysis failed: invalid dartograph.yaml: source_packages must be '
        'project-relative paths: ../outside';

    await expectDiagnostic(['schema', '--format', 'json'], diagnostic);
    await expectDiagnostic(['routes', '--role', 'client'], diagnostic);
  });
  group('workspace declarations', () {
    test('a malformed root pubspec is named, not reported as missing '
        'members', () async {
      // 수정 전에는 YAML 오류를 삼키고 '멤버 선언 없음'으로 답했다.
      await write('pubspec.yaml', 'name: config_app\nenvironment: [\n');

      for (final command in [
        ['cycles', '--workspace'],
        ['runtime', '--workspace'],
      ]) {
        final result = await run(command);
        expect(result.code, ExitStatus.failure.code, reason: result.error);
        expect(
          result.error,
          allOf(
            startsWith('Analysis failed: invalid pubspec.yaml: '),
            endsWith(' (line 3, column 1)\n'),
          ),
        );
      }
    });

    test('a root without pubspec.yaml says so', () async {
      await File(p.join(root.path, 'pubspec.yaml')).delete();

      await expectDiagnostic(
        ['cycles', '--workspace'],
        'Analysis failed: --workspace requires a pub workspace root: the '
        'package root has no pubspec.yaml',
      );
    });

    test('members that are all skipped or misnamed are named', () async {
      await write(
        'pubspec.yaml',
        'name: config_app\npublish_to: none\nworkspace:\n  - pkgs/missing\n',
      );
      await expectDiagnostic(
        ['cycles', '--workspace'],
        'Analysis failed: --workspace resolved no members: every declared '
        'workspace entry was skipped (pkgs/missing)',
      );

      await write(
        'pubspec.yaml',
        'name: config_app\npublish_to: none\nworkspace:\n  - pkgs/a\n',
      );
      await write('pkgs/a/pubspec.yaml', 'name: a-b\nresolution: workspace\n');
      await expectDiagnostic(
        ['cycles', '--workspace'],
        'Analysis failed: workspace member pubspec name must be a valid '
        'package name: pkgs/a',
      );

      await write('pkgs/a/pubspec.yaml', 'name: a\nenvironment: [\n');
      final result = await run(['cycles', '--workspace']);
      expect(result.code, ExitStatus.failure.code);
      expect(
        result.error,
        allOf(
          startsWith('Analysis failed: invalid pkgs/a/pubspec.yaml: '),
          endsWith(' (line 3, column 1)\n'),
        ),
      );
    });
  });

  group('source_packages inputs name the file at fault', () {
    /// `vendor/local` source package와 [packageConfig] 내용의 package config를 둔다.
    Future<void> sourcePackage(String packageConfig) async {
      await write('vendor/local/pubspec.yaml', 'name: local\n');
      await write('vendor/local/lib/local.dart', 'void local() {}\n');
      await write('.dart_tool/package_config.json', packageConfig);
      await write('dartograph.yaml', 'source_packages:\n  - vendor/local\n');
    }

    const localEntry =
        '{"name": "local", "rootUri": "../vendor/local/", "packageUri": "lib/"}';

    test('a malformed source package pubspec points at that pubspec', () async {
      await sourcePackage('{"configVersion": 2, "packages": [$localEntry]}');
      await write('vendor/local/pubspec.yaml', 'name: local\nenvironment: [\n');

      final result = await run(['cycles']);

      // 줄·열은 dartograph.yaml이 아니라 이 pubspec의 위치다.
      expect(result.code, ExitStatus.failure.code);
      expect(
        result.error,
        allOf(
          startsWith('Analysis failed: invalid vendor/local/pubspec.yaml: '),
          endsWith(' (line 3, column 1)\n'),
        ),
      );
    });

    test('a device in place of the package config keeps the read-boundary '
        'diagnostic', () async {
      await sourcePackage('{}');
      await File(
        p.join(root.path, '.dart_tool', 'package_config.json'),
      ).delete();
      await Link(
        p.join(root.path, '.dart_tool', 'package_config.json'),
      ).create('/dev/null');

      await expectDiagnostic(
        ['cycles'],
        'Analysis failed: an input is not a regular file (device, FIFO, or '
        'socket). Point the symbolic link or import at a regular file, or '
        'remove it.',
      );
    }, skip: Platform.isWindows);

    test('package config problems name the package config', () async {
      const config = 'Analysis failed: invalid .dart_tool/package_config.json:';

      await sourcePackage(
        '{"configVersion": 2, "packages": '
        '[{"name": "x", "rootUri": "http://[::1"}]}',
      );
      await expectDiagnostic([
        'cycles',
      ], '$config rootUri is not a valid URI: http://[::1');

      await sourcePackage('{"configVersion": 2, "packages": {}}');
      await expectDiagnostic(['cycles'], '$config packages must be a list');

      await sourcePackage('{not json');
      final result = await run(['cycles']);
      expect(result.code, ExitStatus.failure.code);
      expect(result.error, startsWith('$config '));
      expect(result.error, isNot(contains('dartograph.yaml')));
    });

    test('a package config over 16 MiB is named with its limit', () async {
      await sourcePackage('');
      // 내용 없이 길이만 늘린 파일이다(디스크를 쓰지 않는다). 상한 검사가 내용보다 먼저다.
      File(
          p.join(root.path, '.dart_tool', 'package_config.json'),
        ).openSync(mode: FileMode.write)
        ..truncateSync(16 * 1024 * 1024 + 1)
        ..closeSync();

      await expectDiagnostic(
        ['cycles'],
        'Analysis failed: invalid .dart_tool/package_config.json: package '
        'configuration exceeds the 16 MiB limit',
      );
    });

    test('a package config between 1 and 16 MiB with stale entries is '
        'read', () async {
      // 대형 모노레포의 package_config는 설정 상한(1 MiB)을 넘을 수 있다. 캐시 키
      // 열거와 같은 16 MiB 상한이다. 항목은 모두 지워진 루트를 가리킨다.
      final stale = [
        for (var index = 0; index < 16000; index++)
          '{"name": "gone_$index", "rootUri": "../gone_$index/", '
              '"packageUri": "lib/"}',
      ];
      await sourcePackage(
        '{"configVersion": 2, "packages": [${[...stale, localEntry].join(', ')}]}',
      );
      expect(
        File(
          p.join(root.path, '.dart_tool', 'package_config.json'),
        ).lengthSync(),
        greaterThan(1024 * 1024),
      );

      final result = await run(['graph', '--format', 'json']);

      expect(result.code, ExitStatus.success.code, reason: result.error);
      expect(result.output, contains('package:local/local.dart'));
    });

    test(
      'a stale package config entry does not fail source_packages',
      () async {
        // 지워진 path 의존 하나가 analysis 전체를 '원인 불명'으로 멈추게 했다.
        await sourcePackage(
          '{"configVersion": 2, "packages": [{"name": "gone", "rootUri": '
          '"../gone/", "packageUri": "lib/"}, $localEntry]}',
        );

        final result = await run(['graph', '--format', 'json']);

        expect(result.code, ExitStatus.success.code, reason: result.error);
        expect(result.output, contains('package:local/local.dart'));
      },
    );
  });

  group('diagnostic text', () {
    test('a long echoed value is shortened with an ellipsis', () async {
      await write('dartograph.yaml', 'thresholds:\n  ${'k' * 5000}: 1\n');
      const prefix =
          'Analysis failed: invalid dartograph.yaml: thresholds key must be '
          'distance or complexity: kkk';

      final result = await run(['cycles']);

      // "Analysis failed: " 17자 + 설정 문장 400자 + 말줄임표 + 개행이다.
      expect(result.code, ExitStatus.failure.code);
      expect(result.error, startsWith(prefix));
      expect(result.error, endsWith('k…\n'));
      expect(result.error.length, 17 + 400 + 1 + 1);
    });

    test('the file name is not repeated for a non-mapping document', () async {
      await write('dartograph.yaml', '- lib/main.dart\n');

      await expectDiagnostic(
        ['cycles'],
        'Analysis failed: invalid dartograph.yaml: the document must be a YAML '
        'mapping',
      );
    });

    test('a configuration file that is not UTF-8 is named', () async {
      File(p.join(root.path, 'dartograph.yaml')).writeAsBytesSync([
        ...'entry_points:\n  - bin/caf'.codeUnits,
        0xe9,
        ...'.dart\n'.codeUnits,
      ]);
      await expectDiagnostic(
        ['cycles'],
        'Analysis failed: invalid dartograph.yaml: the file is not valid UTF-8',
      );

      await File(p.join(root.path, 'dartograph.yaml')).delete();
      File(p.join(root.path, 'pubspec.yaml')).writeAsBytesSync([
        ...'name: config_app\ndescription: caf'.codeUnits,
        0xe9,
        10,
      ]);
      await expectDiagnostic([
        'cycles',
      ], 'Analysis failed: invalid pubspec.yaml: the file is not valid UTF-8');
    });

    test('a pubspec over the configuration limit is named', () async {
      await write('pubspec.yaml', 'name: config_app\n${'#' * (1024 * 1024)}\n');

      await expectDiagnostic(
        ['cycles'],
        'Analysis failed: invalid pubspec.yaml: configuration file exceeds the '
        '1024 KiB limit',
      );
    });
  });
}
