import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('runtime-cli.');
  });

  tearDown(() => directory.delete(recursive: true));

  void write(String relative, String content) {
    File(p.join(directory.path, relative))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  Future<({int status, String out, String err})> run(
    List<String> arguments,
  ) async {
    final output = StringBuffer();
    final error = StringBuffer();
    final status = await runDartograph(arguments, output: output, error: error);
    return (status: status, out: output.toString(), err: error.toString());
  }

  Map<String, Object?> document(String text) =>
      jsonDecode(text) as Map<String, Object?>;

  List<Object?> detected(Map<String, Object?> report, String kind) =>
      (report['detected']! as Map<String, Object?>)[kind]! as List<Object?>;

  /// 환경변수 하나를 읽는 최소 패키지를 만든다.
  void writeTokenPackage() {
    write(
      'lib/env.dart',
      "import 'dart:io';\n"
          "String? token() => Platform.environment['RUNTIME_CLI_TOKEN'];\n",
    );
  }

  test('json 출력은 version 1과 다섯 카테고리 키를 낸다', () async {
    writeTokenPackage();

    final result = await run(['runtime', '--format', 'json', directory.path]);

    expect(result.status, 0);
    final report = document(result.out);
    expect(report['version'], 1);
    expect((report['detected']! as Map<String, Object?>).keys, [
      'env',
      'dynamicLoad',
      'config',
      'asset',
      'external',
    ]);
    expect((report['verified']! as Map<String, Object?>).keys, [
      'present',
      'defaulted',
      'missing',
    ]);
    expect(report['execution'], isNull);
    expect(report['truncated'], {
      'detected': 0,
      'unverified': 0,
      'verified': 0,
    });
    expect(report['limitations'], isNotEmpty);

    final fact = detected(report, 'env').single as Map<String, Object?>;
    expect(fact['name'], 'RUNTIME_CLI_TOKEN');
    expect(fact['channel'], 'environment');
    expect(fact['kind'], 'env');
    expect(fact['source'], 'project:lib/env.dart');
    expect(fact['line'], 2);
    final missing = report['verified']! as Map<String, Object?>;
    expect(missing['present'], isEmpty);
    expect((missing['missing']! as List<Object?>).single, {
      'channel': 'environment',
      'column': 20,
      'detail': 'Platform.environment["RUNTIME_CLI_TOKEN"]',
      'evidence': 'not present in the process environment',
      'id': 'env:RUNTIME_CLI_TOKEN@project:lib/env.dart:2:20',
      'kind': 'env',
      'line': 2,
      'name': 'RUNTIME_CLI_TOKEN',
      'source': 'project:lib/env.dart',
      'verdict': 'missing',
    });
  });

  test('--env는 주어진 값만 쓰고 값 자체는 출력하지 않는다', () async {
    writeTokenPackage();

    final without = await run(['runtime', '--format', 'json', directory.path]);
    expect(
      ((document(without.out)['verified']! as Map<String, Object?>)['missing']!
          as List<Object?>),
      hasLength(1),
    );

    final hermetic = await run([
      'runtime',
      '--format',
      'json',
      '--env',
      'RUNTIME_CLI_TOKEN=super-secret-token',
      directory.path,
    ]);
    final report = document(hermetic.out);
    final present =
        ((report['verified']! as Map<String, Object?>)['present']!
                    as List<Object?>)
                .single
            as Map<String, Object?>;
    expect(present['name'], 'RUNTIME_CLI_TOKEN');
    expect(present['evidence'], '--env RUNTIME_CLI_TOKEN');
    // 값은 근거에도 한계에도 실리지 않는다.
    expect(hermetic.out, isNot(contains('super-secret-token')));
    // --env를 주면 프로세스 환경은 판정에 쓰이지 않는다(hermetic).
    expect(
      report['limitations'],
      contains(startsWith('environment-source: verification used only')),
    );
  });

  test('--dart-define은 dart-define 채널만 충족한다', () async {
    write(
      'lib/env.dart',
      "const String endpoint = String.fromEnvironment('RUNTIME_CLI_ENDPOINT');\n",
    );

    final without = await run(['runtime', '--format', 'json', directory.path]);
    expect(
      ((document(without.out)['verified']! as Map<String, Object?>)['missing']!
          as List<Object?>),
      hasLength(1),
    );

    final defined = await run([
      'runtime',
      '--format',
      'json',
      '--dart-define',
      'RUNTIME_CLI_ENDPOINT=https://example.com/api',
      directory.path,
    ]);
    final report = document(defined.out);
    final present =
        ((report['verified']! as Map<String, Object?>)['present']!
                    as List<Object?>)
                .single
            as Map<String, Object?>;
    expect(present['channel'], 'dart-define');
    expect(present['evidence'], '--dart-define RUNTIME_CLI_ENDPOINT');
    expect(defined.out, isNot(contains('https://example.com/api')));
    // 프로세스 환경은 dart-define을 충족하지 않는다.
    expect(report['limitations'], isNotEmpty);
  });

  test('--fail-on은 임계 이상일 때만 1을 낸다', () async {
    writeTokenPackage();

    expect(
      (await run(['runtime', directory.path])).status,
      0,
      reason: '기본값은 none이다',
    );
    expect(
      (await run(['runtime', '--fail-on', 'none', directory.path])).status,
      0,
    );
    // 미충족 하나는 low(12/100)다.
    expect(
      (await run([
        'runtime',
        '--format',
        'json',
        '--fail-on',
        'low',
        directory.path,
      ])).status,
      1,
    );
    expect(
      (await run(['runtime', '--fail-on', 'medium', directory.path])).status,
      0,
    );
    expect(
      (await run(['runtime', '--fail-on', 'high', directory.path])).status,
      0,
    );
  });

  test('--no-verify는 탐지만 하고 판정을 생략한다', () async {
    writeTokenPackage();

    final result = await run([
      'runtime',
      '--no-verify',
      '--format',
      'json',
      directory.path,
    ]);

    expect(result.status, 0);
    final report = document(result.out);
    expect(detected(report, 'env'), hasLength(1));
    final verified = report['verified']! as Map<String, Object?>;
    expect(verified['present'], isEmpty);
    expect(verified['defaulted'], isEmpty);
    expect(verified['missing'], isEmpty);
    expect(report['unverified'], isEmpty);
    expect(report['risk'], {
      'factors': <Object?>[],
      'level': 'none',
      'score': 0,
    });
    expect(
      report['limitations'],
      contains(startsWith('verification-disabled')),
    );

    final text = await run(['runtime', '--no-verify', directory.path]);
    expect(text.out, contains('verification: skipped (--no-verify)'));
  });

  test('--limit은 보고 항목만 줄이고 생략 수를 남긴다', () async {
    write(
      'lib/env.dart',
      "import 'dart:io';\n"
          "String? a() => Platform.environment['RUNTIME_CLI_A'];\n"
          "String? b() => Platform.environment['RUNTIME_CLI_B'];\n",
    );

    final result = await run([
      'runtime',
      '--format',
      'json',
      '--limit',
      '1',
      directory.path,
    ]);

    final report = document(result.out);
    expect(detected(report, 'env'), hasLength(1));
    expect(
      (report['verified']! as Map<String, Object?>)['missing'],
      hasLength(1),
    );
    expect(report['truncated'], {
      'detected': 1,
      'unverified': 0,
      'verified': 1,
    });
  });

  test('모든 포맷을 렌더링한다', () async {
    writeTokenPackage();

    final text = await run(['runtime', directory.path]);
    expect(text.status, 0);
    expect(text.out, contains('detected: 1 fact(s) — env 1'));
    expect(text.out, contains('missing RUNTIME_CLI_TOKEN'));

    final markdown = await run([
      'runtime',
      '--format',
      'markdown',
      directory.path,
    ]);
    expect(markdown.out, contains('# dartograph runtime report'));
    expect(markdown.out, contains('| Missing | 1 |'));

    final actions = await run([
      'runtime',
      '--format',
      'github-actions',
      directory.path,
    ]);
    expect(actions.out, contains('::warning'), reason: '미충족 항목을 워크플로 경고로 올린다');

    final sarif = await run(['runtime', '--format', 'sarif', directory.path]);
    final payload = document(sarif.out);
    expect(payload['version'], '2.1.0');
    final run_ =
        (payload['runs']! as List<Object?>).single as Map<String, Object?>;
    expect(
      (run_['invocations']! as List<Object?>).single,
      containsPair('executionSuccessful', true),
    );
    final results = run_['results']! as List<Object?>;
    expect(results, hasLength(1));
    final result_ = results.single as Map<String, Object?>;
    expect(result_['ruleId'], 'runtime-missing-env');
    expect(result_['level'], 'warning');
    expect(
      (result_['locations']! as List<Object?>).single,
      containsPair('physicalLocation', {
        'artifactLocation': {'uri': 'lib/env.dart'},
        'region': {'startColumn': 20, 'startLine': 2},
      }),
    );
  });

  test('--kinds는 보고 카테고리를 좁히고 위험도는 유지한다', () async {
    writeTokenPackage();
    write(
      'lib/config.dart',
      "import 'dart:io';\n"
          "File settings() => File('config/app.yaml');\n",
    );

    final result = await run([
      'runtime',
      '--format',
      'json',
      '--kinds',
      'env',
      directory.path,
    ]);

    expect(result.status, 0);
    final report = document(result.out);
    expect(detected(report, 'env'), hasLength(1));
    expect(detected(report, 'config'), isEmpty);
    expect(
      (report['detected']! as Map<String, Object?>).keys,
      hasLength(5),
      reason: '카테고리 키는 필터 아래에서도 유지된다',
    );
    final missing =
        (report['verified']! as Map<String, Object?>)['missing']!
            as List<Object?>;
    expect(missing.map((item) => (item as Map<String, Object?>)['name']), [
      'RUNTIME_CLI_TOKEN',
    ]);
    // 걸러진 config 미충족(12)까지 센 위험도 24 = medium이 유지된다.
    expect((report['risk']! as Map<String, Object?>)['score'], 24);
    expect((report['risk']! as Map<String, Object?>)['level'], 'medium');

    // 위험도가 보존되므로 --fail-on 게이트는 필터와 무관하게 동작한다.
    final gated = await run([
      'runtime',
      '--kinds',
      'env',
      '--fail-on',
      'medium',
      directory.path,
    ]);
    expect(gated.status, 1);
  });

  test('--statuses는 판정 절만 좁히고 탐지 목록은 유지한다', () async {
    writeTokenPackage();
    write(
      'lib/computed.dart',
      "import 'dart:io';\n"
          "String? pick(String key) => Platform.environment[key];\n",
    );

    final result = await run([
      'runtime',
      '--format',
      'json',
      '--statuses',
      'missing',
      directory.path,
    ]);

    expect(result.status, 0);
    final report = document(result.out);
    final verified = report['verified']! as Map<String, Object?>;
    expect(verified['present'], isEmpty);
    expect(verified['defaulted'], isEmpty);
    expect(
      ((verified['missing']! as List<Object?>).single
          as Map<String, Object?>)['name'],
      'RUNTIME_CLI_TOKEN',
    );
    expect(report['unverified'], isEmpty);
    // 탐지 목록은 판정 절 필터를 적용하지 않는다.
    expect(detected(report, 'env'), hasLength(2));
    // 미판정 사유 집계는 필터 전 전체 집합을 센다.
    expect(report['unverifiedReasonCounts'], {'computed-target': 1});
  });

  test('--kinds는 --no-verify와 결합할 수 있다', () async {
    writeTokenPackage();
    write(
      'lib/config.dart',
      "import 'dart:io';\n"
          "File settings() => File('config/app.yaml');\n",
    );

    final result = await run([
      'runtime',
      '--no-verify',
      '--format',
      'json',
      '--kinds',
      'env',
      directory.path,
    ]);

    expect(result.status, 0);
    final report = document(result.out);
    expect(detected(report, 'env'), hasLength(1));
    expect(detected(report, 'config'), isEmpty);
    expect(report['verified'], {'present': [], 'defaulted': [], 'missing': []});
  });

  test('집계 요약을 text·markdown·sarif에도 렌더링한다', () async {
    writeTokenPackage();
    write(
      'lib/computed.dart',
      "import 'dart:io';\n"
          "String? pick(String key) => Platform.environment[key];\n",
    );

    final text = await run(['runtime', directory.path]);
    expect(text.out, contains('unverified reasons: computed-target 1'));

    final markdown = await run([
      'runtime',
      '--format',
      'markdown',
      directory.path,
    ]);
    expect(markdown.out, contains('_By reason: computed-target 1._'));

    final sarif = await run(['runtime', '--format', 'sarif', directory.path]);
    final invocation =
        (((document(sarif.out)['runs']! as List<Object?>).single
                        as Map<String, Object?>)['invocations']!
                    as List<Object?>)
                .single
            as Map<String, Object?>;
    expect(
      (invocation['properties']!
          as Map<String, Object?>)['unverifiedReasonCounts'],
      {'computed-target': 1},
    );
  });

  test('--statuses는 --no-verify와 결합하지 않는다', () async {
    writeTokenPackage();

    final result = await run([
      'runtime',
      '--no-verify',
      '--statuses',
      'missing',
      directory.path,
    ]);

    expect(result.status, 64);
    expect(result.err, contains('--statuses requires verification'));
    expect(result.out, isEmpty);
  });

  test('필터된 목록에 --limit이 적용된다', () async {
    write(
      'lib/env.dart',
      "import 'dart:io';\n"
          "String? a() => Platform.environment['RUNTIME_CLI_A'];\n"
          "String? b() => Platform.environment['RUNTIME_CLI_B'];\n",
    );
    write(
      'lib/config.dart',
      "import 'dart:io';\n"
          "File settings() => File('config/app.yaml');\n",
    );

    final result = await run([
      'runtime',
      '--format',
      'json',
      '--kinds',
      'env',
      '--limit',
      '1',
      directory.path,
    ]);

    final report = document(result.out);
    expect(detected(report, 'env'), hasLength(1));
    expect(detected(report, 'config'), isEmpty);
    expect(
      (report['verified']! as Map<String, Object?>)['missing'],
      hasLength(1),
    );
    expect(report['truncated'], {
      'detected': 1,
      'unverified': 0,
      'verified': 1,
    });
  });

  test('잘못된 인자는 usage(64)다', () async {
    final cases = <(String, List<String>)>[
      ('알 수 없는 포맷', ['runtime', '--format', 'xml', directory.path]),
      (
        '중복 포맷',
        ['runtime', '--format', 'json', '--format', 'text', directory.path],
      ),
      ('포맷 값 누락', ['runtime', '--format']),
      ('limit 0', ['runtime', '--limit', '0', directory.path]),
      ('limit 누락', ['runtime', '--limit']),
      ('알 수 없는 fail-on', ['runtime', '--fail-on', 'sometimes', directory.path]),
      ('알 수 없는 kinds', ['runtime', '--kinds', 'bogus', directory.path]),
      ('빈 kinds 항목', ['runtime', '--kinds', 'env,,config', directory.path]),
      ('빈 kinds 값', ['runtime', '--kinds', '', directory.path]),
      ('옵션 모양 kinds 값', ['runtime', '--kinds', '--statuses', directory.path]),
      (
        '중복 kinds',
        ['runtime', '--kinds', 'env', '--kinds', 'config', directory.path],
      ),
      ('kinds 값 누락', ['runtime', '--kinds']),
      ('알 수 없는 statuses', ['runtime', '--statuses', 'bogus', directory.path]),
      ('빈 statuses 항목', ['runtime', '--statuses', 'missing,', directory.path]),
      (
        '중복 statuses',
        [
          'runtime',
          '--statuses',
          'missing',
          '--statuses',
          'present',
          directory.path,
        ],
      ),
      ('statuses 값 누락', ['runtime', '--statuses']),
      ('중복 verify', ['runtime', '--verify', '--no-verify', directory.path]),
      ('루트 누락', ['runtime']),
      ('정의가 아닌 --env', ['runtime', '--env', 'NOEQUALS', directory.path]),
      ('빈 키 --env', ['runtime', '--env', '=VALUE', directory.path]),
      ('--env 값 누락', ['runtime', '--env']),
      ('알 수 없는 옵션', ['runtime', '--depth', '2', directory.path]),
      ('위치 인자 둘', ['runtime', directory.path, directory.path]),
      ('--execute 값 누락', ['runtime', '--execute']),
      (
        '--execute 경로 없음',
        ['runtime', '--execute', 'bin/nope.dart', directory.path],
      ),
    ];

    for (final (description, arguments) in cases) {
      final result = await run(arguments);
      expect(result.status, 64, reason: description);
      expect(result.err, isNotEmpty, reason: description);
      expect(result.out, isEmpty, reason: description);
    }
  });

  test('오류 메시지가 원인과 기대값을 알려준다', () async {
    final format = await run(['runtime', '--format', 'xml', directory.path]);
    expect(format.err, contains('Unknown report format: xml'));

    final failOn = await run([
      'runtime',
      '--fail-on',
      'sometimes',
      directory.path,
    ]);
    expect(failOn.err, contains('Unknown fail-on level: sometimes'));

    final define = await run(['runtime', '--env', 'NOEQUALS', directory.path]);
    expect(define.err, contains('expected --env KEY=VALUE'));

    final entrypoint = await run([
      'runtime',
      '--execute',
      'bin/nope.dart',
      directory.path,
    ]);
    expect(entrypoint.err, contains('Entrypoint not found: bin/nope.dart'));

    final usage = await run(['runtime']);
    expect(usage.err, contains('dartograph runtime'));
  });

  test('분석 실패는 2다', () async {
    final result = await run([
      'runtime',
      '--format',
      'json',
      p.join(directory.path, 'does-not-exist'),
    ]);

    expect(result.status, 2);
    expect(result.err, contains('Analysis failed'));
    expect(result.out, isEmpty);
  });

  test('같은 입력에 같은 바이트를 낸다', () async {
    write(
      'lib/env.dart',
      "import 'dart:io';\n"
          "const String endpoint = String.fromEnvironment('RUNTIME_CLI_ENDPOINT');\n"
          "const int port = int.fromEnvironment('RUNTIME_CLI_PORT', defaultValue: 8080);\n"
          "String? token() => Platform.environment['RUNTIME_CLI_TOKEN'];\n",
    );
    write(
      'lib/dynamic.dart',
      "import 'dart:ffi';\n"
          "void open() { DynamicLibrary.open('libfoo.so'); }\n",
    );

    final first = await run(['runtime', '--format', 'json', directory.path]);
    final second = await run(['runtime', '--format', 'json', directory.path]);

    expect(first.out, isNotEmpty);
    expect(second.out, first.out);
  });

  test('--execute는 성공한 실행을 증거로 남긴다', () async {
    writeTokenPackage();
    write('bin/probe_ok.dart', "void main() { print('probe output'); }\n");

    final result = await run([
      'runtime',
      '--execute',
      'bin/probe_ok.dart',
      '--format',
      'json',
      directory.path,
    ]);

    expect(result.status, 0);
    expect(document(result.out)['execution'], {
      'entrypoint': 'bin/probe_ok.dart',
      'exitCode': 0,
      'ok': true,
      'stderrSummary': '',
      'timedOut': false,
    });

    final text = await run([
      'runtime',
      '--execute',
      'bin/probe_ok.dart',
      directory.path,
    ]);
    expect(
      text.out,
      contains('execution: dart run bin/probe_ok.dart exited 0'),
    );
  });

  test('--execute 실패는 종료 코드·stderr·위험도로 보고된다', () async {
    writeTokenPackage();
    write(
      'bin/probe_fail.dart',
      "import 'dart:io';\n"
          "void main() { stderr.writeln('probe failed'); exit(3); }\n",
    );

    final result = await run([
      'runtime',
      '--execute',
      'bin/probe_fail.dart',
      '--format',
      'json',
      directory.path,
    ]);

    // 실행 실패 자체는 종료 코드가 아니라 위험도 요인이다.
    expect(result.status, 0);
    final report = document(result.out);
    final execution = report['execution']! as Map<String, Object?>;
    expect(execution['exitCode'], 3);
    expect(execution['ok'], isFalse);
    expect(execution['stderrSummary'], contains('probe failed'));
    expect(
      (report['risk']! as Map<String, Object?>)['factors'],
      contains(containsPair('name', 'execution-failed')),
    );

    // 미충족 하나(12)에 실행 실패(30)가 더해져 medium이 된다.
    final gated = await run([
      'runtime',
      '--execute',
      'bin/probe_fail.dart',
      '--fail-on',
      'medium',
      directory.path,
    ]);
    expect(gated.status, 1);
  });
}
