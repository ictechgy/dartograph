import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../analysis/baseline.dart';
import '../analysis/architecture_metrics.dart';
import '../analysis/cycle_detector.dart';
import '../analysis/layer_rules.dart';
import '../analysis/reachability_analyzer.dart';
import '../analysis/symbol_query.dart';
import '../analysis/graph_comparison.dart';
import '../core/tool_info.dart';
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
    case 'compare':
      return _runCompare(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
        indexPackage ?? AnalyzerGraphIndex().index,
      );
    case null:
    case '--help':
    case '-h':
      stdoutSink.write(_help);
      return ExitStatus.success.code;
    case '--version':
      stdoutSink.writeln('dartograph $toolVersion');
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

Future<int> _runCompare(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
) async {
  // 단일 대시도 거부한다. `--`만 보면 `compare -h .`처럼 실재하는 짧은 옵션이
  // 경로가 되어 usage(64) 대신 분석 실패(2)로 보고된다.
  if (arguments.length != 2 || arguments.any((a) => a.startsWith('-'))) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final before = await indexPackage(arguments[0]);
    final after = await indexPackage(arguments[1]);
    output.write(
      encodeSymbolQueryDocument(
        compareGraphs(
          before: before.graph.snapshot(),
          after: after.graph.snapshot(),
          beforeRoots: before.retentionRoots,
          afterRoots: after.retentionRoots,
          beforeLimitations: _limitations(before),
          afterLimitations: _limitations(after),
        ),
      ),
    );
    return ExitStatus.success.code;
  } on Exception {
    return _reportAnalysisFailure(error);
  } on StateError {
    return _reportAnalysisFailure(error);
  }
}

Future<int> _runCycles(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
) async {
  var strict = false;
  String? explainId;
  String? root;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--strict') {
      if (strict) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      strict = true;
    } else if (argument == '--explain') {
      // 값은 경로가 아니라 심볼 ID다. dead --explain과 같이 대시 가드를 적용하지
      // 않는다. 값이 빠진 오타는 뒤따르는 위치 인자가 남아 usage(64)로 떨어진다.
      if (explainId != null) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      explainId = arguments[index];
    } else if (!argument.startsWith('-') && root == null) {
      root = argument;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  // --explain은 한 정점의 근거를 묻는 질의라 finding 게이트(--strict)와 결합하지
  // 않는다. dead --explain이 --baseline/--since를 배제하는 것과 같은 철학이다.
  if (root == null || (strict && explainId != null)) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(root);
    final limitations = _limitations(indexed);
    if (explainId != null) {
      final explanation = CycleDetector().explain(
        indexed.graph.snapshot(),
        explainId,
      );
      output.write(
        AnalysisReporter.cyclesExplain(explanation, limitations: limitations),
      );
      return explanation.known
          ? ExitStatus.success.code
          : ExitStatus.usage.code;
    }
    final cycles = CycleDetector().detect(indexed.graph.snapshot());
    output.write(AnalysisReporter.cycles(cycles, limitations: limitations));
    return strict && cycles.isNotEmpty
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
  String? explainId;
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
      // 값이 빠진 호출에서 다음 옵션이 config 파일 경로가 되면 안 된다.
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      config = arguments[index];
    } else if (argument == '--explain' && explainId == null) {
      // 값은 경로가 아니라 심볼 ID다. dead --explain과 같이 대시 가드를 적용하지
      // 않는다. 값이 빠진 오타는 뒤따르는 위치 인자가 남아 usage(64)로 떨어진다.
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      explainId = arguments[index];
    } else if (!argument.startsWith('-') && root == null) {
      root = argument;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  // --explain은 한 정점의 레이어 배치를 묻는 질의라 finding 게이트(--strict)와
  // 결합하지 않는다. 레이어 배치는 ruleset에 의존하므로 --config는 계속 필요하다.
  if (config == null || root == null || (strict && explainId != null)) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  final LayerRuleSet ruleSet;
  try {
    ruleSet = LayerRuleSet.parse(await File(config).readAsString());
  } on FileSystemException {
    // config 파일 부재·읽기 실패는 인덱싱 실패와 다르다. 원인을 반대로 가리키지 않게
    // 구분하되, 기존 계약(phase5_cli_test)이 단언하는 "Analysis failed:" 접두는 유지한다.
    return _reportRulesConfigFailure(error);
  } on FormatException {
    return _reportRulesConfigFailure(error);
  }
  try {
    final indexed = await indexPackage(root);
    final limitations = _limitations(indexed);
    if (explainId != null) {
      final explanation = LayerRuleEvaluator(
        ruleSet,
      ).explainNode(indexed.graph.snapshot(), explainId);
      output.write(
        AnalysisReporter.rulesExplain(explanation, limitations: limitations),
      );
      return explanation.known
          ? ExitStatus.success.code
          : ExitStatus.usage.code;
    }
    final violations = LayerRuleEvaluator(
      ruleSet,
    ).evaluate(indexed.graph.snapshot());
    output.write(AnalysisReporter.rules(violations, limitations: limitations));
    return strict && violations.isNotEmpty
        ? ExitStatus.findings.code
        : ExitStatus.success.code;
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
  String? batchPath;
  late final List<String> requests;
  late final String rootPath;
  // `--depth`/`--limit`은 위치 인자 사이에 어디든 올 수 있다. 먼저 뽑아내고
  // 남은 위치 인자만 기존 형태 계약으로 검증한다. 값이 빠졌거나(다음 토큰이
  // 옵션이거나 없음) 1 미만·비정수면 usage(64)다. cartograph와 같은 하한이다.
  // 중복 플래그는 last-wins로 조용히 받아들이지 않는다. 같은 CLI의 `--config`·
  // `--baseline` 중복 거부와 일관되게 usage(64)다.
  int? depthOption;
  int? limitOption;
  final positional = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument != '--depth' && argument != '--limit') {
      positional.add(argument);
      continue;
    }
    if ((argument == '--depth' && depthOption != null) ||
        (argument == '--limit' && limitOption != null)) {
      error.write(_help);
      return ExitStatus.usage.code;
    }
    if (index + 1 >= arguments.length) {
      error.write(_help);
      return ExitStatus.usage.code;
    }
    final value = int.tryParse(arguments[++index]);
    if (value == null || value < 1) {
      error.write(_help);
      return ExitStatus.usage.code;
    }
    if (argument == '--depth') {
      depthOption = value;
    } else {
      limitOption = value;
    }
  }
  final depth = depthOption ?? 1;
  final limit = limitOption;
  if (positional.length >= 3 &&
      positional[0] == '--batch' &&
      (positional.length == 3 ||
          (positional.length == 5 && positional[2] == '--baseline'))) {
    batchPath = positional[1];
    rootPath = positional.last;
    if (rootPath.startsWith('-')) {
      error.write(_help);
      return ExitStatus.usage.code;
    }
    if (positional.length == 5) baselinePath = positional[3];
    try {
      final file = File(batchPath);
      if (await file.length() > 1024 * 1024) throw const FormatException();
      final value = jsonDecode(await file.readAsString());
      if (value is! List ||
          value.isEmpty ||
          value.length > 1000 ||
          value.any((item) => item is! String || item.trim().isEmpty)) {
        throw const FormatException();
      }
      requests = value.cast<String>();
    } on Exception {
      error.writeln(
        'Invalid batch: provide a JSON array of 1–1000 non-empty symbol names (maximum 1 MiB).',
      );
      return ExitStatus.usage.code;
    }
    // 옵션 모양의 값은 경로로 받지 않는다. 받으면 값이 빠진 호출이 usage(64)가
    // 아니라 분석 실패(2)로 보고돼 사용자가 원인을 잘못 찾는다. 위 batch 분기와
    // 같은 기준이며, `-`로 시작하는 실제 경로는 `./-name`으로 전달한다.
  } else if (positional.length == 2 &&
      !positional.first.startsWith('--') &&
      !positional[1].startsWith('-')) {
    requests = [positional[0]];
    rootPath = positional[1];
  } else if (positional.length == 4 &&
      positional[1] == '--baseline' &&
      !positional[2].startsWith('-') &&
      !positional[3].startsWith('-')) {
    requests = [positional[0]];
    baselinePath = positional[2];
    rootPath = positional[3];
  } else {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(rootPath);
    final limitations = _limitations(indexed);
    final session = SymbolQuerySession(
      graph: indexed.graph.snapshot(),
      roots: indexed.retentionRoots,
      limitations: limitations,
    );
    final suppressedIds = <String>{};
    if (baselinePath != null) {
      final baseline = await _readBaseline(File(baselinePath));
      final findings = session.analysis.deadDeclarations;
      final remaining = baseline
          .filter(findings)
          .findings
          .map((f) => f.id)
          .toSet();
      for (final finding in findings) {
        if (!remaining.contains(finding.id)) suppressedIds.add(finding.id);
      }
    }
    final results = [
      for (final requested in requests)
        session.query(
          requested,
          suppressedIds: suppressedIds,
          depth: depth,
          limit: limit,
        ),
    ];
    final document = batchPath == null
        ? results.single
        : <String, Object?>{
            'format': 'symbol-query-batch',
            'version': 1,
            'results': results,
          };
    output.write(encodeSymbolQueryDocument(document));
    return results.any((result) => result['status'] == 'notFound')
        ? ExitStatus.usage.code
        : ExitStatus.success.code;
  } on _InvalidBaseline {
    return _reportInvalidBaseline(error);
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
  if ((arguments.length != 2 && !force) ||
      arguments[0] != '--install' ||
      arguments[1].startsWith('-')) {
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
  final rootIndex = arguments.length == 4 && arguments[2] == '--' ? 3 : 2;
  // 이스케이프 없이 온 옵션 모양의 값은 경로로 받지 않는다. 길이 검사가 먼저라
  // 짧은 호출에서 인덱스를 벗어나지 않는다. `-`로 시작하는 실제 경로는 이미
  // 있는 `--` 이스케이프로 전달한다.
  if (arguments.length != rootIndex + 1 ||
      arguments[0] != '--format' ||
      arguments[1] != 'json' ||
      (rootIndex == 2 && arguments[2].startsWith('-'))) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final root = Directory(
      arguments[rootIndex],
    ).absolute.resolveSymbolicLinksSync();
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
  var reportTestOnly = false;
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
          // 값은 경로가 아니라 심볼 ID다. `<no-library>`처럼 특수한 형태가
          // 있으므로 대시 가드를 적용하지 않는다. 값이 빠진 오타는 뒤따르는
          // 위치 인자가 남아 이미 usage(64)로 떨어진다.
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
          // 값이 빠진 호출에서 다음 옵션이 baseline 파일 경로가 되면 안 된다.
          if (value.startsWith('-')) {
            error.write(_help);
            return ExitStatus.usage.code;
          }
          baselinePath = value;
        case '--since':
          // git ref는 `-`로 시작할 수 없으므로 같은 기준을 적용한다.
          if (value.startsWith('-')) {
            error.write(_help);
            return ExitStatus.usage.code;
          }
          since = value;
      }
    } else if (argument == '--report-test-only') {
      if (reportTestOnly) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      reportTestOnly = true;
    } else if (!argument.startsWith('-') && rootPath == null) {
      rootPath = argument;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  // --report-test-only는 "테스트가 유일한 호출자인 프로덕션 선언"이라는 다른
  // 질문을 info로 답한다. 단일 대상을 묻는 --explain, dead finding을 억제하는
  // --baseline과는 결합하지 않는다(--since는 보고 위치만 좁히므로 허용).
  if (rootPath == null ||
      reportFormat == null ||
      (explainId != null &&
          (reportFormat != ReportFormat.json ||
              baselinePath != null ||
              since != null ||
              reportTestOnly)) ||
      (reportTestOnly && baselinePath != null)) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(rootPath);
    final limitations = _limitations(indexed);
    final analyzer = ReachabilityAnalyzer();
    final snapshot = indexed.graph.snapshot();
    if (explainId != null) {
      final explanation = analyzer
          .analyze(
            snapshot,
            roots: indexed.retentionRoots,
            limitations: limitations,
          )
          .explain(explainId);
      output.writeln(jsonEncode(explanation.toJson()));
      return !explanation.known
          ? ExitStatus.usage.code
          : explanation.reachable
          ? ExitStatus.success.code
          : ExitStatus.findings.code;
    }
    // --report-test-only는 "테스트가 유일한 호출자인 프로덕션 선언"을 info로
    // 답한다. 죽은 코드가 아니므로 finding이 있어도 빌드를 실패시키지 않는다.
    final report = reportTestOnly ? DeadReport.testOnly : DeadReport.dead;
    final List<DeadFinding> findings;
    if (reportTestOnly) {
      findings = analyzer.testOnlyDeclarations(
        snapshot,
        roots: indexed.retentionRoots,
        limitations: limitations,
      );
    } else {
      final result = analyzer.analyze(
        snapshot,
        roots: indexed.retentionRoots,
        limitations: limitations,
      );
      findings = [...result.deadDeclarations, ...result.deadFiles]
        ..sort((a, b) {
          final kindOrder = a.kind.compareTo(b.kind);
          return kindOrder != 0 ? kindOrder : a.id.compareTo(b.id);
        });
    }
    var reported = findings;
    if (since != null) {
      final changed = await changedFilesSince(since, rootPath);
      final canonicalRoot = await Directory(rootPath).resolveSymbolicLinks();
      final scoped = <DeadFinding>[];
      for (final finding in reported) {
        final source = await _canonicalSource(canonicalRoot, finding.source);
        if (source == null || changed.contains(source)) scoped.add(finding);
      }
      reported = scoped;
    }
    var suppressedCount = 0;
    if (baselinePath != null) {
      final filtered = (await _readBaseline(
        File(baselinePath),
      )).filter(reported);
      reported = filtered.findings;
      suppressedCount = filtered.suppressedCount;
    }
    output.write(
      DeadReporter.render(
        reportFormat,
        reported,
        limitations: limitations,
        suppressedCount: suppressedCount,
        report: report,
      ),
    );
    if (reportTestOnly) return ExitStatus.success.code;
    return reported.isEmpty
        ? ExitStatus.success.code
        : ExitStatus.findings.code;
  } on _InvalidBaseline {
    return _reportInvalidBaseline(error);
  } on ChangedFilesException {
    error.writeln(
      'Changed files could not be computed. In CI, fetch full Git history.',
    );
    return ExitStatus.failure.code;
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
  // 옵션 모양의 값을 경로로 받으면 `baseline --write --force .`이 `--force`라는
  // 이름의 파일을 실제로 만들고 성공을 보고한다. 인덱싱과 쓰기 전에 거부한다.
  // `-`로 시작하는 실제 경로는 `./-name`으로 전달한다.
  if (arguments.length != 3 ||
      arguments[0] != '--write' ||
      arguments[1].startsWith('-') ||
      arguments[2].startsWith('-')) {
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
  // 옵션 모양의 값은 경로로 받지 않는다. `-`로 시작하는 실제 경로는
  // `./-name`으로 전달한다.
  if (arguments.length != 3 ||
      arguments[0] != '--format' ||
      arguments[2].startsWith('-')) {
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

int _reportRulesConfigFailure(StringSink error) {
  error.writeln('Analysis failed: unable to read the rules configuration.');
  return ExitStatus.failure.code;
}

Future<Baseline> _readBaseline(File file) async {
  try {
    return await BaselineStore.read(file);
  } on FormatException {
    throw const _InvalidBaseline();
  } on FileSystemException {
    // baseline 경로가 없으면 PathNotFoundException(FileSystemException)이 난다.
    // 이를 인덱싱 실패("unable to index the package")로 뭉개면 원인을 반대로 가리킨다.
    // _reportInvalidBaseline의 "create it with baseline --write" 안내가 부재에도 맞다.
    throw const _InvalidBaseline();
  }
}

int _reportInvalidBaseline(StringSink error) {
  error.writeln(
    'Baseline is invalid: create it with dartograph baseline --write.',
  );
  return ExitStatus.failure.code;
}

final class _InvalidBaseline implements Exception {
  const _InvalidBaseline();
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
       dartograph dead --report-test-only --format <text|json|github-actions|sarif> [--since <ref>] <package-root>
       dartograph baseline --write <file> <package-root>
       dartograph query <symbol-id-or-name> [--baseline <file>] [--depth <n>] [--limit <n>] <package-root>
       dartograph query --batch <requests.json> [--baseline <file>] [--depth <n>] [--limit <n>] <package-root>
       dartograph compare <before-package-root> <after-package-root>
       dartograph skill [--install <skills-directory> [--force]]
       dartograph bridges --format json <package-root>
       dartograph cycles [--strict] <package-root>
       dartograph cycles --explain <symbol-id> <package-root>
       dartograph rules --config <yaml-file> [--strict] <package-root>
       dartograph rules --config <yaml-file> --explain <symbol-id> <package-root>
       dartograph metrics [--strict] <package-root>

dead --explain requires --format json and does not combine with --baseline or
--since. dead --report-test-only answers a different question (production
declarations reached only from test code) at info severity, so it never fails
the build and does not combine with --explain or --baseline. cycles/rules
--explain answer for one symbol and do not combine with --strict; an id absent
from the graph is reported as known:false with exit 64.

Paths and files that begin with "-" are rejected as usage errors so that a
missing option value is not silently consumed. Pass such a path as "./-name".

Exit codes:
  0   success
  1   dead findings, or cycles/rules/metrics findings with --strict
  2   analysis failure
  64  usage error
''';
