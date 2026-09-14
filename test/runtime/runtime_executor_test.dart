import 'dart:io';

import 'package:dartograph/src/runtime/runtime_executor.dart';
import 'package:dartograph/src/runtime/runtime_facts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('runtime-executor.');
  });

  tearDown(() => directory.delete(recursive: true));

  File script(String name, String content) =>
      File(p.join(directory.path, name))..writeAsStringSync(content);

  Future<RuntimeExecution> execute(
    File entrypoint, {
    Duration timeout = const Duration(seconds: 20),
  }) => executeEntrypoint(
    entrypoint: p.basename(entrypoint.path),
    rootPath: directory.path,
    timeout: timeout,
  );

  test('성공한 실행은 종료 코드 0과 빈 stderr 요약을 남긴다', () async {
    final entrypoint = script(
      'probe_ok.dart',
      "import 'dart:io';\nvoid main() { stdout.writeln('probe output'); }\n",
    );

    final execution = await execute(entrypoint);

    expect(execution.entrypoint, 'probe_ok.dart');
    expect(execution.exitCode, 0);
    expect(execution.timedOut, isFalse);
    expect(execution.ok, isTrue);
    expect(execution.stderrSummary, isEmpty);
  });

  test('실패한 실행은 종료 코드와 stderr 요약을 남긴다', () async {
    final entrypoint = script(
      'probe_fail.dart',
      "import 'dart:io';\n"
          "void main() { stderr.writeln('probe failed'); exit(3); }\n",
    );

    final execution = await execute(entrypoint);

    expect(execution.exitCode, 3);
    expect(execution.ok, isFalse);
    expect(execution.stderrSummary.trim(), 'probe failed');
  });

  test('제한 시간을 넘기면 종료시키고 timedOut을 남긴다', () async {
    final entrypoint = script(
      'probe_slow.dart',
      "import 'dart:io';\n"
          'void main() { sleep(const Duration(seconds: 30)); }\n',
    );

    final execution = await execute(
      entrypoint,
      timeout: const Duration(milliseconds: 500),
    );

    expect(execution.timedOut, isTrue);
    expect(execution.ok, isFalse);
    expect(execution.exitCode, isNot(0));
  });

  test('파이프를 소진해 자식이 출력에 막히지 않는다', () async {
    // stdout을 읽지 않으면 자식이 파이프 버퍼에서 멈춘다. 소진하지 않는 구현은
    // 이 테스트에서 제한 시간을 넘긴다.
    final entrypoint = script(
      'probe_noisy.dart',
      "import 'dart:io';\n"
          'void main() {\n'
          '  final line = List.filled(200, "x").join();\n'
          '  for (var index = 0; index < 2000; index++) {\n'
          '    stdout.writeln(line);\n'
          '  }\n'
          '}\n',
    );

    final execution = await execute(
      entrypoint,
      timeout: const Duration(seconds: 30),
    );

    expect(execution.exitCode, 0);
    expect(execution.timedOut, isFalse);
  });

  test('stderr 요약은 상한에서 자른다', () async {
    final entrypoint = script(
      'probe_loud.dart',
      "import 'dart:io';\n"
          'void main() {\n'
          '  for (var index = 0; index < 2000; index++) {\n'
          '    stderr.writeln("noise");\n'
          '  }\n'
          '}\n',
    );

    final execution = await execute(entrypoint);

    expect(execution.stderrSummary, endsWith('… (stderr truncated)'));
    expect(execution.stderrSummary.length, lessThan(runtimeStderrLimit + 64));
  });

  test('자식이 끝나도 후손이 출력 파이프를 잡고 있으면 제한 시간에 반환한다', () async {
    // 프로세스 경계만 검증한다. 짧은 shell 부모가 끝난 뒤 sleep이 두 파이프를 보유한다.
    script('run', '''
/bin/sleep 30 &
printf '%s' "\$!" > "\$1"
printf 'before exit' >&2
exit 0
''');
    final pidFile = File(p.join(directory.path, 'descendant.pid'));
    final pending = executeEntrypoint(
      entrypoint: 'descendant.pid',
      rootPath: directory.path,
      dartExecutable: '/bin/sh',
      timeout: const Duration(milliseconds: 200),
    );
    try {
      final execution = await pending.timeout(const Duration(seconds: 2));
      expect(execution.exitCode, 0);
      expect(execution.timedOut, isTrue);
      expect(execution.ok, isFalse);
      expect(execution.stderrSummary, 'before exit');
    } finally {
      if (await pidFile.exists()) {
        Process.killPid(
          int.parse(await pidFile.readAsString()),
          ProcessSignal.sigkill,
        );
      }
      await pending;
    }
  }, skip: Platform.isWindows);
}
