import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../analysis/baseline.dart';
import '../analysis/architecture_metrics.dart';
import '../analysis/cycle_detector.dart';
import '../analysis/layer_rules.dart';
import '../analysis/reachability_analyzer.dart';
import '../analysis/symbol_query.dart';
import '../export/bridge_exporter.dart';
import '../export/analysis_reporter.dart';
import '../export/dead_reporter.dart';
import '../export/graph_exporter.dart';
import '../index/analyzer_graph_index.dart';
import '../index/bridge_index.dart';
import 'agent_skill.dart';
import 'changed_files.dart';

/// 패키지 경로를 analyzer 그래프로 바꾸는 주입 가능한 경계다.
typedef IndexPackage = Future<AnalyzerGraphResult> Function(String rootPath);

/// `--since`의 Git 접근을 대체할 수 있는 테스트 경계다.
typedef ChangedFilesSince =
    Future<Set<String>> Function(String reference, String rootPath);

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
  ChangedFilesSince? changedFilesSince,
  DateTime Function()? now,
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
    case 'baseline':
      return await _runBaseline(
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
        changedFilesSince ?? ChangedFiles.since,
      );
    case 'query':
      return await _runQuery(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
        indexPackage ?? AnalyzerGraphIndex().index,
      );
    case 'skill':
      return await _runSkill(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
      );
    case 'bridges':
      return await _runBridges(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
        now ?? DateTime.now,
      );
    case 'cycles':
      return await _runCycles(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
        indexPackage ?? AnalyzerGraphIndex().index,
      );
    case 'rules':
      return await _runRules(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
        indexPackage ?? AnalyzerGraphIndex().index,
      );
    case 'metrics':
      return await _runMetrics(
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

Future<int> _runCycles(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
) async {
  final parsed = _strictRoot(arguments);
  if (parsed == null) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(parsed.root);
    final cycles = CycleDetector().detect(indexed.graph.snapshot());
    output.write(
      AnalysisReporter.cycles(cycles, limitations: _limitations(indexed)),
    );
    return parsed.strict && cycles.isNotEmpty
        ? ExitStatus.findings.code
        : ExitStatus.success.code;
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

Future<int> _runRules(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
) async {
  var strict = false;
  String? config;
  String? root;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--strict') {
      if (strict) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      strict = true;
    } else if (argument == '--config' && config == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      config = arguments[index];
    } else if (!argument.startsWith('-') && root == null) {
      root = argument;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  if (config == null || root == null) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final ruleSet = LayerRuleSet.parse(await File(config).readAsString());
    final indexed = await indexPackage(root);
    final violations = LayerRuleEvaluator(
      ruleSet,
    ).evaluate(indexed.graph.snapshot());
    output.write(
      AnalysisReporter.rules(violations, limitations: _limitations(indexed)),
    );
    return strict && violations.isNotEmpty
        ? ExitStatus.findings.code
        : ExitStatus.success.code;
  } on FileSystemException {
    return _reportAnalysisFailure(error);
  } on FormatException {
    return _reportAnalysisFailure(error);
  } on ArgumentError {
    return _reportAnalysisFailure(error);
  } on StateError {
    return _reportAnalysisFailure(error);
  } on Exception {
    return _reportAnalysisFailure(error);
  }
}

Future<int> _runMetrics(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
) async {
  final parsed = _strictRoot(arguments);
  if (parsed == null) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(parsed.root);
    final metrics = ArchitectureMetricsCalculator().calculate(
      indexed.graph.snapshot(),
    );
    const tolerance = 0.3;
    output.write(
      AnalysisReporter.metrics(
        metrics,
        limitations: _limitations(indexed),
        tolerance: tolerance,
      ),
    );
    final exceedsTolerance = metrics.any(
      (item) => !item.isolated && item.distance > tolerance,
    );
    return parsed.strict && exceedsTolerance
        ? ExitStatus.findings.code
        : ExitStatus.success.code;
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

({String root, bool strict})? _strictRoot(List<String> arguments) {
  if (arguments.length == 1 && !arguments.single.startsWith('-')) {
    return (root: arguments.single, strict: false);
  }
  if (arguments.length == 2 &&
      arguments.where((item) => item == '--strict').length == 1) {
    final root = arguments.firstWhere((item) => item != '--strict');
    if (!root.startsWith('-')) return (root: root, strict: true);
  }
  return null;
}

Future<int> _runQuery(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
) async {
  String? baselinePath;
  late final String requested;
  late final String rootPath;
  if (arguments.length == 2) {
    requested = arguments[0];
    rootPath = arguments[1];
  } else if (arguments.length == 4 && arguments[1] == '--baseline') {
    requested = arguments[0];
    baselinePath = arguments[2];
    rootPath = arguments[3];
  } else {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(rootPath);
    final limitations = _limitations(indexed);
    final suppressedIds = <String>{};
    if (baselinePath != null) {
      final baseline = await BaselineStore.read(File(baselinePath));
      final reachability = ReachabilityAnalyzer().analyze(
        indexed.graph.snapshot(),
        roots: indexed.retentionRoots,
        limitations: limitations,
      );
      for (final finding in reachability.deadDeclarations) {
        if (baseline.filter([finding]).suppressedCount == 1) {
          suppressedIds.add(finding.id);
        }
      }
    }
    final document = querySymbol(
      graph: indexed.graph.snapshot(),
      roots: indexed.retentionRoots,
      requested: requested,
      limitations: limitations,
      suppressedIds: suppressedIds,
    );
    output.write(encodeSymbolQueryDocument(document));
    return document['status'] == 'notFound'
        ? ExitStatus.usage.code
        : ExitStatus.success.code;
  } on StateError {
    return _reportAnalysisFailure(error);
  } on Exception {
    return _reportAnalysisFailure(error);
  }
}

Future<int> _runSkill(
  List<String> arguments,
  StringSink output,
  StringSink error,
) async {
  if (arguments.isEmpty) {
    output.write(agentSkillMarkdown);
    return ExitStatus.success.code;
  }
  final force = arguments.length == 3 && arguments[2] == '--force';
  if ((arguments.length != 2 && !force) || arguments[0] != '--install') {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final directory = Directory(p.join(arguments[1], 'dartograph'));
    await directory.create(recursive: true);
    final skill = File(p.join(directory.path, 'SKILL.md'));
    if (await skill.exists() && !force) {
      error.writeln('Skill already exists. Pass --force to overwrite it.');
      return ExitStatus.usage.code;
    }
    await skill.writeAsString(agentSkillMarkdown);
    output.writeln('Installed dartograph skill.');
    return ExitStatus.success.code;
  } on FileSystemException {
    error.writeln(
      'Skill installation failed: check the destination permissions.',
    );
    return ExitStatus.failure.code;
  }
}

Future<int> _runBridges(
  List<String> arguments,
  StringSink output,
  StringSink error,
  DateTime Function() now,
) async {
  if (arguments.length != 3 ||
      arguments[0] != '--format' ||
      arguments[1] != 'json') {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final root = Directory(arguments[2]).absolute.resolveSymbolicLinksSync();
    final indexed = indexBridges(root);
    output.write(
      exportBridgeFacts(
        project: root,
        generatedAt: now(),
        facts: indexed.facts,
        limitations: indexed.limitations,
      ),
    );
    return ExitStatus.success.code;
  } on ArgumentError {
    return _reportAnalysisFailure(error);
  } on StateError {
    return _reportAnalysisFailure(error);
  } on Exception {
    return _reportAnalysisFailure(error);
  }
}

List<String> _limitations(AnalyzerGraphResult result) {
  final details = [...result.limitationDetails];
  for (final limitation in result.limitations) {
    if (limitation == AnalyzerLimitation.conditionalConfiguration &&
        details.any((item) => item.startsWith('conditional-imports:'))) {
      continue;
    }
    details.add(_describeLimitation(limitation));
  }
  return details.toSet().toList()..sort();
}

Future<int> _runDead(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
  ChangedFilesSince changedFilesSince,
) async {
  String? explainId;
  String? baselinePath;
  String? since;
  ReportFormat? reportFormat;
  String? rootPath;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (const {
      '--explain',
      '--format',
      '--baseline',
      '--since',
    }.contains(argument)) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = arguments[index];
      switch (argument) {
        case '--explain':
          explainId = value;
        case '--format':
          reportFormat = value == 'github-actions'
              ? ReportFormat.githubActions
              : ReportFormat.values
                    .where((item) => item.name == value)
                    .firstOrNull;
          if (reportFormat == null) {
            error.writeln('Unknown report format: $value');
            return ExitStatus.usage.code;
          }
        case '--baseline':
          baselinePath = value;
        case '--since':
          since = value;
      }
    } else if (!argument.startsWith('-') && rootPath == null) {
      rootPath = argument;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  if (rootPath == null ||
      reportFormat == null ||
      (explainId != null && reportFormat != ReportFormat.json)) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(rootPath);
    final limitations = _limitations(indexed);
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
    var findings = [...result.deadDeclarations, ...result.deadFiles]
      ..sort((a, b) {
        final kindOrder = a.kind.compareTo(b.kind);
        return kindOrder != 0 ? kindOrder : a.id.compareTo(b.id);
      });
    if (since != null) {
      final changed = await changedFilesSince(since, rootPath);
      final canonicalRoot = await Directory(rootPath).resolveSymbolicLinks();
      final scoped = <DeadFinding>[];
      for (final finding in findings) {
        final source = await _canonicalSource(canonicalRoot, finding.source);
        if (source == null || changed.contains(source)) scoped.add(finding);
      }
      findings = scoped;
    }
    var suppressedCount = 0;
    if (baselinePath != null) {
      final filtered = (await BaselineStore.read(
        File(baselinePath),
      )).filter(findings);
      findings = filtered.findings;
      suppressedCount = filtered.suppressedCount;
    }
    output.write(
      DeadReporter.render(
        reportFormat,
        findings,
        limitations: limitations,
        suppressedCount: suppressedCount,
      ),
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

Future<int> _runBaseline(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
) async {
  if (arguments.length != 3 || arguments[0] != '--write') {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(arguments[2]);
    final limitations = _limitations(indexed);
    final result = ReachabilityAnalyzer().analyze(
      indexed.graph.snapshot(),
      roots: indexed.retentionRoots,
      limitations: limitations,
    );
    final findings = [...result.deadDeclarations, ...result.deadFiles];
    await BaselineStore.write(Baseline.capture(findings), File(arguments[1]));
    output.writeln('Baseline wrote ${findings.length} finding(s).');
    return ExitStatus.success.code;
  } on StateError {
    return _reportAnalysisFailure(error);
  } on Exception {
    return _reportAnalysisFailure(error);
  }
}

Future<String?> _canonicalSource(String rootPath, String source) async {
  if (!source.startsWith('project:')) return null;
  final relative = source.substring('project:'.length);
  final absolute = p.normalize(p.absolute(rootPath, relative));
  try {
    return await File(absolute).resolveSymbolicLinks();
  } on FileSystemException {
    return null;
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
    final limitations = _limitations(result);
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
       dartograph dead [--explain <symbol-id>] --format <text|json|github-actions|sarif> [--baseline <file>] [--since <ref>] <package-root>
       dartograph baseline --write <file> <package-root>
       dartograph query <symbol-id-or-name> [--baseline <file>] <package-root>
       dartograph skill [--install <skills-directory> [--force]]
       dartograph bridges --format json <package-root>
       dartograph cycles [--strict] <package-root>
       dartograph rules --config <yaml-file> [--strict] <package-root>
       dartograph metrics [--strict] <package-root>

Exit codes:
  0   success
  1   findings with --strict, or a configured threshold exceeded
  2   analysis failure
  64  usage error
''';
