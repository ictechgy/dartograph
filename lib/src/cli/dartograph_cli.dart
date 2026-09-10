import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../analysis/affected_analyzer.dart';
import '../analysis/baseline.dart';
import '../analysis/architecture_metrics.dart';
import '../analysis/graph_projection.dart';
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
  try {
    return await _dispatch(
      arguments,
      stdoutSink,
      stderrSink,
      indexPackage,
      changedFilesSince,
      now,
    );
  } on Object {
    // 명령별 catch를 빠져나오는 Error 계열(TypeError·RangeError·
    // StackOverflowError, 그리고 누락된 ArgumentError 분기들)은 기본 핸들러가
    // 스택트레이스(내부·저장소 경로 반향)와 함께 종료 코드 255로 끝나게 한다 —
    // CLI 계약(0/1/2/64)과 경로 미반향 규약 위반이다. 경계에서 마지막으로
    // 분석 실패(2)로 모은다. 상세 분류는 명령별 catch가 먼저 담당한다.
    return _reportAnalysisFailure(stderrSink);
  }
}

Future<int> _dispatch(
  List<String> arguments,
  StringSink stdoutSink,
  StringSink stderrSink,
  IndexPackage? indexPackage,
  ChangedFilesSince? changedFilesSince,
  DateTime Function()? now,
) async {
  final command = arguments.firstOrNull;
  switch (command) {
    case 'affected':
      return await _runAffected(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
        indexPackage ?? AnalyzerGraphIndex().index,
        changedFilesSince ?? ChangedFiles.since,
      );
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

Future<int> _runAffected(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
  ChangedFilesSince changedFilesSince,
) async {
  // 위치 인자 두 개: <git-ref> <package-root>. Git ref는 `-`로 시작하지 않으므로
  // 옵션 모양 값은 오타다. `-`로 시작하는 실제 경로는 `./-name`으로 전달한다.
  if (arguments.length != 2 ||
      arguments[0].startsWith('-') ||
      arguments[1].startsWith('-')) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  final reference = arguments[0];
  final rootPath = arguments[1];
  try {
    // 인덱싱을 먼저 시도해 패키지 루트 부재를 Git 실패로 오귀인하지 않는다
    // (dead --since와 같은 순서).
    final indexed = await indexPackage(rootPath);
    final changed = await changedFilesSince(reference, rootPath);
    final canonicalRoot = await Directory(rootPath).resolveSymbolicLinks();
    final snapshot = indexed.graph.snapshot();
    // dead --since와 같은 양방향 매칭(_changedContains): 링크 경로 자체와
    // 링크 대상 실 경로 양쪽을 변경 집합과 비교한다. `project:` 스킴은
    // 루트 패키지 안 파일 전용이다(projectIdForPath가 루트 밖 경로에는
    // file:// URI를 돌려준다) — 의존 패키지 소스가 같은 스킴으로 오매칭될
    // 여지가 없다.
    final sources = <String>{
      for (final node in snapshot.nodes)
        if (node.sourceUri?.startsWith('project:') ?? false) node.sourceUri!,
    }.toList()..sort();
    final changedSources = <String>{};
    final matchedChangedFiles = <String>{};
    for (final source in sources) {
      final relative = source.substring('project:'.length);
      final absolute = p.normalize(p.join(canonicalRoot, relative));
      final canonical = await _canonicalSource(canonicalRoot, source);
      // dead --since의 _changedContains와 달리 canonical == null(깨진 링크·
      // 소멸 파일)은 매치 실패다: git은 삭제 파일을 변경 집합에 넣지 않으므로
      // 사라진 파일의 라이브러리를 '변경됨' 씨앗으로 보고하면 오보다.
      final matched =
          changed.contains(absolute) ||
          (canonical != null && changed.contains(canonical));
      if (matched) {
        changedSources.add(source);
        matchedChangedFiles
          ..add(absolute)
          ..add(canonical ?? absolute);
      }
    }
    // 패키지 안에 있는데 어떤 분석 라이브러리에도 속하지 않는 변경 Dart 파일은
    // 영향 반경 계산에서 조용히 사라지므로 한계로 남긴다(삭제 파일은 Git 단계에서
    // 이미 제외된다 — ChangedFiles 계약). 소스 URI는 매치됐지만 라이브러리
    // 노드로 귀속되지 못한 경우(unattributedSources)도 같은 한계로 센다.
    final result = AffectedAnalysis.analyze(snapshot, changedSources);
    final unmappedDartFiles =
        changed
            .where(
              (path) =>
                  p.extension(path) == '.dart' &&
                  p.isWithin(canonicalRoot, path) &&
                  !matchedChangedFiles.contains(path),
            )
            .length +
        result.unattributedSources.length;
    final limitations = _limitations(indexed);
    if (unmappedDartFiles > 0) {
      limitations.add(
        'changed-dart-files-without-library: $unmappedDartFiles changed Dart '
        'file(s) are not part of any analyzed library',
      );
    }
    output.write(AnalysisReporter.affected(result, limitations: limitations));
    return ExitStatus.success.code;
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
      final findings = session.deadDeclarations;
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

const _invalidBridgesProjectMessage =
    'Invalid --project: it must be an existing directory containing the '
    'package root.';

Future<int> _runBridges(
  List<String> arguments,
  StringSink output,
  StringSink error,
  DateTime Function() now,
) async {
  // `--project <shared-root>`는 위치 인자 사이에 어디든 올 수 있다(query의
  // `--depth`와 같은 규칙). 중복·값 빠짐·옵션 모양 값은 usage(64)다.
  String? projectOption;
  final positional = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument != '--project') {
      positional.add(argument);
      continue;
    }
    if (projectOption != null || index + 1 >= arguments.length) {
      error.write(_help);
      return ExitStatus.usage.code;
    }
    final value = arguments[++index];
    // 빈 값은 Directory('').absolute가 cwd로 조용히 해석돼 공유 루트가
    // 실행 위치에 따라 달라진다 — 옵션 모양 값과 같이 거부한다.
    if (value.isEmpty || value.startsWith('-')) {
      error.write(_help);
      return ExitStatus.usage.code;
    }
    projectOption = value;
  }
  final rootIndex = positional.length == 4 && positional[2] == '--' ? 3 : 2;
  // 이스케이프 없이 온 옵션 모양의 값은 경로로 받지 않는다. 길이 검사가 먼저라
  // 짧은 호출에서 인덱스를 벗어나지 않는다. `-`로 시작하는 실제 경로는 이미
  // 있는 `--` 이스케이프로 전달한다.
  if (positional.length != rootIndex + 1 ||
      positional[0] != '--format' ||
      positional[1] != 'json' ||
      (rootIndex == 2 && positional[2].startsWith('-'))) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final root = Directory(
      positional[rootIndex],
    ).absolute.resolveSymbolicLinksSync();
    // 프로젝트 루트 우선순위: 명시적 --project > pub workspace 감지 > 스캔
    // 루트. 모노레포 조인은 두 producer 문서가 정확히 같은 project 문자열을
    // 가져야 성립한다(GRAPH-EXCHANGE 정확 문자열 일치 fail-closed) —
    // 공유 루트를 문서 손으로 고쳐 쓰면 provenance가 깨진다(dartograph#38).
    var project = root;
    final projectLimitations = <String>[];
    if (projectOption != null) {
      String resolved;
      try {
        resolved = Directory(projectOption).absolute.resolveSymbolicLinksSync();
      } on FileSystemException {
        error.writeln(_invalidBridgesProjectMessage);
        return ExitStatus.usage.code;
      }
      if (!p.equals(resolved, root) && !p.isWithin(resolved, root)) {
        error.writeln(_invalidBridgesProjectMessage);
        return ExitStatus.usage.code;
      }
      project = resolved;
    } else {
      final detected = _detectPubWorkspace(root);
      if (detected.root != null) {
        project = detected.root!;
      } else if (detected.limitation != null) {
        projectLimitations.add(detected.limitation!);
      }
    }
    final indexed = indexBridges(
      root,
      projectRootPath: project == root ? null : project,
    );
    output.write(
      exportBridgeFacts(
        project: project,
        generatedAt: now(),
        facts: indexed.facts,
        limitations: [...indexed.limitations, ...projectLimitations],
      ),
    );
    return ExitStatus.success.code;
  } on FormatException {
    // 제어문자·빈 fact 값의 전면 거부는 bridges 추출 정책이다(GRAPH-EXCHANGE
    // 계약). 인덱싱 실패로 답하면 원인을 반대로 가리킨다.
    error.writeln(
      'Bridges extraction failed: a fact value or source path contains control characters.',
    );
    return ExitStatus.failure.code;
  } on ArgumentError {
    return _reportAnalysisFailure(error);
  } on StateError {
    return _reportAnalysisFailure(error);
  } on Exception {
    return _reportAnalysisFailure(error);
  }
}

/// pub workspace 감지 결과 — 공유 프로젝트 루트와 감시 실패 한계다.
final class _WorkspaceDetection {
  const _WorkspaceDetection(this.root, this.limitation);

  final String? root;
  final String? limitation;
}

/// [rootPath]의 pubspec이 `resolution: workspace`를 선언하면 `workspace:` 키를
/// 가진 가장 가까운 조상 pubspec의 디렉터리를 프로젝트 루트로 돌려준다(Dart
/// Pub Workspaces — Melos의 "workspace: 키를 가진 루트" 정의와 같다).
///
/// 선언이 없으면 (null, null)로 기존 행동(project = 스캔 루트)을 보존한다.
/// 선언했는데 루트를 찾지 못하거나 pubspec을 파싱할 수 없으면 null 루트와
/// limitation을 돌려준다 — 조인 기준이 조용히 어긋나면 isthmus의 정확 문자열
/// 일치 fail-closed만 관측되므로 원인을 출력에 남긴다.
_WorkspaceDetection _detectPubWorkspace(String rootPath) {
  Object? document;
  try {
    final pubspec = File(p.join(rootPath, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return const _WorkspaceDetection(null, null);
    document = loadYaml(pubspec.readAsStringSync());
  } on Exception {
    return const _WorkspaceDetection(
      null,
      'pub-workspace-pubspec-unparsed: pubspec.yaml could not be parsed for '
      'workspace detection; project fell back to the package root',
    );
  }
  if (document is! YamlMap || document['resolution'] != 'workspace') {
    return const _WorkspaceDetection(null, null);
  }
  var directory = Directory(rootPath).parent;
  while (true) {
    final candidate = File(p.join(directory.path, 'pubspec.yaml'));
    if (candidate.existsSync()) {
      try {
        final parsed = loadYaml(candidate.readAsStringSync());
        if (parsed is YamlMap && parsed['workspace'] != null) {
          final workspaceRoot = directory.resolveSymbolicLinksSync();
          if (_workspaceListsMember(
            workspaceRoot,
            parsed['workspace'],
            rootPath,
          )) {
            return _WorkspaceDetection(workspaceRoot, null);
          }
          // workspace: 키는 있지만 스캔 루트가 멤버 목록에 없다 — 이 조상이 이
          // 패키지의 workspace 루트가 아니다. 잘못된 기준으로 조용히 조인되지 않게
          // limitation을 싣고 스캔 루트로 폴백한다(멤버십 검증 — 감사 후속).
          return const _WorkspaceDetection(
            null,
            'pub-workspace-member-not-listed: the nearest ancestor pubspec '
            'declares workspace but does not list the package root as a member; '
            'project fell back to the package root',
          );
        }
      } on Exception {
        // 파싱할 수 없는 조상 pubspec은 workspace 루트가 아니다 — 계속 올라간다.
      }
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return const _WorkspaceDetection(
    null,
    'pub-workspace-root-not-found: pubspec.yaml declares resolution workspace '
    'but no ancestor pubspec declares workspace; project fell back to the '
    'package root',
  );
}

/// 스캔 루트의 workspace 루트 기준 상대 경로가 `workspace:` 멤버 목록에 있는지.
///
/// 명시 경로는 URL 정규화 후 동일 비교하고, 글롭 문자(`*`·`?`)를 가진 항목은
/// 정적 해결이 불가하므로 보수적으로 멤버로 인정(sawGlob)한다. 목록이 아닌 형태도
/// 거부하지 않는다 — 조인은 fail-closed 정확 문자열 일치라 여기서 과하게 거부하면
/// 오히려 조인 어긋남이 커진다(방어적 허용).
bool _workspaceListsMember(
  String workspaceRoot,
  Object? workspaceValue,
  String scanRoot,
) {
  if (workspaceValue is! YamlList) return true;
  final scanResolved = Directory(scanRoot).resolveSymbolicLinksSync();
  final relative = p.url.joinAll(
    p.split(p.relative(scanResolved, from: workspaceRoot)),
  );
  var sawGlob = false;
  for (final entry in workspaceValue) {
    if (entry is! String) continue;
    final normalized = p.url.normalize(entry);
    if (normalized == relative) return true;
    if (normalized.contains('*') || normalized.contains('?')) sawGlob = true;
  }
  return sawGlob;
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
      // 같은 파일의 finding마다 링크 해석 syscall을 반복하지 않도록 고유
      // source당 1회만 해석한다(감사 P8).
      final canonicalBySource = <String, String?>{};
      for (final source in reported.map((finding) => finding.source).toSet()) {
        canonicalBySource[source] = await _canonicalSource(
          canonicalRoot,
          source,
        );
      }
      final scoped = <DeadFinding>[];
      for (final finding in reported) {
        if (_changedContains(
          changed,
          canonicalRoot,
          finding.source,
          canonicalBySource,
        )) {
          scoped.add(finding);
        }
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
    try {
      await BaselineStore.write(Baseline.capture(findings), File(arguments[1]));
    } on FileSystemException {
      // 인덱싱은 이미 성공했다. 쓰기 실패(부모 생성·rename·권한)를
      // "unable to index the package"로 답하면 원인을 반대로 가리킨다.
      return _reportBaselineWriteFailure(error);
    }
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

/// `project:` 소스가 Git 변경 파일 집합에 속하는지 **양방향**으로 판정한다.
///
/// 미해석 절대 경로(소스가 심볼릭 링크면 링크 경로 자체 — 링크 파일이 바뀐
/// 경우)와 심볼릭 링크를 해석한 실 경로(링크 대상이 바뀐 경우)를 모두 본다.
/// 한 방향만 보면 링크 retarget·대상 수정 중 하나가 스코프에서 조용히 빠진다
/// (감사 S4 실측). `project:`가 아닌 소스와 해석 실패(null)는 기존 규약대로
/// 보존 쪽(참)으로 편향한다. [canonicalBySource]는 호출자가 고유 source마다
/// 1회씩 미리 해석해 넣는 메모다(finding 수만큼 syscall을 반복하지 않는다).
bool _changedContains(
  Set<String> changed,
  String canonicalRoot,
  String source,
  Map<String, String?> canonicalBySource,
) {
  if (!source.startsWith('project:')) return true;
  final relative = source.substring('project:'.length);
  final absolute = p.normalize(p.join(canonicalRoot, relative));
  if (changed.contains(absolute)) return true;
  // 메모 누락은 해석 실패(null)와 구별되지 않아 보존 쪽으로 조용히 넓어진다 —
  // 미래 호출부의 사전 계산 누락을 크게 잡는다(릴리스 빌드에서는 제거).
  assert(
    canonicalBySource.containsKey(source),
    'canonical memo must cover every project: source',
  );
  final canonical = canonicalBySource[source];
  return canonical == null || changed.contains(canonical);
}

Future<int> _runGraph(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
) async {
  // `--level`·`--collapse`는 위치 인자 사이에 어디든 올 수 있다(query의
  // `--depth`/`--limit`과 같은 규칙). 값 빠짐·중복·알 수 없는 해상도·1 미만
  // 또는 비정수 collapse는 usage(64)다.
  GraphLevel? level;
  int? collapse;
  final positional = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument != '--level' && argument != '--collapse') {
      positional.add(argument);
      continue;
    }
    if ((argument == '--level' && level != null) ||
        (argument == '--collapse' && collapse != null)) {
      error.write(_help);
      return ExitStatus.usage.code;
    }
    if (index + 1 >= arguments.length) {
      error.write(_help);
      return ExitStatus.usage.code;
    }
    final value = arguments[++index];
    if (argument == '--level') {
      level = switch (value) {
        'file' => GraphLevel.file,
        'type' => GraphLevel.type,
        'symbol' => GraphLevel.symbol,
        _ => null,
      };
      if (level == null) {
        error.writeln('Unknown graph level: $value');
        return ExitStatus.usage.code;
      }
    } else {
      collapse = int.tryParse(value);
      if (collapse == null || collapse < 1) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
    }
  }
  // --collapse는 파일 수준 그래프의 폴더 요약이다. 다른 해상도와는 접는
  // 기준이 겹쳐 의미가 정의되지 않으므로 결합을 거부한다.
  if (collapse != null && level != GraphLevel.file) {
    error.writeln('graph --collapse requires --level file.');
    return ExitStatus.usage.code;
  }
  // 옵션 모양의 값은 경로로 받지 않는다. `-`로 시작하는 실제 경로는
  // `./-name`으로 전달한다.
  if (positional.length != 3 ||
      positional[0] != '--format' ||
      positional[2].startsWith('-')) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  final format = positional[1];
  if (!const {'dot', 'json', 'mermaid', 'html'}.contains(format)) {
    error.writeln('Unknown graph format: $format');
    return ExitStatus.usage.code;
  }
  try {
    final result = await indexPackage(positional[2]);
    final limitations = _limitations(result);
    // 기본 해상도(symbol)는 입력 스냅샷을 그대로 돌려주므로 기존 출력은
    // byte-for-byte 보존된다.
    var snapshot = GraphProjection.atLevel(
      result.graph.snapshot(),
      level ?? GraphLevel.symbol,
    );
    if (collapse != null) {
      snapshot = GraphProjection.collapse(snapshot, collapse);
    }
    output.write(switch (format) {
      // 순환 색칠은 dot 전용(madge 패리티)이다. 판정은 CycleDetector가
      // 담당하고 다른 포맷에 계산 비용을 들이지 않는다.
      'dot' => GraphExporter.dot(
        snapshot,
        limitations: limitations,
        cycleNodeIds: {
          for (final cycle in CycleDetector().detect(snapshot)) ...[
            ...cycle.component,
          ],
        },
      ),
      'json' => GraphExporter.json(snapshot, limitations: limitations),
      'html' => GraphExporter.html(snapshot, limitations: limitations),
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

int _reportBaselineWriteFailure(StringSink error) {
  error.writeln('Baseline write failed: unable to write the baseline file.');
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
       dartograph graph --format <dot|json|mermaid|html> [--level <file|type|symbol>] [--collapse <n>] <package-root>
       dartograph dead [--explain <symbol-id>] --format <text|json|github-actions|sarif> [--baseline <file>] [--since <ref>] <package-root>
       dartograph dead --report-test-only --format <text|json|github-actions|sarif> [--since <ref>] <package-root>
       dartograph baseline --write <file> <package-root>
       dartograph query <symbol-id-or-name> [--baseline <file>] [--depth <n>] [--limit <n>] <package-root>
       dartograph query --batch <requests.json> [--baseline <file>] [--depth <n>] [--limit <n>] <package-root>
       dartograph compare <before-package-root> <after-package-root>
       dartograph affected <git-ref> <package-root>
       dartograph skill [--install <skills-directory> [--force]]
       dartograph bridges --format json [--project <shared-root>] <package-root>
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

affected answers for a git revision (commit, branch, tag, HEAD~1, ...): the
libraries changed since that revision plus the libraries that transitively
depend on them through import/export edges, each with a shortest dependency
path as evidence. Impact is a library-level observation, not proof that
unlisted declarations are unaffected.

graph --format html emits a single self-contained document with no CDN
references. Graphs above 400 nodes keep the most connected nodes and say so
on the page; use --format dot for the full graph.

A "// dartograph:ignore" line comment heads a declaration and suppresses its
dead report by retaining it as an inlineIgnore root; blank lines or other
comments may sit between, code may not. A trailing comment at the end of a
line does not suppress the next declaration. Retention keeps what the
declaration references reachable too — use a baseline to suppress a single
finding, including file findings.

bridges --project declares the shared join root for a monorepo: the scan stays
on <package-root> while the document's project field and location.path become
relative to <shared-root> (which must contain, or be, the package root). A package
whose pubspec declares "resolution: workspace" picks up its pub workspace root
automatically (fallbacks are reported as limitations). Both sides of an isthmus
join must carry the exact same project string; rewriting it by hand afterwards
breaks provenance.

graph --level projects the graph to a resolution: file folds declarations
into their libraries, type folds members into top-level declarations, symbol
(the default) keeps the graph unchanged. Folded internal relations are dropped
as self-loops. graph --collapse <n> (requires --level file) summarizes
libraries into their first n path segments; folder nodes are aggregates and
carry no source location.

Paths and files that begin with "-" are rejected as usage errors so that a
missing option value is not silently consumed. Pass such a path as "./-name".

Exit codes:
  0   success
  1   dead findings, or cycles/rules/metrics findings with --strict
  2   analysis failure
  64  usage error
''';
