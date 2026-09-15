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
import '../analysis/impact_analyzer.dart';
import '../core/atomic_write.dart';
import '../core/config_source.dart';
import '../core/tool_info.dart';
import '../export/bridge_exporter.dart';
import '../export/analysis_reporter.dart';
import '../export/dead_reporter.dart';
import '../export/graph_exporter.dart';
import '../export/impact_reporter.dart';
import '../export/runtime_reporter.dart';
import '../index/analyzer_graph_index.dart';
import '../index/bridge_index.dart';
import '../index/incremental_cache.dart';
import '../runtime/runtime_executor.dart';
import '../runtime/runtime_facts.dart';
import '../runtime/runtime_scanner.dart';
import '../runtime/runtime_verifier.dart';
import 'agent_skill.dart';
import 'changed_files.dart';
import 'configuration_template.dart';
import 'mcp_server.dart';

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
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runAffected(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
        changedFilesSince ?? ChangedFiles.since,
      );
    case 'impact':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runImpact(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
        changedFilesSince ?? ChangedFiles.since,
      );
    case 'compare':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return _runCompare(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
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
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runGraph(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
      );
    case 'baseline':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runBaseline(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
      );
    case 'dead':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runDead(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
        changedFilesSince ?? ChangedFiles.since,
      );
    case 'query':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runQuery(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
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
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runCycles(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
      );
    case 'rules':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runRules(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
      );
    case 'metrics':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runMetrics(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
      );
    case 'init':
      return await _runInit(arguments.skip(1).toList(), stdoutSink, stderrSink);
    case 'runtime':
      return await _runRuntime(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
      );
    case 'mcp':
      return await _runMcp(arguments.skip(1).toList(), stdoutSink, stderrSink);
    default:
      stderrSink.write(_help);
      return ExitStatus.usage.code;
  }
}

/// 색인을 소비하는 명령의 `--incremental <dir>`를 인자에서 떼어낸 결과다.
final class _IndexedArguments {
  const _IndexedArguments(this.arguments, this.index);

  /// 명령이 받는 나머지 인자다(명령 이름은 뺀 상태).
  final List<String> arguments;

  /// 그 명령이 쓸 색인 함수다. 테스트 주입이 있으면 주입된 함수다.
  final IndexPackage index;
}

/// 색인 명령 인자에서 `--incremental <dir>`를 떼어내고 색인 함수를 고른다.
///
/// 디렉터리는 호출자가 정한다(없으면 만든다). 옵션 모양의 값·중복·값 누락은
/// usage(64)다 — 다른 옵션과 같은 규칙이다. 옵션이 없으면 기존 경로 그대로
/// 기본 색인을 쓴다.
_IndexedArguments? _indexArguments(
  List<String> arguments,
  StringSink error,
  IndexPackage? injected,
) {
  final remaining = arguments.skip(1).toList();
  String? directory;
  for (var index = 0; index < remaining.length; index++) {
    if (remaining[index] != '--incremental') continue;
    if (directory != null ||
        index + 1 >= remaining.length ||
        remaining[index + 1].startsWith('-')) {
      error.write(_help);
      return null;
    }
    directory = remaining[index + 1];
    remaining.removeRange(index, index + 2);
    index--;
  }
  if (injected != null) return _IndexedArguments(remaining, injected);
  final target = directory;
  return _IndexedArguments(
    remaining,
    target == null
        ? AnalyzerGraphIndex().index
        : AnalyzerGraphIndex(incremental: IncrementalCache(target)).index,
  );
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
    final matched = await _matchChangedSources(
      indexed: indexed,
      changed: changed,
      canonicalRoot: canonicalRoot,
    );
    final changedSources = matched.matchedSources;
    final result = AffectedAnalysis.analyze(snapshot, changedSources);
    final unmappedDartFiles =
        matched.unmappedDartFiles + result.unattributedSources.length;
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

Future<int> _runImpact(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
  ChangedFilesSince changedFilesSince,
) async {
  // 씨앗 입력은 --since/--changed/--symbol 중 정확히 하나다. 나머지는 영향
  // 계산 옵션이다. 값이 빠지거나 중복이면 조용히 받아들이지 않고 usage(64)다
  // (query --depth/--limit·rules --config와 같은 계약).
  String? since;
  String? changedFile;
  String? symbol;
  String? failOn;
  String? rootPath;
  ImpactFormat? format;
  int? depthOption;
  int? limitOption;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--since' && since == null) {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      since = arguments[index];
    } else if (argument == '--changed' && changedFile == null) {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      changedFile = arguments[index];
    } else if (argument == '--symbol' && symbol == null) {
      // 값은 경로가 아니라 심볼 ID다. dead --explain과 같이 대시 가드를 적용하지
      // 않는다(`<no-library>` 같은 특수 형태가 있다).
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      symbol = arguments[index];
    } else if (argument == '--format' && format == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = arguments[index];
      final parsed = switch (value) {
        'text' => ImpactFormat.text,
        'json' => ImpactFormat.json,
        'markdown' => ImpactFormat.markdown,
        'github-actions' => ImpactFormat.githubActions,
        'sarif' => ImpactFormat.sarif,
        _ => null,
      };
      if (parsed == null) {
        error.writeln(
          'Unknown report format: $value '
          '(expected text, json, markdown, github-actions, or sarif).',
        );
        return ExitStatus.usage.code;
      }
      format = parsed;
    } else if (argument == '--depth' && depthOption == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = int.tryParse(arguments[index]);
      if (value == null || value < 1) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      depthOption = value;
    } else if (argument == '--limit' && limitOption == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = int.tryParse(arguments[index]);
      if (value == null || value < 1) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      limitOption = value;
    } else if (argument == '--fail-on' && failOn == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = arguments[index];
      if (!const {'none', 'low', 'medium', 'high'}.contains(value)) {
        error.writeln(
          'Unknown fail-on level: $value '
          '(expected none, low, medium, or high).',
        );
        return ExitStatus.usage.code;
      }
      failOn = value;
    } else if (!argument.startsWith('-') && rootPath == null) {
      rootPath = argument;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  final seedModes = [since, changedFile, symbol].where((v) => v != null).length;
  if (rootPath == null || seedModes != 1) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  const thresholds = {'none': 0, 'low': 1, 'medium': 2, 'high': 3};
  final threshold = thresholds[failOn ?? 'none']!;
  try {
    final indexed = await indexPackage(rootPath);
    final snapshot = indexed.graph.snapshot();
    final limitations = _limitations(indexed);
    final changedSources = <String>{};
    final changedSymbols = <String>[];
    var unmappedDartFiles = 0;
    if (since != null) {
      final changed = await changedFilesSince(since, rootPath);
      final canonicalRoot = await Directory(rootPath).resolveSymbolicLinks();
      final matched = await _matchChangedSources(
        indexed: indexed,
        changed: changed,
        canonicalRoot: canonicalRoot,
      );
      changedSources.addAll(matched.matchedSources);
      unmappedDartFiles = matched.unmappedDartFiles;
    } else if (changedFile != null) {
      changedSources.addAll(await _readChangedEntries(changedFile));
    } else {
      changedSymbols.add(symbol!);
    }
    final report = ImpactAnalysis.analyze(
      snapshot,
      changedSources: changedSources,
      changedSymbols: changedSymbols,
      maxDepth: depthOption,
      limit: limitOption,
    );
    if (unmappedDartFiles > 0) {
      limitations.add(
        'changed-dart-files-without-library: $unmappedDartFiles changed Dart '
        'file(s) are not part of any analyzed library',
      );
    }
    if (report.unattributedSources.isNotEmpty) {
      limitations.add(
        'changed-sources-without-node: ${report.unattributedSources.length} '
        'changed source(s) are not attributed to any graph node',
      );
    }
    output.write(
      ImpactReporter.render(
        format ?? ImpactFormat.text,
        report,
        limitations: limitations.toSet().toList()..sort(),
        explainId: symbol,
        known: symbol == null ? null : report.missingSymbols.isEmpty,
      ),
    );
    // 미발견 심볼은 query/--explain 계열과 같이 64로 구분한다(보고는 그대로).
    if (report.missingSymbols.isNotEmpty) {
      return ExitStatus.usage.code;
    }
    if (threshold > 0 && _riskRank(report.risk.level) >= threshold) {
      return ExitStatus.findings.code;
    }
    return ExitStatus.success.code;
  } on ChangedFilesException {
    error.writeln(
      'Changed files could not be computed. In CI, fetch full Git history.',
    );
    return ExitStatus.failure.code;
  } on FormatException {
    error.writeln(
      'Invalid changed list: provide a JSON array of 1–1000 non-empty '
      'project-relative paths (maximum 1 MiB).',
    );
    return ExitStatus.usage.code;
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

/// risk level을 `--fail-on` 비교용 순위로 바꾼다.
int _riskRank(String level) => switch (level) {
  'high' => 3,
  'medium' => 2,
  _ => 1,
};

/// `--changed`의 JSON 문자열 배열을 `project:` 소스 URI 집합으로 읽는다.
///
/// query --batch와 같은 상한(1 MiB, 1–1000개, 비어 있지 않은 문자열)을 쓴다.
Future<Set<String>> _readChangedEntries(String path) async {
  final file = File(path);
  if (await file.length() > 1024 * 1024) throw const FormatException();
  final value = jsonDecode(await file.readAsString());
  if (value is! List ||
      value.isEmpty ||
      value.length > 1000 ||
      value.any((item) => item is! String || item.trim().isEmpty)) {
    throw const FormatException();
  }
  return {
    for (final entry in value.cast<String>()) _relativeToProjectSource(entry),
  };
}

/// 프로젝트 상대 경로를 `project:` 소스 URI로 정규화한다.
String _relativeToProjectSource(String entry) {
  var value = entry.replaceAll('\\', '/');
  while (value.startsWith('./')) {
    value = value.substring(2);
  }
  return 'project:${p.posix.normalize(value)}';
}

/// `project:` 소스 URI 중 변경 집합에 매치되는 것을 고른다.
///
/// dead --since·affected·impact가 공유하는 양방향 링크 매칭이다(링크 경로 자체와
/// 링크 대상 실 경로). canonical을 얻지 못한 소스(깨진 링크·소멸)는 affected·impact
/// 에서 비매치로 처리한다 — git은 삭제 파일을 변경 집합에 넣지 않으므로 사라진
/// 파일의 라이브러리를 '변경됨'으로 보고하면 오보다. 매치된 절대 경로와 함께
/// 라이브러리로 귀속되지 못한 변경 Dart 파일 수를 돌려준다.
Future<
  ({
    Set<String> matchedSources,
    Set<String> matchedFiles,
    int unmappedDartFiles,
  })
>
_matchChangedSources({
  required AnalyzerGraphResult indexed,
  required Set<String> changed,
  required String canonicalRoot,
}) async {
  final sources = <String>{
    for (final node in indexed.graph.snapshot().nodes)
      if (node.sourceUri?.startsWith('project:') ?? false) node.sourceUri!,
  }.toList()..sort();
  final matchedSources = <String>{};
  final matchedFiles = <String>{};
  for (final source in sources) {
    final relative = source.substring('project:'.length);
    final absolute = p.normalize(p.join(canonicalRoot, relative));
    final canonical = await _canonicalSource(canonicalRoot, source);
    if (changed.contains(absolute) ||
        (canonical != null && changed.contains(canonical))) {
      matchedSources.add(source);
      matchedFiles
        ..add(absolute)
        ..add(canonical ?? absolute);
    }
  }
  final unmapped = changed
      .where(
        (path) =>
            p.extension(path) == '.dart' &&
            p.isWithin(canonicalRoot, path) &&
            !matchedFiles.contains(path),
      )
      .length;
  return (
    matchedSources: matchedSources,
    matchedFiles: matchedFiles,
    unmappedDartFiles: unmapped,
  );
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
    ruleSet = LayerRuleSet.parse(await readConfiguration(File(config)));
  } on FileSystemException {
    // config 파일 부재·읽기 실패는 인덱싱 실패와 다르다. 원인을 반대로 가리키지 않게
    // 구분하되, 기존 계약(phase5_cli_test)이 단언하는 "Analysis failed:" 접두는 유지한다.
    return _reportRulesConfigUnreadable(error, config);
  } on FormatException catch (exception) {
    // 파서 상세는 키 이름 등 설정 내용만 담는다. loadYaml은 문자열을 받으므로
    // YamlException에도 파일 경로가 없고, .message는 줄 위치도 담지 않는다.
    // 설정 파일 경로는 기존 계약대로 이 진단에 반향하지 않는다.
    return _reportRulesConfigInvalid(error, exception.message);
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
    // init의 충돌 가드와 같이 링크 자체도 검사한다. File.exists는 링크를
    // 따라가므로 매달린 링크는 이 검사만으로는 보이지 않는다.
    if (!force && (await skill.exists() || await Link(skill.path).exists())) {
      error.writeln(
        '${skill.path} already exists. Pass --force to overwrite it.',
      );
      return ExitStatus.usage.code;
    }
    // init과 같은 원자적 교체로 쓴다. 대상 자리의 심볼릭 링크를 따라가지 않고
    // 링크 자체를 교체해 신뢰할 수 없는 디렉터리의 링크 대상 파일 오염을 막는다.
    AtomicWrite.stringSync(skill, agentSkillMarkdown);
    output.writeln('Installed dartograph skill at ${skill.path}.');
    return ExitStatus.success.code;
  } on FileSystemException {
    error.writeln(
      'Skill installation failed: check the destination permissions.',
    );
    return ExitStatus.failure.code;
  }
}

Future<int> _runInit(
  List<String> arguments,
  StringSink output,
  StringSink error,
) async {
  bool force = false;
  String? rootPath;
  for (final argument in arguments) {
    if (argument == '--force') {
      if (force) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      force = true;
    } else if (!argument.startsWith('-') && rootPath == null) {
      rootPath = argument;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  final root = rootPath ?? '.';
  if (File(root).existsSync()) {
    return _reportInitTargetNotDirectory(error, root);
  }
  final directory = Directory(root);
  if (!directory.existsSync()) {
    return _reportInitDirectoryFailure(error, root);
  }
  final configFile = File(p.join(root, 'dartograph.yaml'));
  if (!force &&
      (configFile.existsSync() || Link(configFile.path).existsSync())) {
    error.writeln(
      '${configFile.path} already exists. Pass --force to overwrite it.',
    );
    return ExitStatus.usage.code;
  }
  try {
    // --force 시 대상이 심볼릭 링크라면 링크 대상을 덮어쓰지 않고 링크 자체를
    // 원자적으로 정규 설정 파일로 교체해 외부 파일 오염을 방지한다.
    AtomicWrite.stringSync(configFile, configurationTemplate);
    output.writeln('Wrote ${configFile.path}');
    // 첫 pubspec 이전 스캐폴딩도 지원하지만, 잘못된 디렉터리에 쓰는 실수를
    // 조용히 넘기지 않게 표시한다.
    if (!File(p.join(root, 'pubspec.yaml')).existsSync()) {
      error.writeln(
        'Warning: no pubspec.yaml found here; dartograph.yaml written anyway.',
      );
    }
    return ExitStatus.success.code;
  } on IOException {
    return _reportInitWriteFailure(error, configFile.path);
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
  var messagesOption = false;
  final positional = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--messages') {
      if (messagesOption) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      messagesOption = true;
      continue;
    }
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
      messages: messagesOption,
    );
    output.write(
      exportBridgeFacts(
        project: project,
        generatedAt: now(),
        facts: indexed.facts,
        limitations: [...indexed.limitations, ...projectLimitations],
        version: messagesOption ? 2 : 1,
        transport: messagesOption ? 'basic-message-channel' : null,
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
    document = loadYaml(readConfigurationSync(pubspec));
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
        final parsed = loadYaml(readConfigurationSync(candidate));
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
  var reportRedundantPublic = false;
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
            error.writeln(
              'Unknown report format: $value '
              '(expected text, json, github-actions, or sarif).',
            );
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
    } else if (argument == '--report-redundant-public') {
      if (reportRedundantPublic) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      reportRedundantPublic = true;
    } else if (!argument.startsWith('-') && rootPath == null) {
      rootPath = argument;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  // --report-test-only·--report-redundant-public는 각각 다른 질문을 info로
  // 답한다. 단일 대상을 묻는 --explain, dead finding을 억제하는 --baseline, 두
  // 리포트의 동시 사용과는 결합하지 않는다(--since는 보고 위치만 좁히므로 허용).
  if (rootPath == null ||
      reportFormat == null ||
      (reportTestOnly && reportRedundantPublic) ||
      (explainId != null &&
          (reportFormat != ReportFormat.json ||
              baselinePath != null ||
              since != null ||
              reportTestOnly ||
              reportRedundantPublic)) ||
      ((reportTestOnly || reportRedundantPublic) && baselinePath != null)) {
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
    // 두 info 리포트는 죽은 코드가 아니므로 finding이 있어도 빌드를 실패시키지
    // 않는다.
    final report = reportTestOnly
        ? DeadReport.testOnly
        : reportRedundantPublic
        ? DeadReport.redundantPublic
        : DeadReport.dead;
    final List<DeadFinding> findings;
    if (reportTestOnly) {
      findings = analyzer.testOnlyDeclarations(
        snapshot,
        roots: indexed.retentionRoots,
        limitations: limitations,
      );
    } else if (reportRedundantPublic) {
      findings = analyzer.redundantPublicDeclarations(
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
    if (reportTestOnly || reportRedundantPublic) {
      return ExitStatus.success.code;
    }
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
        error.writeln(
          'Unknown graph level: $value (expected file, type, or symbol).',
        );
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
  if (!const {'dot', 'json', 'mermaid', 'html', 'anon'}.contains(format)) {
    error.writeln(
      'Unknown graph format: $format (expected dot, json, mermaid, html, or anon).',
    );
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
      // 담당하고(투영된·그려지는 그래프 기준), 다른 포맷에 계산 비용을
      // 들이지 않는다.
      'dot' => GraphExporter.dot(
        snapshot,
        limitations: limitations,
        cycleNodeIds: {
          for (final cycle in CycleDetector().detect(snapshot))
            ...cycle.component,
        },
      ),
      'json' => GraphExporter.json(snapshot, limitations: limitations),
      'html' => GraphExporter.html(snapshot, limitations: limitations),
      // anon은 json 문서에서 식별 문자열만 결정적으로 치환한다(공유용).
      'anon' => GraphExporter.anon(snapshot, limitations: limitations),
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

/// `runtime --format`의 값을 형식으로 바꾼다. 모르는 값이면 null이다.
RuntimeFormat? _runtimeFormat(String value) => switch (value) {
  'text' => RuntimeFormat.text,
  'json' => RuntimeFormat.json,
  'markdown' => RuntimeFormat.markdown,
  'github-actions' => RuntimeFormat.githubActions,
  'sarif' => RuntimeFormat.sarif,
  _ => null,
};

/// `runtime --env`·`--dart-define`의 `KEY=VALUE`를 파싱한다.
///
/// 키가 비어 있으면(`=VALUE`) 정의가 아니므로 null을 돌려준다. 값은 빈 문자열을
/// 허용한다 — "설정되었지만 빈 값"은 미설정과 다른 관측이기 때문이다.
({String key, String value})? _parseDefinition(String value) {
  final separator = value.indexOf('=');
  if (separator <= 0) return null;
  return (
    key: value.substring(0, separator),
    value: value.substring(separator + 1),
  );
}

/// runtime 위험 등급을 `--fail-on` 비교용 순위로 바꾼다.
///
/// impact의 [_riskRank]와 달리 `none`이 0이다 — runtime은 위험 요인이 하나도
/// 없으면 점수 0을 내므로, `--fail-on low`가 그 경우를 발견으로 세면 게이트가
/// 거짓 보고를 하게 된다.
int _runtimeRiskRank(String level) => switch (level) {
  'high' => 3,
  'medium' => 2,
  'low' => 1,
  _ => 0,
};

Future<int> _runRuntime(
  List<String> arguments,
  StringSink output,
  StringSink error,
) async {
  // 검증은 기본 수행한다(--no-verify로 끈다). --env·--dart-define은 반복
  // 지정할 수 있고 같은 키를 두 번 주면 마지막 값이 이긴다. 그 밖의 옵션은
  // impact와 같이 중복을 거부한다 — 값이 조용히 버려지면 사용자는 자기가 준
  // 입력이 판정에 쓰였다고 믿게 된다.
  var verify = true;
  var verifySeen = false;
  RuntimeFormat? format;
  final dartDefines = <String, String>{};
  final environment = <String, String>{};
  var environmentGiven = false;
  int? limitOption;
  String? failOn;
  String? entrypoint;
  String? rootPath;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if ((argument == '--verify' || argument == '--no-verify') && !verifySeen) {
      verifySeen = true;
      verify = argument == '--verify';
    } else if (argument == '--format' && format == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final parsed = _runtimeFormat(arguments[index]);
      if (parsed == null) {
        error.writeln(
          'Unknown report format: ${arguments[index]} '
          '(expected text, json, markdown, github-actions, or sarif).',
        );
        return ExitStatus.usage.code;
      }
      format = parsed;
    } else if (argument == '--dart-define' || argument == '--env') {
      final isDefine = argument == '--dart-define';
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final parsed = _parseDefinition(arguments[index]);
      if (parsed == null) {
        error.writeln(
          'Invalid $argument: expected $argument KEY=VALUE with a non-empty '
          'KEY.',
        );
        return ExitStatus.usage.code;
      }
      if (isDefine) {
        dartDefines[parsed.key] = parsed.value;
      } else {
        environmentGiven = true;
        environment[parsed.key] = parsed.value;
      }
    } else if (argument == '--limit' && limitOption == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = int.tryParse(arguments[index]);
      if (value == null || value < 1) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      limitOption = value;
    } else if (argument == '--fail-on' && failOn == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = arguments[index];
      if (!const {'none', 'low', 'medium', 'high'}.contains(value)) {
        error.writeln(
          'Unknown fail-on level: $value '
          '(expected none, low, medium, or high).',
        );
        return ExitStatus.usage.code;
      }
      failOn = value;
    } else if (argument == '--execute' && entrypoint == null) {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      entrypoint = arguments[index];
    } else if (!argument.startsWith('-') && rootPath == null) {
      rootPath = argument;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  if (rootPath == null) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  const thresholds = {'none': 0, 'low': 1, 'medium': 2, 'high': 3};
  final threshold = thresholds[failOn ?? 'none']!;
  // --env가 하나라도 오면 그 집합만 쓴다(hermetic). 주지 않으면 실제 프로세스
  // 환경을 쓰고, 그 사실을 보고서 limitation에 남긴다.
  final inputs = RuntimeInputs(
    environment: environmentGiven ? environment : Platform.environment,
    dartDefines: dartDefines,
    environmentFromProcess: !environmentGiven,
    windows: Platform.isWindows,
  );
  try {
    // 패키지 루트 부재를 --execute 실패로 오귀인하지 않도록 먼저 해석한다.
    final canonicalRoot = await Directory(rootPath).resolveSymbolicLinks();
    if (entrypoint != null && _looksLikeEntryPointPath(entrypoint)) {
      final file = File(
        p.isAbsolute(entrypoint) ? entrypoint : p.join(rootPath, entrypoint),
      );
      if (!file.existsSync()) {
        error.writeln(
          'Entrypoint not found: $entrypoint. Pass a .dart file or a package '
          'executable name.',
        );
        return ExitStatus.usage.code;
      }
    }
    final facts = await RuntimeScanner().scan(rootPath);
    RuntimeExecution? execution;
    if (entrypoint != null) {
      // --env를 주었으면 그 값으로 실제 실행해 본다(상속 환경 위에 덮어쓴다).
      execution = await executeEntrypoint(
        entrypoint: entrypoint,
        rootPath: rootPath,
        environment: environmentGiven ? environment : null,
      );
    }
    final report = RuntimeVerifier.analyze(
      facts: facts,
      inputs: inputs,
      fileSystem: LocalRuntimeFileSystem(canonicalRoot),
      execution: execution,
      limit: limitOption,
      verify: verify,
    );
    output.write(RuntimeReporter.render(format ?? RuntimeFormat.text, report));
    if (threshold > 0 && _runtimeRiskRank(report.risk.level) >= threshold) {
      return ExitStatus.findings.code;
    }
    return ExitStatus.success.code;
  } on ProcessException {
    // --execute의 dart 실행 파일을 띄우지 못했다.
    error.writeln('Analysis failed: unable to run the --execute entrypoint.');
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

/// `--execute` 값이 파일 경로를 뜻하는지 판정한다.
///
/// `.dart`로 끝나거나 경로 구분자가 있으면 경로다. 그 밖의 단일 이름은
/// `dart run`이 해석하는 패키지 실행 파일 이름일 수 있으므로 존재를 요구하지
/// 않는다(`dart run`의 실패는 실행 증거로 남는다).
bool _looksLikeEntryPointPath(String entrypoint) =>
    entrypoint.endsWith('.dart') ||
    entrypoint.contains('/') ||
    entrypoint.contains(r'\');

Future<int> _runMcp(
  List<String> arguments,
  StringSink output,
  StringSink error,
) async {
  // 옵션이 없다. 도구 인자(packageRoot 등)는 클라이언트가 요청마다 보낸다.
  if (arguments.isNotEmpty) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  return runMcpServer(
    input: stdin.transform(utf8.decoder).transform(const LineSplitter()),
    output: output,
    error: error,
  );
}

int _reportAnalysisFailure(StringSink error) {
  error.writeln('Analysis failed: unable to index the package.');
  return ExitStatus.failure.code;
}

int _reportBaselineWriteFailure(StringSink error) {
  error.writeln('Baseline write failed: unable to write the baseline file.');
  return ExitStatus.failure.code;
}

int _reportRulesConfigUnreadable(StringSink error, String config) {
  error.writeln(
    'Analysis failed: unable to read the rules configuration: $config.',
  );
  return ExitStatus.failure.code;
}

int _reportRulesConfigInvalid(StringSink error, String detail) {
  error.writeln('Analysis failed: invalid rules configuration: $detail');
  return ExitStatus.failure.code;
}

int _reportInitDirectoryFailure(StringSink error, String path) {
  error.writeln('Init failed: target directory does not exist: $path');
  return ExitStatus.failure.code;
}

int _reportInitTargetNotDirectory(StringSink error, String path) {
  error.writeln('Init failed: target path is not a directory: $path');
  return ExitStatus.failure.code;
}

int _reportInitWriteFailure(StringSink error, String path) {
  error.writeln('Init failed: unable to write $path.');
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
       dartograph init [--force] [<package-root>]
       dartograph graph --format <dot|json|mermaid|html|anon> [--level <file|type|symbol>] [--collapse <n>] [--incremental <dir>] <package-root>
       dartograph dead [--explain <symbol-id>] --format <text|json|github-actions|sarif> [--baseline <file>] [--since <ref>] [--incremental <dir>] <package-root>
       dartograph dead --report-test-only --format <text|json|github-actions|sarif> [--since <ref>] [--incremental <dir>] <package-root>
       dartograph dead --report-redundant-public --format <text|json|github-actions|sarif> [--since <ref>] [--incremental <dir>] <package-root>
       dartograph baseline --write <file> [--incremental <dir>] <package-root>
       dartograph query <symbol-id-or-name> [--baseline <file>] [--depth <n>] [--limit <n>] [--incremental <dir>] <package-root>
       dartograph query --batch <requests.json> [--baseline <file>] [--depth <n>] [--limit <n>] [--incremental <dir>] <package-root>
       dartograph compare [--incremental <dir>] <before-package-root> <after-package-root>
       dartograph affected [--incremental <dir>] <git-ref> <package-root>
       dartograph impact --since <git-ref> [--format <fmt>] [--depth <n>] [--limit <n>] [--fail-on <level>] [--incremental <dir>] <package-root>
       dartograph impact --changed <changes.json> [--format <fmt>] [--depth <n>] [--limit <n>] [--fail-on <level>] [--incremental <dir>] <package-root>
       dartograph impact --symbol <symbol-id> [--format <fmt>] [--depth <n>] [--limit <n>] [--incremental <dir>] <package-root>
       dartograph skill [--install <skills-directory> [--force]]
       dartograph runtime [--verify|--no-verify] [--format <fmt>] [--dart-define KEY=VALUE]... [--env KEY=VALUE]... [--limit <n>] [--fail-on <none|low|medium|high>] [--execute <dart-entrypoint>] <package-root>
       dartograph mcp
       dartograph bridges --format json [--project <shared-root>] <package-root>
       dartograph bridges --messages --format json [--project <shared-root>] <package-root>
       dartograph cycles [--strict] [--incremental <dir>] <package-root>
       dartograph cycles --explain <symbol-id> [--incremental <dir>] <package-root>
       dartograph rules --config <yaml-file> [--strict] [--incremental <dir>] <package-root>
       dartograph rules --config <yaml-file> --explain <symbol-id> [--incremental <dir>] <package-root>
       dartograph metrics [--strict] [--incremental <dir>] <package-root>

init writes a commented dartograph.yaml configuration template to the project
root. Pass --force to overwrite an existing configuration file.

skill prints an installable agent skill. --install writes
<skills-directory>/dartograph/SKILL.md; pass --force to overwrite an existing
file (a symlink at that path is replaced as a link, never followed).

dead --explain requires --format json and does not combine with --baseline or
--since. dead --report-test-only answers a different question (production
declarations reached only from test code) at info severity, so it never fails
the build and does not combine with --explain or --baseline. dead
--report-redundant-public likewise answers at info severity (public
declarations whose observed references all come from their own library) with
the same combination rules. cycles/rules
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

bridges --messages emits opt-in BasicMessageChannel send facts as bridge-facts
version 2 with transport basic-message-channel. The default bridges command
keeps the version 1 MethodChannel output.

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

analyzer를 쓰는 명령(graph, dead, query, compare, affected, impact, baseline,
cycles, rules, metrics)은 --incremental <dir>를 받는다. 디렉터리에 파일별 사실
캐시를 두고 다음 실행에서 바뀐 파일과 그 파일을 import·export하는 폐쇄만 다시
해석한다. 산출물은 전체 해석과 byte 동일하다. 캐시가 없거나 손상됐거나 스키마가
다르거나 쓸 수 없으면 전체 해석으로 폴백하고 오류로 끝내지 않는다(쓸 수 없을
때만 그 사실을 limitation으로 남긴다). 캐시 디렉터리는 프로젝트마다 따로 쓴다.

Paths and files that begin with "-" are rejected as usage errors so that a
missing option value is not silently consumed. Pass such a path as "./-name".

impact answers "what does changing this affect?" before the edit. Give it a
git revision (--since), a JSON array of changed project-relative paths
(--changed), or one symbol id (--symbol); it reports the changed set, every
symbol that transitively uses it with a shortest usage path, the call sites
into changed declarations, the test libraries that depend on the changed set,
and a risk score with its factors. The coverage block counts the impacted
symbols that inspecting only the changed files would have missed.
--fail-on <level> turns a risk level of at least <level> into exit 1
(default none). Impact is an observed dependency reachability, not a deletion
verdict; an unlisted declaration is not proven unaffected.

mcp runs a Model Context Protocol server on stdio (JSON-RPC 2.0) for AI
clients. It exposes three read-only tools over the existing CLI paths:
impact_query (the impact pre-check), dependency_query (query/--batch), and
verify_run (dead, cycles, rules, metrics with exit code and raw output).
stdout carries only JSON-RPC; diagnostics stay on stderr. The caller passes
packageRoot per call. Nothing is modified by these tools.

runtime reports the dependencies that only appear at run time — environment
variables and dart-defines, dynamic loading (Isolate.spawnUri, Process.run,
DynamicLibrary.open, dart:mirrors), configuration paths, bundled assets, and
external URLs — and, by default, judges each one against this environment:
present, defaulted, or missing, with everything that could not be judged left
in `unverified` with its reason. Missing and unjudged facts feed a risk score.
--env and --dart-define are repeatable and replace their channels hermetically
(when --env is given, only those values are used and the process environment is
ignored); the values themselves are never printed. --verify is on by default
and --no-verify only detects. --fail-on <level> turns a risk level of at least
<level> into exit 1. --execute <dart-entrypoint> RUNS ARBITRARY CODE: it starts
`dart run <entrypoint>` in the package root (60s timeout), applies the --env
values on top of the inherited environment, and reports the exit code and a
stderr summary as execution evidence. A missing path is not proof that the
program cannot run, and a present one is not proof that it does.

Exit codes:
  0   success
  1   dead findings (including a dead --explain of an unreachable target),
      or cycles/rules/metrics findings with --strict, or a runtime/impact
      risk level at or above --fail-on
  2   analysis failure
  64  usage error, or a query/--explain target not found in the graph
''';
