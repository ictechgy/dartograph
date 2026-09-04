import 'dart:io';
import 'dart:convert';

import '../analysis/reachability_analyzer.dart';
import '../export/graph_exporter.dart';
import '../index/analyzer_graph_index.dart';

/// 패키지 경로를 analyzer 그래프로 바꾸는 주입 가능한 경계다.
typedef IndexPackage = Future<AnalyzerGraphResult> Function(String rootPath);

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
Future<int> runDartograph(
  List<String> arguments, {
  StringSink? output,
  StringSink? error,
  IndexPackage? indexPackage,
}) async {
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
    case 'graph':
      return await _runGraph(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
        indexPackage ?? AnalyzerGraphIndex().index,
      );
    case 'dead':
      return await _runDead(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
        indexPackage ?? AnalyzerGraphIndex().index,
      );
    default:
      stderrSink.write(_help);
      return ExitStatus.usage.code;
  }
}

Future<int> _runDead(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
) async {
  String? explainId;
  late String rootPath;
  if (arguments.length == 3 &&
      arguments[0] == '--format' &&
      arguments[1] == 'json') {
    rootPath = arguments[2];
  } else if (arguments.length == 5 &&
      arguments[0] == '--explain' &&
      arguments[2] == '--format' &&
      arguments[3] == 'json') {
    explainId = arguments[1];
    rootPath = arguments[4];
  } else {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(rootPath);
    final limitations = indexed.limitations.map(_describeLimitation).toList()
      ..sort();
    final result = ReachabilityAnalyzer().analyze(
      indexed.graph.snapshot(),
      roots: indexed.retentionRoots,
      limitations: limitations,
    );
    if (explainId != null) {
      final explanation = result.explain(explainId);
      output.writeln(jsonEncode(explanation.toJson()));
      return explanation.reachable
          ? ExitStatus.success.code
          : ExitStatus.findings.code;
    }
    final findings = [...result.deadDeclarations, ...result.deadFiles]
      ..sort((a, b) {
        final kindOrder = a.kind.compareTo(b.kind);
        return kindOrder != 0 ? kindOrder : a.id.compareTo(b.id);
      });
    output.writeln(
      jsonEncode({
        'findings': findings.map((finding) => finding.toJson()).toList(),
        'limitations': limitations,
      }),
    );
    return findings.isEmpty
        ? ExitStatus.success.code
        : ExitStatus.findings.code;
  } on FileSystemException {
    return _reportAnalysisFailure(error);
  } on ArgumentError {
    return _reportAnalysisFailure(error);
  } on StateError {
    return _reportAnalysisFailure(error);
  } on Exception {
    return _reportAnalysisFailure(error);
  }
}

Future<int> _runGraph(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
) async {
  if (arguments.length != 3 || arguments[0] != '--format') {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  final format = arguments[1];
  if (!const {'dot', 'json', 'mermaid'}.contains(format)) {
    error.writeln('Unknown graph format: $format');
    return ExitStatus.usage.code;
  }
  try {
    final result = await indexPackage(arguments[2]);
    final limitations = result.limitations.map(_describeLimitation);
    final snapshot = result.graph.snapshot();
    output.write(switch (format) {
      'dot' => GraphExporter.dot(snapshot, limitations: limitations),
      'json' => GraphExporter.json(snapshot, limitations: limitations),
      _ => GraphExporter.mermaid(snapshot, limitations: limitations),
    });
    return ExitStatus.success.code;
  } on FileSystemException {
    return _reportAnalysisFailure(error);
  } on ArgumentError {
    return _reportAnalysisFailure(error);
  } on StateError {
    return _reportAnalysisFailure(error);
  } on Exception {
    return _reportAnalysisFailure(error);
  }
}

int _reportAnalysisFailure(StringSink error) {
  error.writeln('Analysis failed: unable to index the package.');
  return ExitStatus.failure.code;
}

String _describeLimitation(
  AnalyzerLimitation limitation,
) => switch (limitation) {
  AnalyzerLimitation.conditionalConfiguration =>
    'conditional imports and exports use one analyzer configuration',
  AnalyzerLimitation.generatedCodeRetention =>
    'generated declarations are conservative retention roots',
  AnalyzerLimitation.testCodeRetention =>
    'tests and visibleForTesting declarations are conservative retention roots',
  AnalyzerLimitation.ambiguousPluginEntryPoint =>
    'multiple declarations matched a plugin entry point; all were retained',
  AnalyzerLimitation.unresolvedPluginEntryPoint =>
    'a declared plugin entry point was not found in the graph',
};

const _help = '''
dartograph — dependency graphs for Dart and Flutter codebases

Usage: dartograph [--help] [--version]
       dartograph graph --format <dot|json|mermaid> <package-root>
       dartograph dead [--explain <symbol-id>] --format json <package-root>

Exit codes:
  0   success
  1   findings with --strict, or a configured threshold exceeded
  2   analysis failure
  64  usage error
''';
