import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'runtime_facts.dart';

/// `--execute`의 기본 제한 시간이다.
const runtimeExecutionTimeout = Duration(seconds: 60);

/// 실행 증거로 싣는 stderr 바이트 상한이다.
const runtimeStderrLimit = 4096;

/// `dart run <entrypoint>`를 자식 프로세스로 실행하고 결과를 요약한다.
///
/// **임의 코드를 실행한다.** 기본은 미실행이며 `--execute`를 준 호출만 여기
/// 들어온다. 자식의 stdout은 버리고 stdout·stderr 파이프는 항상 소진한다 —
/// 읽지 않은 파이프는 자식이 쓰다 멈추게 하고, 요약은 bounded로 잘라 메모리를
/// 상한 안에 둔다.
///
/// [environment]가 있으면 상속 환경 위에 덮어쓴다(`--env`로 판정한 값을 실제로
/// 적용해 본다). null이면 상속 환경을 그대로 쓴다.
Future<RuntimeExecution> executeEntrypoint({
  required String entrypoint,
  required String rootPath,
  Map<String, String>? environment,
  Duration timeout = runtimeExecutionTimeout,
  String? dartExecutable,
}) async {
  final executable = dartExecutable ?? Platform.resolvedExecutable;
  final process = await Process.start(
    executable,
    ['run', entrypoint],
    workingDirectory: rootPath,
    environment: environment,
  );
  final stdoutDone = process.stdout.drain<void>();
  final stderrDone = _readBounded(process.stderr, runtimeStderrLimit);
  var timedOut = false;
  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    process.kill(ProcessSignal.sigkill);
    exitCode = await process.exitCode;
  }
  // 자식이 죽은 뒤에도 파이프에 남은 출력은 읽어야 한다.
  await stdoutDone;
  final stderrText = await stderrDone;
  return RuntimeExecution(
    entrypoint: entrypoint,
    exitCode: exitCode,
    timedOut: timedOut,
    stderrSummary: stderrText,
  );
}

/// [stream]을 [limit] 바이트까지만 모으고 나머지는 버리며 소진한다.
Future<String> _readBounded(Stream<List<int>> stream, int limit) async {
  final bytes = <int>[];
  var truncated = false;
  await for (final chunk in stream) {
    if (bytes.length >= limit) {
      truncated = true;
      continue;
    }
    final remaining = limit - bytes.length;
    if (chunk.length <= remaining) {
      bytes.addAll(chunk);
    } else {
      bytes.addAll(chunk.sublist(0, remaining));
      truncated = true;
    }
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  return truncated ? '$text\n… (stderr truncated)' : text;
}
