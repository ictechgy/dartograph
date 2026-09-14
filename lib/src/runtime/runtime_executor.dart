import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'runtime_facts.dart';

/// `--execute`의 기본 제한 시간이다.
const runtimeExecutionTimeout = Duration(seconds: 60);

/// 실행 증거로 싣는 stderr 바이트 상한이다.
const runtimeStderrLimit = 4096;

/// `--execute`가 띄울 dart 실행 파일을 해석한 결과다.
///
/// [path]가 있으면 그 경로로 실행하고 [evidence]가 어디서 찾았는지를 밝힌다.
/// 못 찾으면 [reason]에 사유를 남기고 **실행하지 않는다** — 찾지 못한 채 다른
/// 실행 파일을 추측해서 띄우면 보고서의 실행 증거가 다른 프로그램의 것이 된다.
final class DartExecutableLookup {
  const DartExecutableLookup._({this.path, this.evidence, this.reason});

  /// 찾은 실행 파일로 만든다.
  const DartExecutableLookup.found(String path, String evidence)
    : this._(path: path, evidence: evidence);

  /// 찾지 못한 결과로 만든다.
  const DartExecutableLookup.unresolved(String reason) : this._(reason: reason);

  /// dart 실행 파일의 경로다. 찾지 못했으면 null이다.
  final String? path;

  /// 어디서 찾았는지에 대한 근거다(`the running VM`·`DART_SDK`·`PATH`).
  final String? evidence;

  /// 찾지 못한 사유다. 찾았으면 null이다.
  final String? reason;

  /// 실행 파일을 찾았는지 여부다.
  bool get found => path != null;
}

/// `dart run <entrypoint>`가 쓸 dart 실행 파일을 해석한다.
///
/// `dart compile exe`로 만든 바이너리에서는 [Platform.resolvedExecutable]이 그
/// 바이너리 자신이라 dart VM이 아니다. 그대로 실행하면 dartograph가 자기 자신을
/// `run <entrypoint>`로 다시 띄워 usage(64)로 끝난다. 그래서 다음 순서로 찾는다.
///
/// 1. 실행 중인 실행 파일의 이름이 `dart`/`dart.exe`면 그것이 VM이다.
/// 2. `DART_SDK` 환경변수가 가리키는 SDK의 `bin/dart`(`.exe`).
/// 3. `PATH`의 각 디렉터리에서 찾은 `dart`(`.exe`).
/// 4. 모두 실패하면 실행하지 않고 사유를 돌려준다.
///
/// [resolvedExecutable]·[environment]·[windows]·[executableAt]은 호스트 관측의
/// 주입점이다(기본값은 실제 플랫폼 값). `DART_SDK`의 값 자체는 사유에 싣지
/// 않는다 — 환경변수 값은 보고서에 넣지 않는 규칙을 따른다.
DartExecutableLookup resolveDartExecutable({
  String? resolvedExecutable,
  Map<String, String>? environment,
  bool? windows,
  bool Function(String path)? executableAt,
}) {
  final running = resolvedExecutable ?? Platform.resolvedExecutable;
  final variables = environment ?? Platform.environment;
  final isWindows = windows ?? Platform.isWindows;
  final isExecutable = executableAt ?? _isExecutableFile;
  final suffixes = isWindows ? const ['.exe', ''] : const [''];

  if (_isDartVmName(running)) {
    return DartExecutableLookup.found(running, 'the running VM');
  }

  final sdk = variables['DART_SDK'];
  if (sdk != null && sdk.isNotEmpty) {
    for (final suffix in suffixes) {
      final candidate = p.join(sdk, 'bin', 'dart$suffix');
      if (isExecutable(candidate)) {
        return DartExecutableLookup.found(candidate, 'DART_SDK');
      }
    }
  }

  final pathValue = variables['PATH'];
  if (pathValue != null && pathValue.isNotEmpty) {
    final separator = isWindows ? ';' : ':';
    for (final directory in pathValue.split(separator)) {
      if (directory.isEmpty) continue;
      for (final suffix in suffixes) {
        final candidate = p.join(directory, 'dart$suffix');
        if (isExecutable(candidate)) {
          return DartExecutableLookup.found(candidate, 'PATH');
        }
      }
    }
  }

  return DartExecutableLookup.unresolved(
    'dart-executable-not-found: the running executable '
    '"${p.basename(running)}" is not the dart VM, and no dart executable was '
    'found in DART_SDK or PATH',
  );
}

/// [path]의 basename이 dart VM의 이름인지 확인한다.
bool _isDartVmName(String path) {
  final name = p.basename(path).toLowerCase();
  return name == 'dart' || name == 'dart.exe';
}

/// [path]가 실행 가능한 파일인지 확인한다(주입하지 않았을 때의 호스트 관측).
bool _isExecutableFile(String path) {
  final stat = FileStat.statSync(path);
  if (stat.type != FileSystemEntityType.file) return false;
  if (Platform.isWindows) return true;
  // 0o111: 소유자·그룹·기타 실행 비트 중 하나라도 서 있으면 실행 가능하다.
  return stat.mode & 0x49 != 0;
}

/// `dart run <entrypoint>`를 자식 프로세스로 실행하고 결과를 요약한다.
///
/// **임의 코드를 실행한다.** 기본은 미실행이며 `--execute`를 준 호출만 여기
/// 들어온다. 자식의 stdout은 버리고 stdout·stderr 파이프는 항상 소진한다 —
/// 읽지 않은 파이프는 자식이 쓰다 멈추게 하고, 요약은 bounded로 잘라 메모리를
/// 상한 안에 둔다.
///
/// [environment]가 있으면 상속 환경 위에 덮어쓴다(`--env`로 판정한 값을 실제로
/// 적용해 본다). null이면 상속 환경을 그대로 쓴다.
///
/// [executableLookup]은 실행 파일 해석의 주입점이다. 주지 않으면
/// [resolveDartExecutable]로 찾고, 찾지 못하면 실행하지 않은 채 사유만 남긴다.
Future<RuntimeExecution> executeEntrypoint({
  required String entrypoint,
  required String rootPath,
  Map<String, String>? environment,
  Duration timeout = runtimeExecutionTimeout,
  DartExecutableLookup? executableLookup,
}) async {
  final lookup = executableLookup ?? resolveDartExecutable();
  final dart = lookup.path;
  if (dart == null) {
    return RuntimeExecution.unresolved(
      entrypoint: entrypoint,
      reason: lookup.reason ?? 'dart-executable-not-found',
    );
  }
  final process = await Process.start(
    dart,
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
