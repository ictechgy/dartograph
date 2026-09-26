import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../analysis/affected_analyzer.dart';
import '../analysis/baseline.dart';
import '../analysis/architecture_metrics.dart';
import '../analysis/code_owners.dart';
import '../analysis/dependency_audit.dart';
import '../analysis/duplication_analyzer.dart';
import '../analysis/graph_projection.dart';
import '../analysis/cycle_detector.dart';
import '../analysis/layer_rules.dart';
import '../analysis/reachability_analyzer.dart';
import '../analysis/symbol_query.dart';
import '../analysis/graph_comparison.dart';
import '../analysis/impact_analyzer.dart';
import '../core/atomic_write.dart';
import '../core/config_source.dart';
import '../core/path_glob.dart';
import '../core/result_ledger.dart';
import '../core/tool_info.dart';
import '../export/bridge_exporter.dart';
import '../export/analysis_reporter.dart';
import '../export/codeowners_reporter.dart';
import '../export/dead_reporter.dart';
import '../export/dependency_reporter.dart';
import '../export/duplication_reporter.dart';
import '../export/graph_exporter.dart';
import '../export/impact_reporter.dart';
import '../export/ledger_reporter.dart';
import '../export/runtime_reporter.dart';
import '../index/analyzer_graph_index.dart';
import '../index/bridge_index.dart';
import '../index/schema_index.dart';
import '../index/dependency_tools.dart';
import '../index/incremental_cache.dart';
import '../runtime/runtime_executor.dart';
import '../runtime/runtime_facts.dart';
import '../runtime/runtime_scanner.dart';
import '../runtime/runtime_verifier.dart';
import 'agent_setup.dart';
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
  // `--record <dir>`가 있으면 그 명령의 실행을 append-only 원장에 한 줄 남긴다.
  // 원장 기록은 분석 결과를 뒤집지 않는다 — 쓰기 실패는 stderr 진단으로만
  // 남기고 명령이 낸 종료 코드를 그대로 돌려준다(증분 캐시 쓰기 실패와 같은 경계).
  final ledger = _extractLedgerDirectory(arguments, stderrSink);
  if (ledger == null) return ExitStatus.usage.code;
  final failedItems = <String>[];
  final code = await _dispatchCommand(
    ledger.arguments,
    stdoutSink,
    stderrSink,
    indexPackage,
    changedFilesSince,
    now,
    failedItems,
  );
  final directory = ledger.directory;
  if (directory != null) {
    await _recordRun(
      directory,
      ledger.arguments,
      code,
      failedItems,
      now ?? DateTime.now,
      stderrSink,
    );
  }
  return code;
}

Future<int> _dispatchCommand(
  List<String> arguments,
  StringSink stdoutSink,
  StringSink stderrSink,
  IndexPackage? indexPackage,
  ChangedFilesSince? changedFilesSince,
  DateTime Function()? now,
  List<String> failedItems,
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
        failedItems,
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
        failedItems,
      );
    case 'deps':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runDeps(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
        failedItems,
      );
    case 'dup':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runDup(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
        failedItems,
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
    case 'setup':
      return await _runSetup(
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
    case 'schema':
      return await _runBridges(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
        now ?? DateTime.now,
        schema: true,
      );
    case 'cycles':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runCycles(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
        failedItems,
      );
    case 'rules':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runRules(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
        failedItems,
      );
    case 'metrics':
      final indexed = _indexArguments(arguments, stderrSink, indexPackage);
      if (indexed == null) return ExitStatus.usage.code;
      return await _runMetrics(
        indexed.arguments,
        stdoutSink,
        stderrSink,
        indexed.index,
        failedItems,
      );
    case 'init':
      return await _runInit(arguments.skip(1).toList(), stdoutSink, stderrSink);
    case 'runtime':
      return await _runRuntime(
        arguments.skip(1).toList(),
        stdoutSink,
        stderrSink,
        failedItems,
      );
    case 'history':
      return await _runHistory(
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

/// 색인 명령 인자에서 `--incremental <dir>`와 `--workspace`를 떼어내고 색인
/// 함수를 고른다.
///
/// 디렉터리는 호출자가 정한다(없으면 만든다). 옵션 모양의 값·중복·값 누락은
/// usage(64)다 — 다른 옵션과 같은 규칙이다. `--workspace`는 값을 받지 않는
/// 스위치다 — pub workspace 멤버를 같은 그래프로 집계한다(중복 지정은
/// usage다). 옵션이 없으면 기존 경로 그대로 기본 색인을 쓴다.
_IndexedArguments? _indexArguments(
  List<String> arguments,
  StringSink error,
  IndexPackage? injected,
) {
  final remaining = arguments.skip(1).toList();
  String? directory;
  var workspace = false;
  for (var index = 0; index < remaining.length; index++) {
    if (remaining[index] == '--workspace') {
      if (workspace) {
        error.write(_help);
        return null;
      }
      workspace = true;
      remaining.removeAt(index);
      index--;
      continue;
    }
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
    AnalyzerGraphIndex(
      incremental: target == null ? null : IncrementalCache(target),
      aggregateWorkspace: workspace,
    ).index,
  );
}

/// `--record <dir>`를 받는 명령이다. 문제를 보고하는 검증·분석 명령만 기록한다.
const _recordableCommands = {
  'affected',
  'baseline',
  'compare',
  'cycles',
  'dead',
  'deps',
  'dup',
  'graph',
  'impact',
  'metrics',
  'query',
  'rules',
  'runtime',
};

/// 원장 기록 요청이다. [directory]가 null이면 `--record`가 없었다는 뜻이다.
typedef _LedgerRequest = ({List<String> arguments, String? directory});

/// 명령 인자에서 `--record <dir>`를 떼어낸다.
///
/// 기록 대상이 아닌 명령의 `--record`는 그대로 두어 그 명령의 사용 오류(64)로
/// 떨어지게 한다 — 조용히 무시하지 않는다. 대상 명령에서 값 누락·중복·옵션 모양
/// 값은 usage(64)다(`--incremental`과 같은 규칙). 유효하지 않으면 null이다.
_LedgerRequest? _extractLedgerDirectory(
  List<String> arguments,
  StringSink error,
) {
  final command = arguments.firstOrNull;
  if (command == null || !_recordableCommands.contains(command)) {
    return (arguments: arguments, directory: null);
  }
  final remaining = arguments.skip(1).toList();
  String? directory;
  for (var index = 0; index < remaining.length; index++) {
    if (remaining[index] != '--record') continue;
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
  return (arguments: [command, ...remaining], directory: directory);
}

/// 실행 입력 요약을 만든다. 플래그와 그 값(경로 포함)만 담는다.
///
/// `--env`·`--dart-define`은 값이 비밀일 수 있으므로 **키만** 남긴다. 반복
/// 지정은 순서대로 이어 마지막 값만 남기지 않는다(더 보수적이다).
Map<String, String> _ledgerInputs(List<String> arguments) {
  final inputs = <String, String>{};
  for (var index = 0; index < arguments.length; index++) {
    final token = arguments[index];
    if (!token.startsWith('--')) continue;
    final key = token.substring(2);
    final hasValue =
        index + 1 < arguments.length && !arguments[index + 1].startsWith('-');
    final raw = hasValue ? arguments[++index] : 'true';
    final value = switch (key) {
      'env' || 'dart-define' => raw.split('=').first,
      _ => raw,
    };
    inputs[key] = inputs.containsKey(key) ? '${inputs[key]},$value' : value;
  }
  return inputs;
}

/// 관측한 Git HEAD SHA다. 계산하지 못하면 null이다(추정값을 넣지 않는다).
Future<String?> _observeCommit() async {
  try {
    final result = await Process.run(
      'git',
      const ['rev-parse', 'HEAD'],
      workingDirectory: Directory.current.path,
    ).timeout(const Duration(seconds: 5));
    if (result.exitCode != 0) return null;
    final value = (result.stdout as String).trim();
    return RegExp(r'^[0-9a-f]{7,64}$').hasMatch(value) ? value : null;
  } on Object {
    return null;
  }
}

/// 실행 하나를 원장에 붙인다. 실패해도 분석 결과를 뒤집지 않는다.
Future<void> _recordRun(
  String directory,
  List<String> arguments,
  int exitCode,
  List<String> failedItems,
  DateTime Function() now,
  StringSink error,
) async {
  final command = arguments.firstOrNull ?? '';
  final entry = LedgerEntry(
    recordedAt: now().toUtc(),
    toolVersion: toolVersion,
    command: command,
    exitCode: exitCode,
    commit: await _observeCommit(),
    inputs: _ledgerInputs(arguments.skip(1).toList()),
    failedItems: List<String>.unmodifiable(failedItems),
  );
  try {
    await ResultLedger(directory).append(entry);
  } on Object {
    // 경로를 반향하지 않는다.
    error.writeln(
      'Ledger write failed: analysis is complete but --record was not updated.',
    );
  }
}

/// 검증 원장을 읽어 보고한다.
Future<int> _runHistory(
  List<String> arguments,
  StringSink output,
  StringSink error,
) async {
  String? ledger;
  String? commit;
  HistoryFormat? format;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--ledger' && ledger == null) {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      ledger = arguments[index];
    } else if (argument == '--commit' && commit == null) {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      commit = arguments[index];
    } else if (argument == '--format' && format == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = arguments[index];
      final parsed = switch (value) {
        'text' => HistoryFormat.text,
        'json' => HistoryFormat.json,
        _ => null,
      };
      if (parsed == null) {
        error.writeln('Unknown report format: $value (expected text or json).');
        return ExitStatus.usage.code;
      }
      format = parsed;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  if (ledger == null) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final result = await ResultLedger(ledger).read(commit: commit);
    output.write(LedgerReporter.render(format ?? HistoryFormat.text, result));
    return ExitStatus.success.code;
  } on FileSystemException {
    return _reportAnalysisFailure(error);
  } on Object {
    return _reportAnalysisFailure(error);
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
  String? formatName;
  final positional = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--format' && formatName == null) {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      formatName = arguments[index];
      continue;
    }
    positional.add(argument);
  }
  final format = _parseAnalysisFormat(formatName);
  if (positional.length != 2 ||
      positional.any((item) => item.startsWith('-')) ||
      format == null) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  final reference = positional[0];
  final rootPath = positional[1];
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
    output.write(
      AnalysisReporter.affected(
        result,
        limitations: limitations,
        format: format,
        nodeSources: {for (final node in snapshot.nodes) node.id: node},
      ),
    );
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
  List<String> failedItems,
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
        'test-list' => ImpactFormat.testList,
        _ => null,
      };
      if (parsed == null) {
        error.writeln(
          'Unknown report format: $value '
          '(expected text, json, markdown, github-actions, sarif, '
          'or test-list).',
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
      try {
        changedSources.addAll(await _readChangedEntries(changedFile));
      } on FileSystemException {
        // 파일 부재·권한 같은 입력 경로 문제는 분석 실패(2)가 아니라 잘못된
        // 사용(64)이다 — query --batch의 경로 검증과 같은 분류.
        error.writeln('Changed list could not be read: $changedFile');
        return ExitStatus.usage.code;
      }
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
    failedItems.addAll([for (final item in report.impacted) item.id]);
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
  // 소스마다 resolveSymbolicLinks syscall이 필요하다 — 파일 수에 비례하므로
  // 직렬로 두지 않고 한꺼번에 돌린다.
  final canonicals = await Future.wait(
    sources.map((source) => _canonicalSource(canonicalRoot, source)),
  );
  final matchedSources = <String>{};
  final matchedFiles = <String>{};
  for (var i = 0; i < sources.length; i++) {
    final source = sources[i];
    final relative = source.substring('project:'.length);
    final absolute = p.normalize(p.join(canonicalRoot, relative));
    final canonical = canonicals[i];
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
  String? formatName;
  final positional = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--format' && formatName == null) {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      formatName = arguments[index];
      continue;
    }
    positional.add(argument);
  }
  final format = _parseAnalysisFormat(formatName);
  if (positional.length != 2 ||
      positional.any((item) => item.startsWith('-')) ||
      format == null) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final before = await indexPackage(positional[0]);
    final after = await indexPackage(positional[1]);
    final beforeSnapshot = before.graph.snapshot();
    output.write(
      AnalysisReporter.compare(
        compareGraphs(
          before: beforeSnapshot,
          after: after.graph.snapshot(),
          beforeRoots: before.retentionRoots,
          afterRoots: after.retentionRoots,
          beforeLimitations: _limitations(before),
          afterLimitations: _limitations(after),
        ),
        format: format,
        nodeSources: {for (final node in beforeSnapshot.nodes) node.id: node},
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
  List<String> failedItems,
) async {
  var strict = false;
  String? explainId;
  String? formatName;
  String? root;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--strict') {
      if (strict) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      strict = true;
    } else if (argument == '--format' && formatName == null) {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      formatName = arguments[index];
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
  final format = _parseAnalysisFormat(formatName);
  // --explain은 한 정점의 근거를 는 고정 JSON 질의라 finding 게이트(--strict)·
  // 다른 출력 형식과 결합하지 않는다. dead --explain이 --baseline/--since를
  // 배제하는 것과 같은 철학이다.
  if (root == null ||
      format == null ||
      (strict && explainId != null) ||
      (explainId != null && format != AnalysisFormat.json)) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(root);
    final limitations = _limitations(indexed);
    final snapshot = indexed.graph.snapshot();
    if (explainId != null) {
      final explanation = CycleDetector().explain(snapshot, explainId);
      output.write(
        AnalysisReporter.cyclesExplain(explanation, limitations: limitations),
      );
      return explanation.known
          ? ExitStatus.success.code
          : ExitStatus.usage.code;
    }
    final cycles = CycleDetector().detect(snapshot);
    output.write(
      AnalysisReporter.cycles(
        cycles,
        limitations: limitations,
        format: format,
        nodeSources: {for (final node in snapshot.nodes) node.id: node},
      ),
    );
    failedItems.addAll([
      for (final cycle in cycles)
        '${cycle.breakCandidate.from}->${cycle.breakCandidate.to}',
    ]);
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
  List<String> failedItems,
) async {
  var strict = false;
  String? config;
  String? explainId;
  String? formatName;
  String? root;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--strict') {
      if (strict) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      strict = true;
    } else if (argument == '--format' && formatName == null) {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      formatName = arguments[index];
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
  final format = _parseAnalysisFormat(formatName);
  // --explain은 한 정점의 레이어 배치를 묻는 고정 JSON 질의라 finding 게이트
  // (--strict)·다른 출력 형식과 결합하지 않는다. 레이어 배치는 ruleset에
  // 의존하므로 --config는 계속 필요하다.
  if (config == null ||
      root == null ||
      format == null ||
      (strict && explainId != null) ||
      (explainId != null && format != AnalysisFormat.json)) {
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
    output.write(
      AnalysisReporter.rules(
        violations,
        limitations: limitations,
        format: format,
      ),
    );
    failedItems.addAll([
      for (final violation in violations)
        '${violation.ruleName}:${violation.edge.sourceId}'
            '->${violation.edge.targetId}',
    ]);
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
  List<String> failedItems,
) async {
  var strict = false;
  String? formatName;
  String? root;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--strict') {
      if (strict) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      strict = true;
    } else if (argument == '--format' && formatName == null) {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      formatName = arguments[index];
    } else if (!argument.startsWith('-') && root == null) {
      root = argument;
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  final format = _parseAnalysisFormat(formatName);
  if (root == null || format == null) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(root);
    final snapshot = indexed.graph.snapshot();
    final metrics = ArchitectureMetricsCalculator().calculate(snapshot);
    // thresholds.distance가 |D'| 허용치를, thresholds.complexity가 strict의
    // 복잡도 상한을 정한다 — 설정 파일이 게이트를 바꾼다는 사실은 한계에 남긴다.
    final tolerance = indexed.metricsDistanceThreshold ?? 0.3;
    final complexityLimit = indexed.metricsComplexityThreshold;
    final limitations = _limitations(indexed);
    if (indexed.metricsDistanceThreshold != null || complexityLimit != null) {
      limitations.add(
        'thresholds: dartograph.yaml overrides metrics gates '
        '(distance ≤ $tolerance'
        '${complexityLimit == null ? '' : ', complexity ≤ $complexityLimit'})',
      );
    }
    output.write(
      AnalysisReporter.metrics(
        metrics,
        limitations: limitations,
        tolerance: tolerance,
        complexity: indexed.complexity,
        nodeSources: {for (final node in snapshot.nodes) node.id: node},
        complexityLimit: complexityLimit,
        format: format,
      ),
    );
    final exceedsTolerance = metrics.any(
      (item) => !item.isolated && item.distance > tolerance,
    );
    failedItems.addAll([
      for (final item in metrics)
        if (!item.isolated && item.distance > tolerance) item.id,
    ]);
    var exceedsComplexity = false;
    if (complexityLimit != null) {
      for (final entry in indexed.complexity.entries) {
        if (entry.value > complexityLimit) {
          exceedsComplexity = true;
          failedItems.add(entry.key);
        }
      }
    }
    return strict && (exceedsTolerance || exceedsComplexity)
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

/// `--format` 값을 분석 형식으로 해석한다. 값이 없으면 기존 JSON 기본값이고,
/// 알 수 없는 값이면 null을 돌려 호출자가 usage(64)로 처리하게 한다.
AnalysisFormat? _parseAnalysisFormat(String? name) {
  if (name == null) return AnalysisFormat.json;
  return switch (name) {
    'text' => AnalysisFormat.text,
    'json' => AnalysisFormat.json,
    'sarif' => AnalysisFormat.sarif,
    _ => null,
  };
}

/// 질의 문서의 모든 `location`에 선언 위치 소스 줄을 덧붙인다.
///
/// `--with-source`가 있을 때만 호출한다. `project:` 경로만 읽고(루트 밖·비프로젝트
/// 스킴은 건너뛴다), 파일은 경로별로 한 번만 읽는다. 파일을 읽지 못하면 그 위치만
/// 조용히 생략한다 — 소스 덧붙이기는 부가 정보다. 위치 경로는 이미 프로젝트 상대라
/// 절대 경로·`..` 탈출을 방어로 한 번 더 막는다.
void _attachQuerySource(
  Object? value,
  String root,
  int context,
  Map<String, List<String>?> files,
) {
  if (value is Map<String, Object?>) {
    final location = value['location'];
    if (location is Map<String, Object?>) {
      final path = location['path'];
      final line = location['line'];
      if (path is String && line is int) {
        final source = _querySourceLines(root, path, line, context, files);
        if (source != null) value['source'] = source;
      }
    }
    for (final entry in value.entries) {
      _attachQuerySource(entry.value, root, context, files);
    }
  } else if (value is List) {
    for (final item in value) {
      _attachQuerySource(item, root, context, files);
    }
  }
}

/// 한 선언 위치의 소스 줄(`line` 앞뒤 [context]줄)을 읽는다. 읽을 수 없으면 null.
List<Map<String, Object?>>? _querySourceLines(
  String root,
  String path,
  int line,
  int context,
  Map<String, List<String>?> files,
) {
  const prefix = 'project:';
  if (!path.startsWith(prefix)) return null;
  final relative = path.substring(prefix.length);
  if (p.isAbsolute(relative) || p.normalize(relative).startsWith('..')) {
    return null;
  }
  final filePath = p.join(root, relative);
  final lines = files.putIfAbsent(filePath, () {
    final file = File(filePath);
    try {
      return file.existsSync() ? file.readAsLinesSync() : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      // 잘못된 UTF-8 소스도 분석 대상이 될 수 있다 — 소스 표시만 생략한다.
      return null;
    }
  });
  if (lines == null || lines.isEmpty) return null;
  final start = (line - context).clamp(1, lines.length);
  final end = (line + context).clamp(1, lines.length);
  if (start > end) return null;
  return [
    for (var current = start; current <= end; current++)
      {'line': current, 'text': lines[current - 1]},
  ];
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
  int? sourceContext;
  var withSource = false;
  final positional = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--with-source') {
      if (withSource) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      withSource = true;
      continue;
    }
    if (argument != '--depth' &&
        argument != '--limit' &&
        argument != '--source-context') {
      positional.add(argument);
      continue;
    }
    final duplicate = switch (argument) {
      '--depth' => depthOption != null,
      '--limit' => limitOption != null,
      _ => sourceContext != null,
    };
    if (duplicate || index + 1 >= arguments.length) {
      error.write(_help);
      return ExitStatus.usage.code;
    }
    final value = int.tryParse(arguments[++index]);
    // `--source-context 0`은 선언 줄만 보여주는 유효한 값이다.
    final minimum = argument == '--source-context' ? 0 : 1;
    if (value == null || value < minimum) {
      error.write(_help);
      return ExitStatus.usage.code;
    }
    switch (argument) {
      case '--depth':
        depthOption = value;
      case '--limit':
        limitOption = value;
      default:
        sourceContext = value;
    }
  }
  // 의도 없는 소스 문맥 지정을 조용히 무시하지 않는다.
  if (sourceContext != null && !withSource) {
    error.write(_help);
    return ExitStatus.usage.code;
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
    if (withSource) {
      _attachQuerySource(document, rootPath, sourceContext ?? 0, {});
    }
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

/// Codex 전역 MCP 설정 파일이다. `$CODEX_HOME/config.toml`, 없으면
/// `~/.codex/config.toml`이다(Codex는 프로젝트 설정을 읽지 않는다).
File _codexConfigFile() {
  final codexHome = Platform.environment['CODEX_HOME']?.trim();
  final home = (codexHome != null && codexHome.isNotEmpty)
      ? codexHome
      : p.join(
          Platform.environment['HOME'] ??
              Platform.environment['USERPROFILE'] ??
              '.',
          '.codex',
        );
  return File(p.join(home, 'config.toml'));
}

/// `dartograph setup` — 에이전트 MCP·훅 연동 설정을 생성·설치·해제한다.
///
/// 인쇄 경로는 검토용 결과물을 보여주고, `--install`은 타깃별 설정 파일에
/// dartograph 항목만 병합한다. 기존 파일은 절대 통째로 덮어쓰지 않는다 —
/// 병합할 수 없는 기존 설정은 그대로 두고 실패한다. `--uninstall`은 생성한
/// 항목만 되돌린다. Codex만 설정이 전역이라 프로젝트 루트가 필요 없다.
/// 유료 서비스·로그인·텔레메트리 의존은 없다.
Future<int> _runSetup(
  List<String> arguments,
  StringSink output,
  StringSink error,
) async {
  var target = setupTargetClaude;
  var targetSet = false;
  var force = false;
  var install = false;
  var uninstall = false;
  String? root;
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument == '--force' && !force) {
      force = true;
    } else if (argument == '--target' &&
        !targetSet &&
        i + 1 < arguments.length &&
        !arguments[i + 1].startsWith('-')) {
      targetSet = true;
      target = arguments[++i];
    } else if (argument == '--install' && !install && !uninstall) {
      install = true;
      // Codex는 프로젝트 루트가 필요 없다 — 값이 없어도 받는다.
      if (i + 1 < arguments.length && !arguments[i + 1].startsWith('-')) {
        root = arguments[++i];
      }
    } else if (argument == '--uninstall' && !uninstall && !install) {
      uninstall = true;
      if (i + 1 < arguments.length && !arguments[i + 1].startsWith('-')) {
        root = arguments[++i];
      }
    } else {
      error.write(_help);
      return ExitStatus.usage.code;
    }
  }
  final needsRoot = target != setupTargetCodex;
  if (!setupTargets.contains(target) ||
      (install && uninstall) ||
      (force && uninstall) ||
      ((install || uninstall) && needsRoot && root == null) ||
      // Codex는 전역 설정만 다룬다 — 루트 인자를 조용히 무시하지 않는다.
      (!needsRoot && root != null)) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  if (root != null && !Directory(root).existsSync()) {
    error.writeln('Setup failed: $root is not a directory.');
    return ExitStatus.usage.code;
  }
  if (!install && !uninstall) {
    _printSetupArtifacts(target, output);
    return ExitStatus.success.code;
  }
  return uninstall
      ? _uninstallSetup(target, root, output, error)
      : _installSetup(target, root, force, output, error);
}

/// 타깃별 검토용 결과물을 결정적 순서로 인쇄한다.
void _printSetupArtifacts(String target, StringSink output) {
  switch (target) {
    case setupTargetClaude:
      output
        ..writeln('# .claude/hooks/$agentHookScriptName')
        ..write(agentHookScript)
        ..writeln('# .claude/settings.json — merge this block')
        ..writeln(agentHookConfigJson())
        ..writeln('# .mcp.json')
        ..writeln(agentMcpConfigJson())
        ..writeln('# CLAUDE.md (or AGENTS.md) — managed block')
        ..write(agentGuideBlock);
    case setupTargetCursor:
      output
        ..writeln('# .cursor/mcp.json')
        ..writeln(agentMcpConfigJson());
    case setupTargetOpenCode:
      output
        ..writeln('# opencode.json')
        ..writeln(agentOpenCodeConfigJson());
    case setupTargetCodex:
      output
        ..writeln('# ${_codexConfigFile().path}')
        ..write(codexMcpTomlBlock)
        ..writeln('# or: codex mcp add dartograph -- dartograph mcp');
    default:
      // 위에서 타깃을 검증하므로 도달하지 않는다.
      output.writeln('# unknown setup target');
  }
}

Future<int> _installSetup(
  String target,
  String? root,
  bool force,
  StringSink output,
  StringSink error,
) async {
  switch (target) {
    case setupTargetClaude:
      return _installClaudeSetup(root!, force, output, error);
    case setupTargetCursor:
      return _installMcpJsonSetup(
        File(p.join(root!, '.cursor', 'mcp.json')),
        force,
        output,
        error,
      );
    case setupTargetOpenCode:
      return _installOpenCodeSetup(
        File(p.join(root!, 'opencode.json')),
        force,
        output,
        error,
      );
    case setupTargetCodex:
      return _installCodexSetup(force, output, error);
  }
  return ExitStatus.usage.code;
}

Future<int> _uninstallSetup(
  String target,
  String? root,
  StringSink output,
  StringSink error,
) async {
  switch (target) {
    case setupTargetClaude:
      return _uninstallClaudeSetup(root!, output, error);
    case setupTargetCursor:
      return _uninstallMcpJsonSetup(
        File(p.join(root!, '.cursor', 'mcp.json')),
        output,
        error,
      );
    case setupTargetOpenCode:
      return _uninstallOpenCodeSetup(
        File(p.join(root!, 'opencode.json')),
        output,
        error,
      );
    case setupTargetCodex:
      return _uninstallCodexSetup(output, error);
  }
  return ExitStatus.usage.code;
}

Future<int> _installClaudeSetup(
  String root,
  bool force,
  StringSink output,
  StringSink error,
) async {
  final script = File(p.join(root, '.claude', 'hooks', agentHookScriptName));
  // init·skill과 같은 가드다. 링크 자체도 검사해 매달린 링크를 잡는다.
  if (!force && (await script.exists() || await Link(script.path).exists())) {
    error.writeln(
      '${script.path} already exists. Pass --force to overwrite it.',
    );
    return ExitStatus.usage.code;
  }
  final settings = File(p.join(root, '.claude', 'settings.json'));
  final mcpConfig = File(p.join(root, '.mcp.json'));
  final guide = await _claudeGuideFile(root);
  try {
    // 설정 파일은 통째로 쓰지 않고 기존 내용 위에 dartograph 항목만 병합한다.
    // 깨진 JSON·예상 밖 타입이면 FormatException으로 빠진다 — 병합을 먼저
    // 계산해 한쪽만 쓰이는 부분 설치를 피한다.
    final mergedSettings = mergeClaudeSettings(
      await settings.exists() ? await settings.readAsString() : null,
    );
    final mergedMcp = mergeMcpConfig(
      await mcpConfig.exists() ? await mcpConfig.readAsString() : null,
      force: force,
    );
    final mergedGuide = mergeClaudeGuide(
      await guide.exists() ? await guide.readAsString() : null,
      force: force,
    );

    await Directory(script.parent.path).create(recursive: true);
    AtomicWrite.stringSync(script, agentHookScript);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', script.path]);
    }
    output.writeln('Installed hook script at ${script.path}.');

    if (mergedSettings == null) {
      output.writeln('${settings.path} already registers the dartograph hook.');
    } else {
      AtomicWrite.stringSync(settings, mergedSettings);
      output.writeln('Registered the impact hook in ${settings.path}.');
    }

    if (mergedMcp == null) {
      output.writeln('${mcpConfig.path} already registers dartograph mcp.');
    } else {
      AtomicWrite.stringSync(mcpConfig, mergedMcp);
      output.writeln('Registered the MCP server in ${mcpConfig.path}.');
    }

    if (mergedGuide == null) {
      output.writeln('${guide.path} already has the dartograph block.');
    } else {
      AtomicWrite.stringSync(guide, mergedGuide);
      output.writeln('Added the dartograph block to ${guide.path}.');
    }
    return ExitStatus.success.code;
  } on FormatException catch (exception) {
    error.writeln('Setup failed: ${exception.message}');
    return ExitStatus.failure.code;
  } on FileSystemException {
    error.writeln('Setup failed: check the destination permissions.');
    return ExitStatus.failure.code;
  }
}

/// 안내 블록을 싣는 프로젝트 지시 파일을 고른다.
///
/// CLAUDE.md가 있으면 그것, 없고 AGENTS.md가 있으면 AGENTS.md(Claude Code가
/// 둘 다 읽는다), 둘 다 없으면 CLAUDE.md를 새로 만든다.
Future<File> _claudeGuideFile(String root) async {
  final claude = File(p.join(root, 'CLAUDE.md'));
  if (await claude.exists()) return claude;
  final agents = File(p.join(root, 'AGENTS.md'));
  if (await agents.exists()) return agents;
  return claude;
}

/// `mcpServers` JSON 설정(Cursor)에 dartograph 항목을 병합한다.
Future<int> _installMcpJsonSetup(
  File file,
  bool force,
  StringSink output,
  StringSink error,
) async {
  try {
    final merged = mergeMcpConfig(
      await file.exists() ? await file.readAsString() : null,
      force: force,
    );
    if (merged == null) {
      output.writeln('${file.path} already registers dartograph mcp.');
      return ExitStatus.success.code;
    }
    await file.parent.create(recursive: true);
    AtomicWrite.stringSync(file, merged);
    output.writeln('Registered the MCP server in ${file.path}.');
    return ExitStatus.success.code;
  } on FormatException catch (exception) {
    error.writeln('Setup failed: ${exception.message}');
    return ExitStatus.failure.code;
  } on FileSystemException {
    error.writeln('Setup failed: check the destination permissions.');
    return ExitStatus.failure.code;
  }
}

/// opencode `opencode.json`에 dartograph 항목을 병합한다.
Future<int> _installOpenCodeSetup(
  File file,
  bool force,
  StringSink output,
  StringSink error,
) async {
  try {
    final merged = mergeOpenCodeConfig(
      await file.exists() ? await file.readAsString() : null,
      force: force,
    );
    if (merged == null) {
      output.writeln('${file.path} already registers dartograph mcp.');
      return ExitStatus.success.code;
    }
    await file.parent.create(recursive: true);
    AtomicWrite.stringSync(file, merged);
    output.writeln('Registered the MCP server in ${file.path}.');
    return ExitStatus.success.code;
  } on FormatException catch (exception) {
    error.writeln('Setup failed: ${exception.message}');
    return ExitStatus.failure.code;
  } on FileSystemException {
    error.writeln('Setup failed: check the destination permissions.');
    return ExitStatus.failure.code;
  }
}

/// Codex 전역 `config.toml`에 dartograph MCP 블록을 병합한다.
Future<int> _installCodexSetup(
  bool force,
  StringSink output,
  StringSink error,
) async {
  final file = _codexConfigFile();
  try {
    final merged = mergeCodexConfig(
      await file.exists() ? await file.readAsString() : null,
      force: force,
    );
    if (merged == null) {
      output.writeln('${file.path} already registers dartograph mcp.');
      return ExitStatus.success.code;
    }
    await file.parent.create(recursive: true);
    AtomicWrite.stringSync(file, merged);
    output.writeln('Registered the MCP server in ${file.path}.');
    return ExitStatus.success.code;
  } on FormatException catch (exception) {
    error.writeln('Setup failed: ${exception.message}');
    return ExitStatus.failure.code;
  } on FileSystemException {
    error.writeln('Setup failed: check the destination permissions.');
    return ExitStatus.failure.code;
  }
}

/// Claude Code 훅·MCP 항목과 생성한 훅 스크립트를 되돌린다.
Future<int> _uninstallClaudeSetup(
  String root,
  StringSink output,
  StringSink error,
) async {
  final script = File(p.join(root, '.claude', 'hooks', agentHookScriptName));
  final settings = File(p.join(root, '.claude', 'settings.json'));
  final mcpConfig = File(p.join(root, '.mcp.json'));
  try {
    var removed = false;
    if (await settings.exists()) {
      final remaining = removeClaudeSettingsHook(await settings.readAsString());
      if (remaining != null) {
        AtomicWrite.stringSync(settings, remaining);
        output.writeln('Removed the dartograph hook from ${settings.path}.');
        removed = true;
      }
    }
    if (await mcpConfig.exists()) {
      final remaining = removeMcpServerEntry(await mcpConfig.readAsString());
      if (remaining != null) {
        AtomicWrite.stringSync(mcpConfig, remaining);
        output.writeln(
          'Removed the dartograph MCP server from ${mcpConfig.path}.',
        );
        removed = true;
      }
    }
    // 설치가 고른 파일과 무관하게 양쪽 후보를 검사한다 — 블록이 어느 쪽에
    // 들어갔어도 되돌린다. 설치와 같은 규칙으로 어느 파일도 쓰기 전에 두
    // 파일의 제거 결과를 모두 계산해 부분 uninstall을 피한다.
    final guideWrites = <File, ({String original, String remaining})>{};
    for (final name in const ['CLAUDE.md', 'AGENTS.md']) {
      final guide = File(p.join(root, name));
      if (!await guide.exists()) continue;
      final original = await guide.readAsString();
      String? remaining;
      try {
        remaining = removeClaudeGuide(original);
      } on FormatException catch (e) {
        throw FormatException('${guide.path}: ${e.message}');
      }
      if (remaining != null) {
        guideWrites[guide] = (original: original, remaining: remaining);
      }
    }
    for (final entry in guideWrites.entries) {
      final guide = entry.key;
      // 파일 전체가 현재 생성 블록과 byte가 같을 때만 설치가 만든 파일로 보고
      // 지운다 — 이전 버전이 쓴 블록이나 안쪽을 사용자가 고친 블록은 "우리
      // 것"이 증명 불가라 내용만 벗기고 파일은 남긴다(빈 파일이 될 수 있다).
      if (entry.value.original.trim() == agentGuideBlock.trim()) {
        await guide.delete();
        output.writeln('Removed ${guide.path}.');
      } else {
        AtomicWrite.stringSync(guide, entry.value.remaining);
        output.writeln('Removed the dartograph block from ${guide.path}.');
      }
      removed = true;
    }
    // 생성한 훅 스크립트만 지운다 — 내용이 우리 것이 아니면 남긴다.
    final type = await FileSystemEntity.type(script.path, followLinks: false);
    if (type == FileSystemEntityType.file &&
        (await script.readAsString()).contains(
          'Generated by `dartograph setup --install`',
        )) {
      await script.delete();
      output.writeln('Removed ${script.path}.');
      removed = true;
    }
    if (!removed) {
      output.writeln('Nothing to uninstall for Claude Code in $root.');
    }
    return ExitStatus.success.code;
  } on FormatException catch (exception) {
    error.writeln('Setup failed: ${exception.message}');
    return ExitStatus.failure.code;
  } on FileSystemException {
    error.writeln('Setup failed: check the destination permissions.');
    return ExitStatus.failure.code;
  }
}

/// `mcpServers` JSON 설정(Cursor)에서 dartograph 항목을 되돌린다.
Future<int> _uninstallMcpJsonSetup(
  File file,
  StringSink output,
  StringSink error,
) async {
  if (!await file.exists()) {
    output.writeln('Nothing to uninstall: ${file.path} does not exist.');
    return ExitStatus.success.code;
  }
  try {
    final remaining = removeMcpServerEntry(await file.readAsString());
    if (remaining == null) {
      output.writeln('${file.path} does not register dartograph mcp.');
      return ExitStatus.success.code;
    }
    AtomicWrite.stringSync(file, remaining);
    output.writeln('Removed the dartograph MCP server from ${file.path}.');
    return ExitStatus.success.code;
  } on FormatException catch (exception) {
    error.writeln('Setup failed: ${exception.message}');
    return ExitStatus.failure.code;
  } on FileSystemException {
    error.writeln('Setup failed: check the destination permissions.');
    return ExitStatus.failure.code;
  }
}

/// opencode `opencode.json`에서 dartograph 항목을 되돌린다.
Future<int> _uninstallOpenCodeSetup(
  File file,
  StringSink output,
  StringSink error,
) async {
  if (!await file.exists()) {
    output.writeln('Nothing to uninstall: ${file.path} does not exist.');
    return ExitStatus.success.code;
  }
  try {
    final remaining = removeOpenCodeEntry(await file.readAsString());
    if (remaining == null) {
      output.writeln('${file.path} does not register dartograph mcp.');
      return ExitStatus.success.code;
    }
    AtomicWrite.stringSync(file, remaining);
    output.writeln('Removed the dartograph MCP server from ${file.path}.');
    return ExitStatus.success.code;
  } on FormatException catch (exception) {
    error.writeln('Setup failed: ${exception.message}');
    return ExitStatus.failure.code;
  } on FileSystemException {
    error.writeln('Setup failed: check the destination permissions.');
    return ExitStatus.failure.code;
  }
}

/// Codex 전역 `config.toml`에서 dartograph MCP 블록을 되돌린다.
Future<int> _uninstallCodexSetup(StringSink output, StringSink error) async {
  final file = _codexConfigFile();
  if (!await file.exists()) {
    output.writeln('Nothing to uninstall: ${file.path} does not exist.');
    return ExitStatus.success.code;
  }
  try {
    final remaining = removeCodexConfig(await file.readAsString());
    if (remaining == null) {
      output.writeln('${file.path} does not register dartograph mcp.');
      return ExitStatus.success.code;
    }
    if (remaining.trim().isEmpty) {
      await file.delete();
      output.writeln(
        'Removed the dartograph MCP server and deleted empty ${file.path}.',
      );
    } else {
      AtomicWrite.stringSync(file, remaining);
      output.writeln('Removed the dartograph MCP server from ${file.path}.');
    }
    return ExitStatus.success.code;
  } on FileSystemException {
    error.writeln('Setup failed: check the destination permissions.');
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

/// `bridges`와 `schema` 명령을 실행한다.
///
/// 두 명령은 같은 교환 문서 계약(형식·`--project` 조인 루트·pub workspace
/// 감지)을 공유하고 추출 표면만 다르다. [schema]이면 persistence 도메인의
/// `relation-use` 문서를 만들며 transport 플래그는 받지 않는다.
Future<int> _runBridges(
  List<String> arguments,
  StringSink output,
  StringSink error,
  DateTime Function() now, {
  bool schema = false,
}) async {
  // `--project <shared-root>`는 위치 인자 사이에 어디든 올 수 있다(query의
  // `--depth`와 같은 규칙). 중복·값 빠짐·옵션 모양 값은 usage(64)다.
  String? projectOption;
  var messagesOption = false;
  var eventsOption = false;
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
    if (argument == '--events') {
      if (eventsOption) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      eventsOption = true;
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
  // 문서 하나는 transport 하나다. 두 플래그를 같이 받으면 한 문서에
  // 두 transport가 섞이므로 isthmus처럼 각각 실행하게 앞에서 거부한다.
  if (messagesOption && eventsOption) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  // persistence 문서는 버전 1 하나뿐이다 — transport 플래그는 bridges 전용이다.
  if (schema && (messagesOption || eventsOption)) {
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
    if (schema) {
      final indexed = indexSchema(
        root,
        projectRootPath: project == root ? null : project,
      );
      output.write(
        exportBridgeFacts(
          project: project,
          generatedAt: now(),
          facts: indexed.facts,
          limitations: [...indexed.limitations, ...projectLimitations],
          target: 'persistence',
        ),
      );
      return ExitStatus.success.code;
    }
    final indexed = indexBridges(
      root,
      projectRootPath: project == root ? null : project,
      messages: messagesOption,
      events: eventsOption,
    );
    output.write(
      exportBridgeFacts(
        project: project,
        generatedAt: now(),
        facts: indexed.facts,
        limitations: [...indexed.limitations, ...projectLimitations],
        version: (messagesOption || eventsOption) ? 2 : 1,
        transport: messagesOption
            ? 'basic-message-channel'
            : (eventsOption ? 'event-channel' : null),
      ),
    );
    return ExitStatus.success.code;
  } on FormatException {
    // 제어문자·빈 fact 값의 전면 거부는 bridges 추출 정책이다(GRAPH-EXCHANGE
    // 계약). 인덱싱 실패로 답하면 원인을 반대로 가리킨다.
    error.writeln(
      '${schema ? 'Schema' : 'Bridges'} extraction failed: a fact value or '
      'source path contains control characters.',
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
  List<String> failedItems,
) async {
  String? explainId;
  String? baselinePath;
  String? since;
  String? codeownersPath;
  Set<String>? kinds;
  ReportFormat? reportFormat;
  String? rootPath;
  var reportTestOnly = false;
  var reportRedundantPublic = false;
  var codeownersFormat = false;
  var closedApp = false;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (const {
      '--explain',
      '--format',
      '--baseline',
      '--since',
      '--codeowners',
      '--kinds',
    }.contains(argument)) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = arguments[index];
      // valued 옵션 중복은 boolean 플래그와 같은 기준으로 거부한다 — 조용한
      // last-win은 사용자가 지정한 의도를 침묵 속에 바꾼다.
      final alreadySet = switch (argument) {
        '--explain' => explainId != null,
        '--format' => reportFormat != null || codeownersFormat,
        '--baseline' => baselinePath != null,
        '--since' => since != null,
        '--codeowners' => codeownersPath != null,
        '--kinds' => kinds != null,
        _ => false,
      };
      if (alreadySet) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      switch (argument) {
        case '--kinds':
          kinds = _parseCsvFilter(value, '--kinds', const {
            'declaration',
            'file',
          }, error);
          if (kinds == null) return ExitStatus.usage.code;
        case '--explain':
          // 값은 경로가 아니라 심볼 ID다. `<no-library>`처럼 특수한 형태가
          // 있으므로 대시 가드를 적용하지 않는다. 값이 빠진 오타는 뒤따르는
          // 위치 인자가 남아 이미 usage(64)로 떨어진다.
          explainId = value;
        case '--format':
          if (value == 'codeowners') {
            codeownersFormat = true;
            reportFormat = null;
          } else {
            codeownersFormat = false;
            reportFormat = value == 'github-actions'
                ? ReportFormat.githubActions
                : ReportFormat.values
                      .where((item) => item.name == value)
                      .firstOrNull;
            if (reportFormat == null) {
              error.writeln(
                'Unknown report format: $value '
                '(expected text, json, markdown, codeowners, github-actions, '
                'or sarif).',
              );
              return ExitStatus.usage.code;
            }
          }
        case '--codeowners':
          if (value.startsWith('-')) {
            error.write(_help);
            return ExitStatus.usage.code;
          }
          codeownersPath = value;
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
    } else if (argument == '--closed-app') {
      if (closedApp) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      closedApp = true;
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
  // --closed-app은 공개 API 보존을 거는 분석이므로, 그 보존을 전제로 답하는
  // --report-redundant-public과는 전제가 모순되어 결합하지 않는다.
  if (rootPath == null ||
      (reportFormat == null && !codeownersFormat) ||
      (codeownersFormat && codeownersPath == null) ||
      (!codeownersFormat && codeownersPath != null) ||
      (reportTestOnly && reportRedundantPublic) ||
      (closedApp && reportRedundantPublic) ||
      (explainId != null &&
          (codeownersFormat ||
              reportFormat != ReportFormat.json ||
              baselinePath != null ||
              since != null ||
              kinds != null ||
              reportTestOnly ||
              reportRedundantPublic)) ||
      ((reportTestOnly || reportRedundantPublic) && baselinePath != null)) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(rootPath);
    final limitations = _limitations(indexed);
    if (closedApp) {
      limitations.add(
        'closed-app: public API surface is not preserved; findings assume the '
        'package is a standalone application, not a published library',
      );
    }
    // closed-app은 라이브러리 소비자라는 전제를 걷어낸다 — publicApi 루트만
    // 빼고 나머지 보존 계약(main·테스트·annotation·설정 진입점)은 그대로다.
    final roots = closedApp
        ? (Map.of(indexed.retentionRoots)
            ..removeWhere((_, reason) => reason == RetentionReason.publicApi))
        : indexed.retentionRoots;
    final analyzer = ReachabilityAnalyzer();
    final snapshot = indexed.graph.snapshot();
    if (explainId != null) {
      final explanation = analyzer
          .analyze(snapshot, roots: roots, limitations: limitations)
          .explain(explainId);
      output.writeln(jsonEncode(explanation.toJson()));
      if (explanation.known && !explanation.reachable) {
        failedItems.add(explainId);
      }
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
        roots: roots,
        limitations: limitations,
      );
    } else if (reportRedundantPublic) {
      findings = analyzer.redundantPublicDeclarations(
        snapshot,
        roots: roots,
        limitations: limitations,
      );
    } else {
      final result = analyzer.analyze(
        snapshot,
        roots: roots,
        limitations: limitations,
      );
      findings = [...result.deadDeclarations, ...result.deadFiles]
        ..sort((a, b) {
          final kindOrder = a.kind.compareTo(b.kind);
          return kindOrder != 0 ? kindOrder : a.id.compareTo(b.id);
        });
    }
    var reported = findings;
    // kind 필터는 보고 대상 선택이다 — baseline 억제·--since 범위 좁히기와
    // 조합해도 발견 지문은 바뀌지 않는다.
    if (kinds != null) {
      reported = reported
          .where((finding) => kinds!.contains(finding.kind))
          .toList();
    }
    final scope = _scopeMatchers(indexed.includeGlobs, indexed.excludeGlobs);
    if (scope != null) {
      limitations.add(
        'include-exclude: dartograph.yaml include/exclude globs narrow '
        'reported findings; the graph and fingerprints are unchanged',
      );
      reported = reported
          .where((finding) => _inScope(scope, finding.source))
          .toList();
    }
    if (since != null) {
      final changed = await changedFilesSince(since, rootPath);
      final canonicalRoot = await Directory(rootPath).resolveSymbolicLinks();
      // 같은 파일의 finding마다 링크 해석 syscall을 반복하지 않도록 고유
      // source당 1회만 해석한다(감사 P8). syscall이 파일 수에 비례하므로
      // 직렬로 두지 않고 한꺼번에 돌린다.
      final reportedSources = reported
          .map((finding) => finding.source)
          .toSet()
          .toList();
      final reportedCanonicals = await Future.wait(
        reportedSources.map(
          (source) => _canonicalSource(canonicalRoot, source),
        ),
      );
      final canonicalBySource = Map.fromIterables(
        reportedSources,
        reportedCanonicals,
      );
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
    if (codeownersFormat) {
      output.write(
        CodeownersReporter.render(
          reported,
          CodeOwners.parse(await readConfiguration(File(codeownersPath!))),
          report: report,
          limitations: limitations,
          suppressedCount: suppressedCount,
        ),
      );
    } else {
      output.write(
        DeadReporter.render(
          reportFormat!,
          reported,
          limitations: limitations,
          suppressedCount: suppressedCount,
          report: report,
        ),
      );
    }
    failedItems.addAll([for (final finding in reported) finding.id]);
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

Future<int> _runDeps(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
  List<String> failedItems,
) async {
  ReportFormat? format;
  Set<String>? kinds;
  String? rootPath;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--kinds' && kinds == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      kinds = _parseCsvFilter(arguments[index], '--kinds', const {
        'unused-dependency',
        'unused-dev-dependency',
        'dev-dependency-in-lib',
        'undeclared-dependency',
      }, error);
      if (kinds == null) return ExitStatus.usage.code;
    } else if (argument == '--format' && format == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = arguments[index];
      format = ReportFormat.values
          .where((item) => item.name == value)
          .firstOrNull;
      if (format == null) {
        error.writeln(
          'Unknown report format: $value '
          '(expected text, json, markdown, github-actions, or sarif).',
        );
        return ExitStatus.usage.code;
      }
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
  try {
    final indexed = await indexPackage(rootPath);
    final limitations = _limitations(indexed);
    limitations.add(
      'package-usage: usage is observed from package: import/export directives '
      'only; runtime loading, generated-code, and asset references are '
      'invisible to this audit',
    );
    var findings = <DependencyFinding>[];
    if (indexed.workspacePackages.isEmpty) {
      final declared = <String>{
        ...indexed.declaredDependencies,
        ...indexed.declaredDevDependencies,
        ...indexed.declaredDependencyOverrides,
      };
      final toolCheck = detectToolLikeDependencies(rootPath, declared);
      limitations.addAll(toolCheck.limitations);
      findings = DependencyAudit()
          .audit(
            packageName: indexed.packageName,
            dependencies: indexed.declaredDependencies,
            devDependencies: indexed.declaredDevDependencies,
            dependencyOverrides: indexed.declaredDependencyOverrides,
            packageImports: indexed.packageImports,
            toolLike: toolCheck.toolLike,
          )
          .toList();
    } else {
      // 패키지마다 자기 pubspec 선언과 자기 소스로 감사한다 — 루트 매니페스트를
      // 멤버 소스에 적용하면 멤버의 선언·사용이 모두 잘못 판정된다.
      final memberPaths = [
        for (final member in indexed.workspacePackages) member.path,
      ]..sort((a, b) => b.length - a.length);
      String ownerOf(String source) {
        for (final path in memberPaths) {
          if (source.startsWith('project:$path/')) return path;
        }
        return '';
      }

      Map<String, List<String>> importsFor(String owner) {
        final scoped = <String, List<String>>{};
        for (final entry in indexed.packageImports.entries) {
          final sources = [
            for (final source in entry.value)
              if (ownerOf(source) == owner) source,
          ];
          if (sources.isNotEmpty) scoped[entry.key] = sources;
        }
        return scoped;
      }

      final rootDeclared = <String>{
        ...indexed.declaredDependencies,
        ...indexed.declaredDevDependencies,
        ...indexed.declaredDependencyOverrides,
      };
      final rootToolCheck = detectToolLikeDependencies(rootPath, rootDeclared);
      limitations.addAll(rootToolCheck.limitations);
      findings.addAll(
        DependencyAudit().audit(
          packageName: indexed.packageName,
          dependencies: indexed.declaredDependencies,
          devDependencies: indexed.declaredDevDependencies,
          dependencyOverrides: indexed.declaredDependencyOverrides,
          packageImports: importsFor(''),
          toolLike: rootToolCheck.toolLike,
          manifest: 'pubspec.yaml',
        ),
      );
      for (final member in indexed.workspacePackages) {
        final declared = <String>{
          ...member.dependencies,
          ...member.devDependencies,
          ...member.dependencyOverrides,
        };
        final memberToolCheck = detectToolLikeDependencies(
          p.join(rootPath, member.path),
          declared,
        );
        limitations.addAll(memberToolCheck.limitations);
        findings.addAll(
          DependencyAudit().audit(
            packageName: member.name,
            dependencies: member.dependencies,
            devDependencies: member.devDependencies,
            dependencyOverrides: member.dependencyOverrides,
            packageImports: importsFor(member.path),
            toolLike: memberToolCheck.toolLike,
            productionPrefix: 'project:${member.path}/lib/',
            manifest: '${member.path}/pubspec.yaml',
          ),
        );
      }
    }
    findings = findings
        .where((finding) => kinds == null || kinds.contains(finding.kind))
        .toList();
    final scope = _scopeMatchers(indexed.includeGlobs, indexed.excludeGlobs);
    if (scope != null) {
      limitations.add(
        'include-exclude: dartograph.yaml include/exclude globs narrow '
        'reported findings; the graph and fingerprints are unchanged',
      );
      // 소스를 싣는 발견은 근거 경로를 범위로 좁힌다 — 근거가 전부 빠진
      // 발견은 관측 자체가 사라진 것이라 본다. 패키지 수준 발견
      // (unused-dependency류, sources 없음)은 경로를 모르니 그대로 둔다.
      final scoped = <DependencyFinding>[];
      for (final finding in findings) {
        if (finding.sources.isEmpty) {
          scoped.add(finding);
          continue;
        }
        final sources = finding.sources
            .where((source) => _inScope(scope, source))
            .toList();
        if (sources.isEmpty) continue;
        scoped.add(
          DependencyFinding(
            name: finding.name,
            kind: finding.kind,
            reason: finding.reason,
            sources: sources,
            manifest: finding.manifest,
          ),
        );
      }
      findings = scoped;
    }
    output.write(
      DependencyReporter.render(
        format ?? ReportFormat.text,
        findings,
        limitations: limitations,
      ),
    );
    failedItems.addAll([
      for (final finding in findings)
        'deps:${finding.kind}:${finding.name}'
            '${finding.manifest == null ? '' : ':${finding.manifest}'}',
    ]);
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

/// `dartograph.yaml`의 include/exclude glob을 한 번 컴파일해 둔다.
///
/// 반환값이 null이면 설정이 없다는 뜻이다 — 매칭 비용도 한계 문구도 없다.
({List<RegExp> include, List<RegExp> exclude})? _scopeMatchers(
  List<String> includeGlobs,
  List<String> excludeGlobs,
) {
  if (includeGlobs.isEmpty && excludeGlobs.isEmpty) return null;
  return (
    include: [for (final pattern in includeGlobs) PathGlob.compile(pattern)!],
    exclude: [for (final pattern in excludeGlobs) PathGlob.compile(pattern)!],
  );
}

/// [source]가 include/exclude 범위 안인지 본다. 매칭은 소스 ID의 스킴을 뗀다.
bool _inScope(
  ({List<RegExp> include, List<RegExp> exclude}) scope,
  String source,
) {
  final separator = source.indexOf(':');
  final path = separator < 0 ? source : source.substring(separator + 1);
  if (scope.include.isNotEmpty &&
      !scope.include.any((matcher) => matcher.hasMatch(path))) {
    return false;
  }
  return !scope.exclude.any((matcher) => matcher.hasMatch(path));
}

/// `--kinds`·`--statuses` 같은 `<csv>` 옵션을 유효값 집합으로 파싱한다.
///
/// 모르는 값·빈 항목은 조용히 아무 발견도 내지 않는 필터가 되므로 유효값
/// 목록과 함께 usage 오류로 거부한다. [option]은 오류 메시지에 쓰는 옵션
/// 이름이다.
Set<String>? _parseCsvFilter(
  String value,
  String option,
  Set<String> valid,
  StringSink error,
) {
  final items = value.split(',').map((item) => item.trim()).toSet();
  if (items.isEmpty || items.any((item) => item.isEmpty)) {
    error.writeln('Invalid $option: $value (expected comma-separated values).');
    return null;
  }
  final unknown = items.difference(valid).toList()..sort();
  if (unknown.isNotEmpty) {
    error.writeln(
      'Unknown $option: ${unknown.join(', ')} '
      '(expected ${valid.toList()..sort()}).',
    );
    return null;
  }
  return items;
}

Future<int> _runDup(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
  List<String> failedItems,
) async {
  ReportFormat? format;
  int? minTokens;
  Set<String>? kinds;
  String? rootPath;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--kinds' && kinds == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      kinds = _parseCsvFilter(arguments[index], '--kinds', const {
        'duplicate-block',
      }, error);
      if (kinds == null) return ExitStatus.usage.code;
    } else if (argument == '--format' && format == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = arguments[index];
      format = ReportFormat.values
          .where((item) => item.name == value)
          .firstOrNull;
      if (format == null) {
        error.writeln(
          'Unknown report format: $value '
          '(expected text, json, markdown, github-actions, or sarif).',
        );
        return ExitStatus.usage.code;
      }
    } else if (argument == '--min-tokens' && minTokens == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final value = int.tryParse(arguments[index]);
      if (value == null || value < 2) {
        error.writeln(
          'Invalid --min-tokens: ${arguments[index]} (expected an integer ≥ 2).',
        );
        return ExitStatus.usage.code;
      }
      minTokens = value;
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
  final window = minTokens ?? 50;
  try {
    final indexed = await indexPackage(rootPath);
    final limitations = _limitations(indexed);
    limitations.add(
      'duplication-scope: matching is token-structural within analyzed '
      'sources; generated files are excluded and semantic equivalence is '
      'not required — findings are review candidates, not merge advice',
    );
    final report = DuplicationAnalyzer().analyze(
      indexed.tokenSegments,
      minTokens: window,
    );
    limitations.addAll(report.limitations);
    var findings = kinds == null
        ? report.findings
        : report.findings
              .where((finding) => kinds!.contains(finding.kind))
              .toList();
    final scope = _scopeMatchers(indexed.includeGlobs, indexed.excludeGlobs);
    if (scope != null) {
      limitations.add(
        'include-exclude: dartograph.yaml include/exclude globs narrow '
        'reported findings; the graph and fingerprints are unchanged',
      );
      // 인스턴스를 범위로 좁힌다 — 한 위치만 남으면 쌍이 성립하지 않는다.
      final scoped = <DuplicationFinding>[];
      for (final finding in findings) {
        final instances = finding.instances
            .where((instance) => _inScope(scope, instance.source))
            .toList();
        if (instances.length < 2) continue;
        scoped.add(
          DuplicationFinding(
            tokenCount: finding.tokenCount,
            instances: instances,
          ),
        );
      }
      findings = scoped;
    }
    output.write(
      DuplicationReporter.render(
        format ?? ReportFormat.text,
        findings,
        limitations: limitations,
        minTokens: window,
      ),
    );
    failedItems.addAll([
      for (final finding in findings)
        'dup:${finding.instances.first.source}:${finding.instances.first.startLine}',
    ]);
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
  // 옵션 모양의 값을 경로로 받으면 `baseline --write --force .`이 `--force`라는
  // 이름의 파일을 실제로 만들고 성공을 보고한다. 인덱싱과 쓰기 전에 거부한다.
  // `-`로 시작하는 실제 경로는 `./-name`으로 전달한다.
  if (arguments.length < 3 ||
      arguments.length > 4 ||
      arguments[0] != '--write' ||
      arguments[1].startsWith('-')) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  final tail = arguments.skip(2).toList();
  final closedApp = tail.remove('--closed-app');
  if (tail.length != 1 || tail.first.startsWith('-')) {
    error.write(_help);
    return ExitStatus.usage.code;
  }
  try {
    final indexed = await indexPackage(tail.first);
    final limitations = _limitations(indexed);
    // dead --closed-app과 같은 루트 집합에서 지문을 만들어야 억제가 맞는다.
    final roots = closedApp
        ? (Map.of(indexed.retentionRoots)
            ..removeWhere((_, reason) => reason == RetentionReason.publicApi))
        : indexed.retentionRoots;
    final result = ReachabilityAnalyzer().analyze(
      indexed.graph.snapshot(),
      roots: roots,
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
  List<String> failedItems,
) async {
  // 검증은 기본 수행한다(--no-verify로 끈다). --env·--dart-define은 반복
  // 지정할 수 있고 같은 키를 두 번 주면 마지막 값이 이긴다. 그 밖의 옵션은
  // impact와 같이 중복을 거부한다 — 값이 조용히 버려지면 사용자는 자기가 준
  // 입력이 판정에 쓰였다고 믿게 된다.
  var verify = true;
  var verifySeen = false;
  var workspace = false;
  RuntimeFormat? format;
  final dartDefines = <String, String>{};
  final environment = <String, String>{};
  var environmentGiven = false;
  int? limitOption;
  Set<RuntimeFactKind>? kinds;
  Set<String>? statuses;
  String? failOn;
  String? entrypoint;
  String? rootPath;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--workspace' && !workspace) {
      workspace = true;
    } else if ((argument == '--verify' || argument == '--no-verify') &&
        !verifySeen) {
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
    } else if (argument == '--kinds' && kinds == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      final keys = _parseCsvFilter(arguments[index], '--kinds', {
        for (final kind in RuntimeFactKind.values) kind.key,
      }, error);
      if (keys == null) return ExitStatus.usage.code;
      kinds = {
        for (final key in keys)
          RuntimeFactKind.values.firstWhere((kind) => kind.key == key),
      };
    } else if (argument == '--statuses' && statuses == null) {
      if (++index >= arguments.length) {
        error.write(_help);
        return ExitStatus.usage.code;
      }
      statuses = _parseCsvFilter(
        arguments[index],
        '--statuses',
        runtimeStatuses,
        error,
      );
      if (statuses == null) return ExitStatus.usage.code;
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
  // 판정을 끈 실행에는 판정 절 필터가 걸릴 목록이 없다 — 조용한 no-op
  // 옵션으로 두기보다 조합 오류로 알린다.
  if (!verify && statuses != null) {
    error.writeln(
      '--statuses requires verification and does not combine with '
      '--no-verify.',
    );
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
    // 루트 밖 링크의 내용이 사실로 흘러드는 것을 limitation으로 드러낸다.
    final linkEscapes = <String>{};
    final facts = await RuntimeScanner().scan(
      rootPath,
      linkEscapes: linkEscapes,
      aggregateWorkspace: workspace,
    );
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
      kinds: kinds,
      statuses: statuses,
      extraLimitations: [
        for (final escape in linkEscapes.toList()..sort())
          'symlink-escape: $escape resolves outside its package root; its '
              'contents are scanned as project sources',
      ],
    );
    output.write(RuntimeReporter.render(format ?? RuntimeFormat.text, report));
    failedItems.addAll([
      for (final item in report.missing) item.fact.id,
      for (final item in report.unverified) item.fact.id,
    ]);
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
    // LineSplitter는 개행 전까지 무제한 버퍼링한다 — 메시지 크기 상한은
    // 바이트 단계에서 둔다.
    input: stdin.transform(boundedUtf8Lines(mcpMaxMessageBytes)),
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
       dartograph graph --format <dot|json|mermaid|html|anon> [--level <file|type|symbol>] [--collapse <n>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph dead [--explain <symbol-id>] --format <text|json|markdown|codeowners|github-actions|sarif> [--codeowners <file>] [--baseline <file>] [--since <ref>] [--kinds <csv>] [--closed-app] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph dead --report-test-only --format <text|json|markdown|codeowners|github-actions|sarif> [--codeowners <file>] [--since <ref>] [--kinds <csv>] [--closed-app] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph dead --report-redundant-public --format <text|json|markdown|codeowners|github-actions|sarif> [--codeowners <file>] [--since <ref>] [--kinds <csv>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph deps [--format <text|json|markdown|github-actions|sarif>] [--kinds <csv>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph dup [--format <text|json|markdown|github-actions|sarif>] [--min-tokens <n>] [--kinds <csv>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph baseline --write <file> [--closed-app] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph query <symbol-id-or-name> [--baseline <file>] [--depth <n>] [--limit <n>] [--with-source] [--source-context <n>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph query --batch <requests.json> [--baseline <file>] [--depth <n>] [--limit <n>] [--with-source] [--source-context <n>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph compare [--format <text|json|sarif>] [--incremental <dir>] [--workspace] [--record <dir>] <before-package-root> <after-package-root>
       dartograph affected [--format <text|json|sarif>] [--incremental <dir>] [--workspace] [--record <dir>] <git-ref> <package-root>
       dartograph impact --since <git-ref> [--format <text|json|markdown|github-actions|sarif|test-list>] [--depth <n>] [--limit <n>] [--fail-on <level>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph impact --changed <changes.json> [--format <text|json|markdown|github-actions|sarif|test-list>] [--depth <n>] [--limit <n>] [--fail-on <level>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph impact --symbol <symbol-id> [--format <text|json|markdown|github-actions|sarif|test-list>] [--depth <n>] [--limit <n>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph skill [--install <skills-directory> [--force]]
       dartograph setup [--target <claude|cursor|codex|opencode>] [--install [<package-root>] [--force]] [--uninstall [<package-root>]]
       dartograph runtime [--verify|--no-verify] [--format <fmt>] [--dart-define KEY=VALUE]... [--env KEY=VALUE]... [--limit <n>] [--kinds <csv>] [--statuses <csv>] [--fail-on <none|low|medium|high>] [--execute <dart-entrypoint>] [--workspace] [--record <dir>] <package-root>
       dartograph history --ledger <dir> [--commit <sha>] [--format <text|json>]
       dartograph mcp
       dartograph bridges --format json [--project <shared-root>] <package-root>
       dartograph bridges --messages --format json [--project <shared-root>] <package-root>
       dartograph bridges --events --format json [--project <shared-root>] <package-root>
       dartograph schema --format json [--project <shared-root>] <package-root>
       dartograph cycles [--format <text|json|sarif>] [--strict] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph cycles --explain <symbol-id> [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph rules --config <yaml-file> [--format <text|json|sarif>] [--strict] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph rules --config <yaml-file> --explain <symbol-id> [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
       dartograph metrics [--format <text|json|sarif>] [--strict] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>

init writes a commented dartograph.yaml configuration template to the project
root. Pass --force to overwrite an existing configuration file.

skill prints an installable agent skill. --install writes
<skills-directory>/dartograph/SKILL.md; pass --force to overwrite an existing
file (a symlink at that path is replaced as a link, never followed).

setup prints or installs agent MCP integration without MCP calls. --target
selects claude (default), cursor, codex, or opencode. With no options it
prints the target's artifacts for review. For claude, --install writes
<package-root>/.claude/hooks/dartograph-impact.sh, merges the PostToolUse hook
into <package-root>/.claude/settings.json, merges the dartograph MCP
server into <package-root>/.mcp.json, and merges a managed
<!-- dartograph:begin --> routing block into <package-root>/CLAUDE.md
(or AGENTS.md when only that file exists). cursor merges
<package-root>/.cursor/mcp.json and opencode merges
<package-root>/opencode.json. Codex reads only the global
\$CODEX_HOME/config.toml (default ~/.codex/config.toml), so its --install takes
no package root and merges a [mcp_servers.dartograph] block. Existing keys are
preserved; configs whose expected shape is wrong, or invalid JSON, fail
instead of being overwritten. --force replaces an existing dartograph entry.
--uninstall removes only the dartograph entries and, for claude, the generated
hook script and the managed guide block (a guide file holding exactly the
generated block is removed; a block whose interior was edited is stripped
but its file kept). The hook runs `dartograph impact --changed` after Dart
file edits
and requires dartograph on PATH; no paid service, login, or telemetry is
involved.


dead --format codeowners groups findings by the owners of their source paths
using a CODEOWNERS file passed to --codeowners <file>. The last matching rule
wins; *, **, ?, bracket character classes ([a-c], [!x]), and backslash escapes
are supported, a pattern containing "/" is anchored to the project root, and a
leading "!" exempts the match from ownership (the GitLab extension — GitHub
CODEOWNERS does not support "!"). Findings whose path matches
no rule are grouped under "(unowned)". The file path is not echoed in errors.
dead --explain requires --format json and does not combine with --baseline or
--since. dead --report-test-only answers a different question (production
declarations reached only from test code) at info severity, so it never fails
the build and does not combine with --explain or --baseline. dead
--report-redundant-public likewise answers at info severity (public
declarations whose observed references all come from their own library) with
the same combination rules. dead --closed-app stops retaining the public API
surface: only actual entry points (main functions, tests, annotations, and
configured entry_points) keep code alive. Use it for standalone applications,
not published libraries — the report is still a review list, not a deletion
instruction. Pass the same --closed-app to baseline --write so the recorded
fingerprints match. --closed-app does not combine with
--report-redundant-public, whose premise is public-API retention.

dartograph.yaml also accepts include/exclude globs that narrow which sources
produce dead, deps, and dup findings (matched against the source path without
its project:/package: scheme; the graph is unchanged), retained_names and
retained_files globs that keep declarations alive like dartograph:ignore
comments, and thresholds (distance, complexity) that metrics --strict gates
on. Every active config narrowing is reported as a limitation.

deps audits pubspec hygiene: declared dependencies no source imports
(unused-dependency, unused-dev-dependency), dev_dependencies referenced from
lib/ (dev-dependency-in-lib), and package: imports nothing declares
(undeclared-dependency). Packages with a confirmed tool contract — executables,
build.yaml builders, analysis_options include/plugins — count as used.
Findings are review candidates with evidence, not deletion instructions.

--kinds <csv> restricts which finding kinds dead, deps, and dup report:
dead takes declaration,file; deps takes the four kinds above; dup takes
duplicate-block. For runtime it narrows the reported fact categories
(env,dynamicLoad,config,asset,external) instead, and runtime --statuses
<csv> narrows the verdict sections (present,defaulted,missing,unverified);
--statuses does not combine with --no-verify since there is nothing to
filter without a judgement. Unknown values are usage errors. Filtering
narrows the reported lists — baselines, fingerprints, risk, limitations,
and exit-code semantics are unchanged, and --limit applies to the filtered
lists.

cycles/rules
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
version 2 with transport basic-message-channel. bridges --events emits
EventChannel receiveBroadcastStream listen facts as version 2 with transport
event-channel: a statically identified receiveBroadcastStream() call is
recorded as stream-listen whether or not the returned stream is consumed —
it does not prove the call executes, a listener is attached, a subscription
is active, or an event is received. The two flags are separate documents
and do not combine. The default bridges command keeps the version 1
MethodChannel output.

schema emits persistence relation-use facts (bridge-facts version 1, target
persistence) for the isthmus code-to-schema join: sqflite SQL and table
arguments, sqlite3/postgres SQL arguments, drift Table classes, custom queries
and .drift files, floor @Entity/@DatabaseView/@Query, and uppercase SQL string
literals. Non-literal SQL is kept as dynamic facts; non-SQL stores and
unsupported SQL packages are reported as limitations, not facts. It accepts
--project like bridges.

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

analyzer를 쓰는 명령(graph, dead, deps, dup, query, compare, affected, impact,
baseline, cycles, rules, metrics)은 --incremental <dir>를 받는다. 디렉터리에 파일별 사실
캐시를 두고 다음 실행에서 바뀐 파일과 그 파일을 import·export하는 폐쇄만 다시
해석한다. 산출물은 전체 해석과 byte 동일하다. 캐시가 없거나 손상됐거나 스키마가
다르거나 쓸 수 없으면 전체 해석으로 폴백하고 오류로 끝내지 않는다(쓸 수 없을
때만 그 사실을 limitation으로 남긴다). 캐시 디렉터리는 프로젝트마다 따로 쓴다.

The same commands accept --workspace (runtime too), which opts into pub
workspace aggregation: members listed in the root pubspec's workspace: list
are analyzed into one graph instead of being reported as
workspace-members-not-indexed. Each member's standard source directories
(lib, bin, example, integration_test, test) join the analysis, member
lib/<name>.dart libraries keep public-API retention, and deps audits every
package against its own pubspec (each finding names its manifest). Members
with missing directories or pubspecs are skipped and reported; a root that
declares no workspace: members, or a member pubspec with an invalid package
name, fails the analysis (exit 2). Member dartograph.yaml files are not
read — the root's configuration applies to the aggregate and an ignored
member config is reported as a limitation.

The same commands accept --record <dir>, which appends one JSON line per run to
<dir>/ledger.jsonl: tool version, UTC time, command, exit code, observed Git
HEAD (when available), the input flags (--env and --dart-define values are
reduced to their keys), and the identifiers of the reported problems. The file
is append-only — existing lines are never rewritten. A run whose ledger write
fails still returns its own exit code and prints a diagnostic on stderr.
history --ledger <dir> [--commit <sha>] [--format text|json] reads it back; a
truncated or damaged line is skipped and reported as a ledger-skipped-lines
limitation instead of failing the read.

Paths and files that begin with "-" are rejected as usage errors so that a
missing option value is not silently consumed. Pass such a path as "./-name".

impact answers "what does changing this affect?" before the edit. Give it a
git revision (--since), a JSON array of changed project-relative paths
(--changed), or one symbol id (--symbol); it reports the changed set, every
symbol that transitively uses it with a shortest usage path, the call sites
into changed declarations, the test libraries that depend on the changed set,
and a risk score with its factors. The coverage block counts the impacted
symbols that inspecting only the changed files would have missed.
--format test-list prints only the affected test library paths, one per line,
ready to feed `dart test` (it is never truncated by --limit; an empty list
means no affected tests — do not run bare `dart test` on empty output).
--fail-on <level> turns a risk level of at least <level> into exit 1
(default none). Impact is an observed dependency reachability, not a deletion
verdict; an unlisted declaration is not proven unaffected.

mcp runs a Model Context Protocol server on stdio (JSON-RPC 2.0) for AI
clients. It exposes five read-only tools over the existing CLI paths:
dartograph_explore (single entry point — pass packageRoot plus one
question shape and it routes internally: symbol/batch for dependency
evidence with source lines, impactSymbol/since/changed for impact
pre-checks, command for verifications and runtime facts), impact_query
(the impact pre-check), dependency_query (query/--batch), verify_run
(dead, deps, dup, cycles, rules, metrics with exit code and raw output;
closedApp selects dead --closed-app), and runtime_query (runtime
--no-verify static detection). Setting DARTOGRAPH_MCP_LEGACY_TOOLS=0 (or
false) makes tools/list advertise only dartograph_explore — the narrower
tools stay callable. It also serves three static resources
(dartograph://usage, dartograph://skill, dartograph://config) and four
prompts (impact-precheck, dead-code-review, dependency-audit,
duplication-review) that walk through the common workflows. Within one
server session, indexing reuses a per-package temporary incremental cache.
stdout carries only JSON-RPC; diagnostics stay on stderr. The caller
passes packageRoot per call. Nothing is modified by these tools.

runtime reports the dependencies that only appear at run time — environment
variables and dart-defines, dynamic loading (Isolate.spawnUri, Process.run,
DynamicLibrary.open, dart:mirrors), configuration paths, bundled assets, and
external URLs — and, by default, judges each one against this environment:
present, defaulted, or missing, with everything that could not be judged left
in `unverified` with its reason. Missing and unjudged facts feed a risk score.
--env and --dart-define are repeatable and replace their channels hermetically
(when --env is given, only those values are used and the process environment is
ignored); the values themselves are never printed. --verify is on by default
and --no-verify only detects. --kinds narrows the reported categories and
--statuses the verdict sections; both narrow only the reported lists — the
risk score and the unverifiedReasonCounts tally still describe the full
analysis. --fail-on <level> turns a risk level of at least <level> into
exit 1. --execute <dart-entrypoint> RUNS ARBITRARY CODE: it starts
`dart run <entrypoint>` in the package root (60s timeout), applies the --env
values on top of the inherited environment, and reports the exit code and a
stderr summary as execution evidence. A missing path is not proof that the
program cannot run, and a present one is not proof that it does.

Exit codes:
  0   success
  1   dead findings (including a dead --explain of an unreachable target),
      deps findings, or cycles/rules/metrics findings with --strict, or a
      runtime/impact risk level at or above --fail-on
  2   analysis failure
  64  usage error, or a query/--explain target not found in the graph
''';

/// MCP `dartograph://usage` 리소스가 노출하는 CLI 계약 본문이다(도움말과 같은 문서).
const cliUsageText = _help;
