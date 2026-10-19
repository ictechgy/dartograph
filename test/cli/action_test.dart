import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../tool/parse_action_args.dart' as action_args;

/// 루트 `action.yml` 합성 액션의 셸 경계를 고정한다.
///
/// `${{ }}`는 bash가 스크립트를 받기 전에 GitHub 러너가 확장한다 — `run:`
/// 본문 안에 입력 보간이 있으면 호출자가 넘긴 값이 셸 구문이 되는 스크립트
/// 인젝션 경로다. 입력은 `env:`로만 넘기고 본문은 `"$VAR"` 확장만 쓴다.
void main() {
  test('action.yml keeps expressions out of run script bodies', () {
    final document = loadYaml(File('action.yml').readAsStringSync());
    final steps = document['runs']['steps'] as YamlList;
    var shellSteps = 0;
    for (final step in steps) {
      final map = step as YamlMap;
      final run = map['run'];
      if (run is! String) continue;
      shellSteps++;
      expect(
        run,
        isNot(contains(r'${{')),
        reason: '${map['name']} interpolates an expression in run:',
      );
    }
    expect(shellSteps, greaterThan(0));
  });

  // 합성 액션의 Bash 경계 테스트는 Windows에서 건너뛴다.
  group('action argument and report contract', () {
    late Directory temporary;
    late File captured;
    late File report;
    late File output;
    late Map<String, String> environment;
    late String script;

    setUp(() {
      final document = loadYaml(File('action.yml').readAsStringSync());
      final steps = (document['runs']['steps'] as YamlList).cast<YamlMap>();
      final runStep = steps.singleWhere((step) => step['id'] == 'run');
      script = runStep['run'] as String;
      temporary = Directory.systemTemp.createTempSync('dartograph-action-');
      captured = File('${temporary.path}/argv.json');
      report = File('${temporary.path}/report with spaces.txt');
      output = File('${temporary.path}/github-output');
      final captureProgram = File('${temporary.path}/capture.dart')
        ..writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> arguments) async {
  File(Platform.environment['CAPTURE']!).writeAsStringSync(jsonEncode(arguments));
  final report = Platform.environment['CLI_REPORT'];
  if (report == null) {
    stdout.writeln('report stdout 한글');
    stderr.writeln('report stderr');
  } else {
    stdout.write(report);
  }
  exitCode = int.parse(Platform.environment['CLI_STATUS'] ?? '0');
}
''');
      final testTool = Directory('${temporary.path}/action path 한글/tool')
        ..createSync(recursive: true);
      File(
        'tool/parse_action_args.dart',
      ).copySync('${testTool.path}/parse_action_args.dart');
      final sdkDispatch = File('${temporary.path}/dart')
        ..writeAsStringSync('''#!/usr/bin/env bash
if [[ "\$1" == "pub" ]]; then
  [[ "\$2" == "global" && "\$3" == "run" && "\$4" == "dartograph:dartograph" ]] || exit 99
  shift 4
  exec "${Platform.resolvedExecutable}" "${captureProgram.path}" "\$@"
fi
exec "${Platform.resolvedExecutable}" "\$@"
''');
      expect(Process.runSync('chmod', ['+x', sdkDispatch.path]).exitCode, 0);
      // 수정 전 action도 동일한 실제 argv 관측기로 실패를 재현한다.
      final legacyCli = File('${temporary.path}/dartograph')
        ..writeAsStringSync('''#!/usr/bin/env bash
exec "${Platform.resolvedExecutable}" "${captureProgram.path}" "\$@"
''');
      final chmod = Process.runSync('chmod', ['+x', legacyCli.path]);
      expect(chmod.exitCode, 0);
      environment = {
        'PATH':
            '${temporary.path}:${File(Platform.resolvedExecutable).parent.path}:${Platform.environment['PATH']}',
        'DARTOGRAPH_ACTION_PATH': testTool.parent.path,
        'DARTOGRAPH_COMMAND': 'rules',
        'DARTOGRAPH_ARGS': '',
        'DARTOGRAPH_PACKAGE_ROOT': 'package root 한글',
        'DARTOGRAPH_OUTPUT_FILE': report.path,
        'GITHUB_OUTPUT': output.path,
        'CAPTURE': captured.path,
        'TMPDIR': (Directory('${temporary.path}/args-temp')..createSync()).path,
      };
    });

    tearDown(() {
      try {
        expect(
          Directory(environment['TMPDIR']!).listSync(),
          isEmpty,
          reason:
              'The action must clean its temporary argv file on every exit.',
        );
      } finally {
        temporary.deleteSync(recursive: true);
      }
    });

    Future<ProcessResult> run(
      String arguments, {
      int status = 0,
      String? cliReport,
    }) {
      return Process.run(
        'bash',
        ['-c', script],
        workingDirectory: temporary.path,
        environment: {
          ...environment,
          'DARTOGRAPH_ARGS': arguments,
          'CLI_STATUS': '$status',
          'CLI_REPORT': ?cliReport,
        },
      );
    }

    /// 종료 2·64에서 작업 로그로 반향한 리포트를 풀어 정지 토큰과 본문을 돌려준다.
    ///
    /// 반향은 `::stop-commands::<token>` 줄로 시작해 같은 토큰의 `::<token>::`
    /// 줄로 끝나야 한다. 그 사이의 리포트 줄은 러너가 워크플로 명령으로 읽지 않는다.
    ({String token, String body}) unwrapEcho(Object? stderr) {
      final match = RegExp(
        r'^::stop-commands::([0-9a-f]{32})\n([\s\S]*)::\1::\n$',
      ).firstMatch(stderr! as String);
      expect(match, isNotNull, reason: 'unpaused report echo: $stderr');
      return (token: match!.group(1)!, body: match.group(2)!);
    }

    final vectors = <String, List<String>>{
      '': [],
      ' \t\r\n\v\f ': [],
      '--format json --strict': ['--format', 'json', '--strict'],
      '--config "config files/rules.yaml"': [
        '--config',
        'config files/rules.yaml',
      ],
      "--config 'config files/rules.yaml'": [
        '--config',
        'config files/rules.yaml',
      ],
      "--value '' \"\"": ['--value', '', ''],
      '''--value pre"two words"post'!' ''': ['--value', 'pretwo wordspost!'],
      '''--value "it's fine" 'say "hello"' ''': [
        '--value',
        "it's fine",
        'say "hello"',
      ],
      r'''--value a\ b "a\"b" 'a\b' a\\b''': [
        '--value',
        'a b',
        'a"b',
        r'a\b',
        r'a\b',
      ],
      '--값 "설정 파일/🌱.yaml" café': ['--값', '설정 파일/🌱.yaml', 'café'],
      'one\ttwo\nthree\rfour\vfive\fsix': [
        'one',
        'two',
        'three',
        'four',
        'five',
        'six',
      ],
      '--value "line\none\ttwo"': ['--value', 'line\none\ttwo'],
      r'''--value '$HOME' "$(touch PWNED)" '`touch PWNED`' ; | & > PWNED * ? [abc]''':
          [
            '--value',
            r'$HOME',
            r'$(touch PWNED)',
            '`touch PWNED`',
            ';',
            '|',
            '&',
            '>',
            'PWNED',
            '*',
            '?',
            '[abc]',
          ],
    };
    for (final (arguments, expected) in vectors.entries.map(
      (e) => (e.key, e.value),
    )) {
      test('delivers argv ${jsonEncode(arguments)}', () async {
        File(
          '${temporary.path}/glob-match',
        ).writeAsStringSync('not an argument');
        final result = await run(arguments);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(jsonDecode(captured.readAsStringSync()), [
          'rules',
          ...expected,
          'package root 한글',
        ]);
        expect(File('${temporary.path}/PWNED').existsSync(), isFalse);
      });
    }

    for (final malformed in [
      "--config 'unclosed",
      '--config "unclosed',
      '--value trailing\\',
      '"trailing\\',
    ]) {
      test(
        'rejects malformed args ${jsonEncode(malformed)} before CLI',
        () async {
          final result = await run(malformed);
          expect(result.exitCode, 64);
          expect(captured.existsSync(), isFalse);
          expect(report.readAsStringSync(), contains('invalid args input'));
          expect(unwrapEcho(result.stderr).body, report.readAsStringSync());
          expect(
            output.readAsStringSync(),
            'exit-code=64\noutput-file=${report.path}\n',
          );
        },
      );
    }

    for (final status in [0, 1, 2, 64, 7]) {
      test('preserves CLI status $status and report outputs', () async {
        final result = await run('', status: status);
        expect(result.exitCode, status);
        expect(report.readAsStringSync(), 'report stdout 한글\nreport stderr\n');
        expect(
          output.readAsStringSync(),
          'exit-code=$status\noutput-file=${report.path}\n',
        );
        expect(result.stdout, isEmpty);
        if (status == 2 || status == 64) {
          expect(unwrapEcho(result.stderr).body, report.readAsStringSync());
        } else {
          expect(result.stderr, isEmpty);
        }
      });
    }

    test('pauses workflow commands while echoing a failed report', () async {
      // 리포트는 저장소가 정한 문자열(설정 키·경로)을 반향할 수 있다. 러너는
      // stderr의 `::` 줄도 명령으로 읽으므로 반향하는 동안 추측할 수 없는
      // 토큰으로 명령 처리를 멈췄다가 같은 토큰으로 재개해야 한다.
      const forged =
          'Analysis failed: invalid rules configuration\n'
          '::error file=lib/a.dart,line=1::forged\n'
          '::add-mask::not-a-secret';
      final first = await run('', status: 2, cliReport: forged);
      expect(first.exitCode, 2);
      expect(report.readAsStringSync(), forged);
      final echoed = unwrapEcho(first.stderr);
      // 끝 개행이 없는 리포트에서도 재개 명령은 줄 머리에서 시작한다.
      expect(echoed.body, '$forged\n');

      final second = await run('', status: 64, cliReport: forged);
      expect(second.exitCode, 64);
      expect(unwrapEcho(second.stderr).token, isNot(echoed.token));
    });

    test(
      'keeps the exit code without echoing when no token is available',
      () async {
        // 토큰을 못 만들면 멈춤 없이 반향하지 않는다. `set -e`가 토큰 실패를
        // 단계의 종료 코드로 바꾸지 않고 CLI 종료 코드를 그대로 전파해야 한다.
        final failingOd = File('${temporary.path}/od')
          ..writeAsStringSync('#!/usr/bin/env bash\nexit 1\n');
        expect(Process.runSync('chmod', ['+x', failingOd.path]).exitCode, 0);
        const forged = '::error file=lib/a.dart,line=1::forged\n';
        final result = await run('', status: 2, cliReport: forged);
        expect(result.exitCode, 2);
        expect(report.readAsStringSync(), forged);
        expect(
          output.readAsStringSync(),
          'exit-code=2\noutput-file=${report.path}\n',
        );
        expect(result.stderr, isNot(contains('::')));
        expect(result.stderr, contains('read the output-file report'));
      },
    );

    test(
      'empty command retains the existing no-report usage contract',
      () async {
        environment['DARTOGRAPH_COMMAND'] = '';
        final result = await run('');
        expect(result.exitCode, 64);
        expect(captured.existsSync(), isFalse);
        expect(report.existsSync(), isFalse);
        expect(output.readAsStringSync(), 'exit-code=64\n');
      },
    );

    test('rejects NUL before NUL-delimited transport', () {
      for (final args in [
        '\u0000',
        'value\u0000next',
        "'\u0000'",
        '"\u0000"',
      ]) {
        expect(
          () => action_args.parseActionArguments(args),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('NUL'),
            ),
          ),
        );
      }
    });
  }, skip: Platform.isWindows);
}
