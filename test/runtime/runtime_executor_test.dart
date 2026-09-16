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
      executableLookup: const DartExecutableLookup.found('/bin/sh', 'test'),
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

  group('dart 실행 파일 해석', () {
    test('실행 중인 실행 파일이 dart VM이면 그대로 쓴다', () {
      final lookup = resolveDartExecutable(
        resolvedExecutable: '/sdk/bin/dart',
        environment: const {},
        executableAt: (path) => fail('dart VM이면 후보를 탐색하지 않는다: $path'),
      );

      expect(lookup.found, isTrue);
      expect(lookup.path, '/sdk/bin/dart');
      expect(lookup.evidence, 'the running VM');
      expect(lookup.reason, isNull);
    });

    test('컴파일 배포본에서는 DART_SDK의 dart를 먼저 쓴다', () {
      final probed = <String>[];
      final lookup = resolveDartExecutable(
        resolvedExecutable: '/opt/dartograph/dartograph',
        environment: const {'DART_SDK': '/sdk', 'PATH': '/usr/bin'},
        executableAt: (path) {
          probed.add(path);
          return path == p.join('/sdk', 'bin', 'dart');
        },
      );

      expect(lookup.path, p.join('/sdk', 'bin', 'dart'));
      expect(lookup.evidence, 'DART_SDK');
      // DART_SDK 후보를 먼저 본다(PATH보다 우선이다).
      expect(probed, [p.join('/sdk', 'bin', 'dart')]);
    });

    test('DART_SDK 후보를 쓸 수 없으면 PATH에서 찾는다', () {
      final lookup = resolveDartExecutable(
        resolvedExecutable: '/opt/dartograph/dartograph',
        environment: const {
          'DART_SDK': '/missing-sdk',
          'PATH': '/usr/bin:/opt/dart/bin',
        },
        executableAt: (path) => path == p.join('/opt/dart/bin', 'dart'),
      );

      expect(lookup.path, p.join('/opt/dart/bin', 'dart'));
      expect(lookup.evidence, 'PATH');
    });

    test('Windows에서는 dart.exe를 찾는다', () {
      final lookup = resolveDartExecutable(
        resolvedExecutable: r'C:\dartograph\dartograph.exe',
        environment: const {'DART_SDK': r'C:\sdk'},
        windows: true,
        executableAt: (path) => path == p.join(r'C:\sdk', 'bin', 'dart.exe'),
      );

      expect(lookup.path, p.join(r'C:\sdk', 'bin', 'dart.exe'));
      expect(lookup.evidence, 'DART_SDK');
    });

    test('어디에서도 못 찾으면 사유와 함께 실행 파일 없음을 알린다', () {
      final lookup = resolveDartExecutable(
        resolvedExecutable: '/opt/dartograph/dartograph',
        environment: const {'DART_SDK': '/missing-sdk', 'PATH': '/usr/bin'},
        executableAt: (_) => false,
      );

      expect(lookup.found, isFalse);
      expect(lookup.path, isNull);
      expect(lookup.reason, startsWith('dart-executable-not-found'));
      // 환경변수 값 자체는 사유에 싣지 않는다(보고서에 값이 따라가지 않게).
      expect(lookup.reason, isNot(contains('/missing-sdk')));
    });
  });

  group('실행 파일을 찾지 못한 실행', () {
    test('자식을 띄우지 않고 사유를 실행 증거로 남긴다', () async {
      // 실행됐다면 남을 표식이다. 실행하지 않았다는 것을 부작용으로 확인한다.
      final entrypoint = script(
        'probe_writes.dart',
        "import 'dart:io';\n"
            "void main() { File('ran.txt').writeAsStringSync('ran'); }\n",
      );
      final marker = File(p.join(directory.path, 'ran.txt'));

      final execution = await executeEntrypoint(
        entrypoint: p.basename(entrypoint.path),
        rootPath: directory.path,
        executableLookup: resolveDartExecutable(
          resolvedExecutable: '/opt/dartograph/dartograph',
          environment: const {'PATH': ''},
          executableAt: (_) => false,
        ),
      );

      expect(execution.unresolved, isTrue);
      expect(execution.ok, isFalse);
      expect(execution.exitCode, isNull);
      expect(execution.timedOut, isFalse);
      expect(execution.stderrSummary, isEmpty);
      expect(
        execution.unresolvedReason,
        startsWith('dart-executable-not-found'),
      );
      expect(marker.existsSync(), isFalse);
      // JSON에서도 "실행했는데 종료 코드 0"과 구분된다.
      expect(execution.toJson(), {
        'entrypoint': 'probe_writes.dart',
        'exitCode': null,
        'ok': false,
        'reason': execution.unresolvedReason,
        'stderrSummary': '',
        'timedOut': false,
      });
    });

    test('주입한 해석 결과로 실제 dart를 띄운다', () async {
      final entrypoint = script(
        'probe_injected.dart',
        "import 'dart:io';\nvoid main() { stdout.writeln('injected'); }\n",
      );

      final execution = await executeEntrypoint(
        entrypoint: p.basename(entrypoint.path),
        rootPath: directory.path,
        executableLookup: resolveDartExecutable(),
      );

      expect(execution.unresolved, isFalse);
      expect(execution.exitCode, 0);
      expect(execution.ok, isTrue);
    });
  });
}
