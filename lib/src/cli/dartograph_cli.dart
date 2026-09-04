import 'dart:io';

/// CI 호출자가 의존하는 안정적인 프로세스 결과다.
enum ExitStatus {
  /// 임계값을 넘는 발견 없이 명령이 끝났다.
  success(0),

  /// strict 명령이 보고할 문제를 발견했다.
  findings(1),

  /// 분석을 신뢰할 수 있게 마치지 못했다.
  failure(2),

  /// 인자가 유효한 호출을 나타내지 않는다.
  usage(64);

  const ExitStatus(this.code);

  /// CLI 계약이 약속하는 프로세스 종료 코드다.
  final int code;
}

/// 명령줄 경계를 실행하고 프로세스 종료 코드를 돌려준다.
int runDartograph(
  List<String> arguments, {
  StringSink? output,
  StringSink? error,
}) {
  final stdoutSink = output ?? stdout;
  final stderrSink = error ?? stderr;
  final command = arguments.firstOrNull;
  switch (command) {
    case null:
    case '--help':
    case '-h':
      stdoutSink.write(_help);
      return ExitStatus.success.code;
    case '--version':
      stdoutSink.writeln('dartograph 0.1.0-dev');
      return ExitStatus.success.code;
    // 분석 명령이 들어오기 전에도 빌드 산출물이 네 상태를 고정하도록 쓰는 계약 probe다.
    case '_findings':
      return ExitStatus.findings.code;
    case '_failure':
      stderrSink.writeln('Analysis failed: contract probe');
      return ExitStatus.failure.code;
    default:
      stderrSink.write(_help);
      return ExitStatus.usage.code;
  }
}

const _help = '''
dartograph — dependency graphs for Dart and Flutter codebases

Usage: dartograph [--help] [--version]

Exit codes:
  0   success
  1   findings with --strict, or a configured threshold exceeded
  2   analysis failure
  64  usage error
''';
