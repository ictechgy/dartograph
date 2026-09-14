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
  // AOT의 resolvedExecutable은 dartograph 자체다. --execute는 PATH의 SDK를 사용한다.
  final executable = dartExecutable ?? 'dart';
  final process = await Process.start(
    executable,
    ['run', entrypoint],
    workingDirectory: rootPath,
    environment: environment,
  );
  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  final bytes = <int>[];
  var truncated = false;
  final stdoutSubscription = process.stdout.listen(
    (_) {},
    onDone: stdoutDone.complete,
    onError: stdoutDone.completeError,
    cancelOnError: true,
  );
  final stderrSubscription = process.stderr.listen(
    (chunk) {
      final remaining = runtimeStderrLimit - bytes.length;
      if (chunk.length > remaining) truncated = true;
      bytes.addAll(chunk.take(remaining));
    },
    onDone: stderrDone.complete,
    onError: stderrDone.completeError,
    cancelOnError: true,
  );
  var timedOut = false;
  int? exitCode;
  final exited = process.exitCode.then((value) => exitCode = value);
  try {
    await Future.wait<Object?>([
      exited,
      stdoutDone.future,
      stderrDone.future,
    ]).timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    process.kill(ProcessSignal.sigkill);
    exitCode = await exited.timeout(const Duration(seconds: 5));
  } finally {
    if (exitCode == null) process.kill(ProcessSignal.sigkill);
    // 부모가 끝나도 후손이 파이프를 보유할 수 있다. 제한 시간 뒤에는 EOF를 기다리지 않는다.
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
  }
  final stderrText = utf8.decode(bytes, allowMalformed: true);
  return RuntimeExecution(
    entrypoint: entrypoint,
    exitCode: exitCode!,
    timedOut: timedOut,
    stderrSummary: truncated ? '$stderrText\n… (stderr truncated)' : stderrText,
  );
}
