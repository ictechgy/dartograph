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
}
