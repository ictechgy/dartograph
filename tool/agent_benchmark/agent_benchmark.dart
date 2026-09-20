import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 에이전트 with/without 대조 벤치 하네스다.
///
/// `prepare` — tasks.json의 레포를 핀 리비전으로 클론하고 pub get과
///   `dartograph setup --install`로 MCP 배선을 만든다.
/// `run` — 각 task × arm × run마다 `claude -p`를 stream-json으로 실행해
///   트랜스크립트와 요약을 기록한다. without arm은 PATH에서 dartograph를
///   빼고 빈 MCP 설정을 강제해 오염을 막는다.
/// `score` — summary.jsonl을 task × arm 중앙값으로 집계한다.
///
/// 절대 수치는 SLA가 아니며 같은 arm끼리의 중앙값 비교만 의미 있다.
void main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    (args.isEmpty ? stderr : stdout).writeln(_usage);
    exit(args.isEmpty ? 64 : 0);
  }
  final command = args.first;
  final options = _parseArgs(args.sublist(1));
  switch (command) {
    case 'prepare':
      await _runPrepare(options);
    case 'run':
      await _runBenchmark(options);
    case 'score':
      _runScore(options);
    default:
      stderr.writeln('unknown command: $command');
      exit(64);
  }
}

const _usage = '''
agent_benchmark — with/without dartograph agent benchmark

  dart run tool/agent_benchmark/agent_benchmark.dart prepare
      --repos <dir> --tasks <file> [--only <repo,repo>] [--flutter-bin <path>]

  dart run tool/agent_benchmark/agent_benchmark.dart run
      --repos <dir> --tasks <file> --out <dir> [--arm with|without]
      [--runs <n=4>] [--model <m>] [--max-turns <n=24>]
      [--timeout-secs <n=900>] [--only <task,task>] [--runs-offset <n>]
      [--max-budget-usd <amount>] [--claude-bin <path>]

  dart run tool/agent_benchmark/agent_benchmark.dart score
      --out <dir> [--include-invalid]
''';

class _Options {
  _Options(this.values);

  final Map<String, String> values;

  String? get tasks => values['tasks'];
  String? get repos => values['repos'];
  String? get out => values['out'];
  String get arm => values['arm'] ?? 'both';
  int get runs => int.tryParse(values['runs'] ?? '') ?? 4;
  int get runsOffset => int.tryParse(values['runs-offset'] ?? '') ?? 0;
  int get maxTurns => int.tryParse(values['max-turns'] ?? '') ?? 24;
  int get timeoutSecs => int.tryParse(values['timeout-secs'] ?? '') ?? 900;
  String get model => values['model'] ?? 'sonnet';
  String get claudeBin => values['claude-bin'] ?? 'claude';
  String? get only => values['only'];
  String? get flutterBin => values['flutter-bin'];
  bool get includeInvalid => values.containsKey('include-invalid');

  double? get maxBudgetUsd {
    final raw = values['max-budget-usd'];
    if (raw == null) return null;
    final parsed = double.tryParse(raw);
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      _die('--max-budget-usd must be a finite positive number');
    }
    return parsed;
  }

  Set<String>? get onlySet => only?.split(',').map((s) => s.trim()).toSet();
}

_Options _parseArgs(List<String> args) {
  final values = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      stderr.writeln('unexpected positional: $arg');
      exit(64);
    }
    final name = arg.substring(2);
    if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
      values[name] = '';
    } else {
      values[name] = args[++i];
    }
  }
  return _Options(values);
}

/// tasks.json의 한 항목이다 — 레포 정의 또는 task 정의.
class _TaskSpec {
  _TaskSpec({
    required this.id,
    required this.repo,
    required this.prompt,
    required this.expected,
  });

  final String id;
  final String repo;
  final String prompt;

  /// 정답으로 요구하는 근거 문자열 — 최종 답에 전부 포함돼야 correct다.
  final List<String> expected;
}

class _RepoSpec {
  _RepoSpec({
    required this.name,
    required this.url,
    required this.revision,
    required this.packageRoot,
  });

  final String name;
  final String url;
  final String revision;

  /// 클론 루트에서 패키지 루트까지의 상대 경로다.
  final String packageRoot;
}

({List<_RepoSpec> repos, List<_TaskSpec> tasks}) _loadSpecs(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  final repos = <_RepoSpec>[
    for (final r in decoded['repos'] as List)
      _RepoSpec(
        name: r['name'] as String,
        url: r['url'] as String,
        revision: r['revision'] as String,
        packageRoot: r['packageRoot'] as String? ?? '.',
      ),
  ];
  final tasks = <_TaskSpec>[
    for (final t in decoded['tasks'] as List)
      _TaskSpec(
        id: t['id'] as String,
        repo: t['repo'] as String,
        prompt: t['prompt'] as String,
        expected: (t['expected'] as List).cast<String>(),
      ),
  ];
  return (repos: repos, tasks: tasks);
}

/// 레포 디렉터리 안의 패키지 루트 절대 경로다. WITH arm은 배선이 입혀진
/// `<name>-with` checkout을, WITHOUT arm은 손대지 않은 `<name>`을 쓴다 —
/// 같은 checkout을 공유하면 `.mcp.json`·skill이 without arm에 샌다.
String _packageRoot(String reposDir, _RepoSpec repo, String arm) {
  final dir = arm == 'with' ? '${repo.name}-with' : repo.name;
  final sub = repo.packageRoot == '.' ? '' : '/${repo.packageRoot}';
  return '${reposDir == '.' ? '' : '$reposDir/'}$dir$sub'.replaceAll(
    RegExp('/+'),
    '/',
  );
}

/// [reposDir] 아래 레포 클론·pub get·WITH arm용 MCP 배선을 만든다.
Future<void> _runPrepare(_Options options) async {
  final tasksPath = options.tasks ?? 'tool/agent_benchmark/tasks.json';
  final reposDir = options.repos ?? _die('--repos is required');
  final specs = _loadSpecs(tasksPath);
  final only = options.onlySet;
  final flutter = options.flutterBin ?? 'flutter';
  for (final repo in specs.repos) {
    if (only != null && !only.contains(repo.name)) continue;
    final dir = '$reposDir/${repo.name}';
    if (Directory(dir).existsSync()) {
      // 기존 checkout은 핀 리비전과 대조한다 — tasks.json의 핀이 바뀌었는데
      // 옛 checkout을 재사용하면 측정 조건이 조용히 어긋난다.
      final head = await _execOut('git', ['-C', dir, 'rev-parse', 'HEAD']);
      if (head != repo.revision) {
        _die(
          '${repo.name} checkout이 핀 리비전과 다르다: $head != '
          '${repo.revision} — $dir 를 지우거나 핀을 맞춘 뒤 다시 실행',
        );
      }
    } else {
      stdout.writeln('== clone ${repo.name} @ ${repo.revision}');
      await _exec('git', ['clone', '--depth', '1', repo.url, dir], quiet: true);
      await _exec('git', [
        '-C',
        dir,
        'fetch',
        'origin',
        repo.revision,
        '--depth',
        '1',
      ], quiet: true);
      await _exec('git', ['-C', dir, 'checkout', 'FETCH_HEAD'], quiet: true);
    }
    final root = _packageRoot(reposDir, repo, 'without');
    if (!File('$root/.dart_tool/package_config.json').existsSync()) {
      stdout.writeln('== pub get $root');
      await _exec(flutter, ['pub', 'get'], cwd: root, quiet: true);
    }
    // WITH arm checkout은 배선이 입혀진 복사본이다 — 클론을 통째로 베끼면
    // package_config의 상대 rootUri와 루트 문서(AGENTS.md 등)도 그대로 유효하다.
    final withDir = '$reposDir/${repo.name}-with';
    final withRoot = _packageRoot(reposDir, repo, 'with');
    if (!Directory(withDir).existsSync()) {
      stdout.writeln('== copy ${repo.name} -> ${repo.name}-with');
      await _exec('cp', ['-R', '$reposDir/${repo.name}', withDir], quiet: true);
    }
    if (!File('$withRoot/.mcp.json').existsSync()) {
      stdout.writeln('== dartograph setup --install $withRoot');
      await _exec(
        'dartograph',
        ['setup', '--install', withRoot],
        cwd: withRoot,
        quiet: true,
      );
    }
    // skill은 with arm의 프로젝트 스킬로만 심는다 — without arm에는 없다.
    if (!File('$withRoot/.claude/skills/dartograph/SKILL.md').existsSync()) {
      await _exec(
        'dartograph',
        ['skill', '--install', '$withRoot/.claude/skills'],
        cwd: withRoot,
        quiet: true,
      );
    }
  }
  stdout.writeln('prepare done');
}

/// 한 번의 에이전트 실행을 돌려 요약 레코드를 돌려준다.
Future<void> _runBenchmark(_Options options) async {
  final tasksPath = options.tasks ?? 'tool/agent_benchmark/tasks.json';
  final reposDir = options.repos ?? _die('--repos is required');
  final outDir = options.out ?? _die('--out is required');
  final maxBudgetUsd = options.maxBudgetUsd;
  final specs = _loadSpecs(tasksPath);
  final repoByName = {for (final r in specs.repos) r.name: r};
  final transcripts = Directory('$outDir/transcripts')
    ..createSync(recursive: true);
  final summaryFile = File('$outDir/summary.jsonl');
  final existingKeys = <String>{};
  if (summaryFile.existsSync()) {
    for (final line in summaryFile.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) {
        _die('${summaryFile.path} contains a non-object record');
      }
      final key = _recordKey(decoded);
      if (key != null) existingKeys.add(key);
    }
  }
  final summarySink = summaryFile.openWrite(mode: FileMode.append);
  final only = options.onlySet;
  const validArms = {'with', 'without', 'both'};
  if (!validArms.contains(options.arm)) {
    _die('unknown arm ${options.arm} — with|without|both');
  }
  final arms = options.arm == 'both'
      ? const ['without', 'with']
      : [options.arm];
  for (final task in specs.tasks) {
    if (only != null && !only.contains(task.id)) continue;
    final repo = repoByName[task.repo] ?? _die('unknown repo ${task.repo}');
    // 런 인덱스를 바깥에 두고 arm을 교번한다 — without 전부 → with 전부 순서면
    // 시간에 따라 변하는 API 조건이 arm과 상관한다.
    for (
      var i = options.runsOffset;
      i < options.runsOffset + options.runs;
      i++
    ) {
      for (final arm in arms) {
        final root = _packageRoot(reposDir, repo, arm);
        final name = '${task.id}-$arm-${_safeFilePart(options.model)}-$i';
        final key = _recordKey(<String, Object?>{
          'task': task.id,
          'arm': arm,
          'model': options.model,
          'run': i,
        });
        if (key != null && existingKeys.contains(key)) {
          stdout.writeln('== $name (already recorded; skipped)');
          continue;
        }
        final transcript = File('${transcripts.path}/$name.jsonl');
        if (transcript.existsSync()) {
          _die(
            '${transcript.path} already exists without a matching summary '
            'record; choose a new --runs-offset to preserve it',
          );
        }
        stdout.writeln('== $name');
        Map<String, Object?> record;
        try {
          record = await _runOnce(
            task: task,
            root: root,
            arm: arm,
            model: options.model,
            claudeBin: options.claudeBin,
            maxBudgetUsd: maxBudgetUsd,
            maxTurns: options.maxTurns,
            run: i,
            timeout: Duration(seconds: options.timeoutSecs),
            transcript: transcript,
          );
        } on Object catch (e) {
          // 한 런의 파싱·프로세스 예외가 매트릭스 전체를 죽이지 않게 한다 —
          // 실패는 레코드로 남겨 집계에서 보이게 한다.
          stderr.writeln('$name failed: $e');
          record = <String, Object?>{
            'task': task.id,
            'arm': arm,
            'model': options.model,
            'run': i,
            'runError': '$e',
            'correct': false,
            'contaminated': false,
            'dartographCalls': 0,
            'expectedTotal': task.expected.length,
            'at': DateTime.now().toIso8601String(),
          };
        }
        summarySink.writeln(jsonEncode(record));
        await summarySink.flush();
        if (key != null) existingKeys.add(key);
      }
    }
  }
  await summarySink.close();
  stdout.writeln('wrote ${summaryFile.path}');
}

/// `claude -p` 한 번을 실행하고 파싱된 요약을 돌려준다.
Future<Map<String, Object?>> _runOnce({
  required _TaskSpec task,
  required String root,
  required String arm,
  required String model,
  required String claudeBin,
  required double? maxBudgetUsd,
  required int maxTurns,
  required int run,
  required Duration timeout,
  required File transcript,
}) async {
  final isWith = arm == 'with';
  final prompt =
      'In this Dart/Flutter package, answer the question with evidence '
      '(file paths and symbol names). Do not modify files.\n\n${task.prompt}';
  final args = <String>[
    '-p',
    prompt,
    '--output-format',
    'stream-json',
    '--verbose',
    '--model',
    model,
    '--max-turns',
    '$maxTurns',
    '--permission-mode',
    'bypassPermissions',
    '--disallowedTools',
    'Edit',
    'Write',
    'NotebookEdit',
    '--setting-sources',
    'project',
    '--strict-mcp-config',
    '--no-session-persistence',
  ];
  if (maxBudgetUsd != null) {
    args.addAll(['--max-budget-usd', '$maxBudgetUsd']);
  }
  if (isWith) {
    args.addAll(['--mcp-config', '$root/.mcp.json']);
  }
  // without arm: PATH에서 pub cache를 빼 dartograph를 부르지 못하게 하고,
  // strict-mcp-config가 빈 MCP 목록을 강제한다. PATH 필터는 best-effort다 —
  // 실제 불변식은 아래 dartograph 호출 검출(contaminated)이다.
  final env = Map<String, String>.from(Platform.environment);
  if (!isWith) {
    final filtered = (env['PATH'] ?? '')
        .split(':')
        .where((p) => p.isNotEmpty && !p.contains('.pub-cache'))
        .join(':');
    // PATH가 원래 비어 있었으면 빈 값으로 덮어쓰지 않는다 — 자식이 아무
    // 명령도 못 찾는 꼬인 실패가 된다.
    if (filtered.isNotEmpty) env['PATH'] = filtered;
  }
  final process = await Process.start(
    claudeBin,
    args,
    workingDirectory: root,
    environment: env,
  );
  // stderr는 즉시 드레인한다 — stdout 루프가 끝난 뒤에야 읽으면 자식이
  // 파이프 버퍼 한계를 넘는 stderr 출력에서 블록돼 stdout이 EOF되지 않는다.
  final stderrDrain = process.stderr.drain<void>();
  final sink = transcript.openWrite();
  final toolCalls = <String, int>{};
  var dartographCalls = 0;
  var fileReads = 0;
  var bashCalls = 0;
  var resultText = '';
  var isError = false;
  var numTurns = 0;
  var durationMs = 0;
  var costUsd = 0.0;
  var inputTokens = 0;
  var outputTokens = 0;
  String? resolvedModel;
  // 이벤트 사이 유휴가 timeout을 넘으면 자식을 kill하고 스트림에 에러를 싣는다 —
  // 매달린 claude 한 대가 매트릭스 전체를 세우지 않게 한다. sink.close()는
  // 부르지 않는다 — 닫힌 컨트롤러에 늦게 도착한 소스 이벤트가 add를 던져
  // 처리 불가 async 에러로 프로세스를 죽인다. kill 후 스트림은 자연 종료한다.
  final lineStream = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .timeout(
        timeout,
        onTimeout: (sink) {
          process.kill();
          sink.addError(TimeoutException('run exceeded $timeout'));
        },
      );
  try {
    await for (final line in lineStream) {
      sink.writeln(line);
      Object? event;
      try {
        event = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (event is! Map<String, Object?>) continue;
      switch (event['type']) {
        case 'system':
          final eventModel = event['model'];
          if (eventModel is String && eventModel.isNotEmpty) {
            resolvedModel = eventModel;
          }
          break;
        case 'assistant':
          final message = event['message'];
          if (message is! Map) break;
          for (final content in message['content'] as List? ?? const []) {
            if (content is! Map || content['type'] != 'tool_use') continue;
            final name = content['name'] as String? ?? '?';
            toolCalls[name] = (toolCalls[name] ?? 0) + 1;
            if (name == 'Read') fileReads++;
            if (name == 'Bash') {
              bashCalls++;
              final input = content['input'];
              final command = input is Map
                  ? input['command'] as String? ?? ''
                  : '';
              if (RegExp(r'\bdartograph\b').hasMatch(command)) {
                dartographCalls++;
              }
            }
            if (name.startsWith('mcp__dartograph')) dartographCalls++;
          }
        case 'result':
          resultText = event['result'] as String? ?? '';
          isError = event['is_error'] as bool? ?? false;
          numTurns = event['num_turns'] as int? ?? 0;
          durationMs = event['duration_ms'] as int? ?? 0;
          costUsd = (event['total_cost_usd'] as num?)?.toDouble() ?? 0;
          final usage = event['usage'];
          if (usage is Map) {
            inputTokens = (usage['input_tokens'] as num?)?.toInt() ?? 0;
            outputTokens = (usage['output_tokens'] as num?)?.toInt() ?? 0;
          }
      }
    }
  } finally {
    await sink.close();
  }
  await stderrDrain;
  final exitCode = await process.exitCode;
  final hits = [
    for (final expected in task.expected)
      if (resultText.contains(expected)) expected,
  ];
  // without arm에서 dartograph 호출이 잡히면 오염 실패 — 집계에서 제외 표시다.
  final contaminated = !isWith && dartographCalls > 0;
  return <String, Object?>{
    'task': task.id,
    'arm': arm,
    'model': model,
    'resolvedModel': resolvedModel,
    'run': run,
    'exitCode': exitCode,
    'isError': isError,
    'numTurns': numTurns,
    'durationMs': durationMs,
    'costUsd': costUsd,
    'maxBudgetUsd': maxBudgetUsd,
    'budgetExceeded': maxBudgetUsd != null && costUsd > maxBudgetUsd,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'toolCalls': toolCalls,
    'fileReads': fileReads,
    'bashCalls': bashCalls,
    'dartographCalls': dartographCalls,
    'contaminated': contaminated,
    'usedDartograph': dartographCalls > 0,
    'expectedHits': hits.length,
    'expectedTotal': task.expected.length,
    'correct': hits.length == task.expected.length && !isError && exitCode == 0,
    'result': resultText,
    'at': DateTime.now().toIso8601String(),
  };
}

String? _recordKey(Map<String, Object?> record) {
  final task = record['task'];
  final arm = record['arm'];
  final model = record['model'];
  final run = record['run'];
  if (task is! String || arm is! String || model is! String || run is! num) {
    return null;
  }
  return '$task\t$arm\t$model\t${run.toInt()}';
}

String _safeFilePart(String value) {
  // URI 인코딩으로 a/b와 a_b 같은 모델 별칭을 구분하면서 파일명 호환성을 지킨다.
  final safe = Uri.encodeComponent(value);
  return safe.isEmpty ? 'model' : safe;
}

/// summary.jsonl을 task × arm × model 중앙값으로 집계해 마크다운 표를 낸다.
void _runScore(_Options options) {
  final outDir = options.out ?? _die('--out is required');
  final file = File('$outDir/summary.jsonl');
  if (!file.existsSync()) _die('${file.path} missing');
  final records = <Map<String, Object?>>[
    for (final line in file.readAsLinesSync())
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
  ];
  // 모델이 다른 기록을 한 표에서 섞으면 비교가 무효다 — 그룹 키에 넣는다.
  final groups = <String, List<Map<String, Object?>>>{};
  for (final record in records) {
    if (record['contaminated'] == true && !options.includeInvalid) continue;
    groups
        .putIfAbsent(
          '${record['task']}\t${record['arm']}\t${record['model'] ?? '?'}',
          () => [],
        )
        .add(record);
  }
  // 같은 (task, arm, model, run) 레코드가 두 번이면 append 모드의 재실행
  // 중복이다 — 중앙값이 조용히 밀리니 경고한다. run 필드가 없는 옛 레코드는
  // 구분할 수 없으니 건너뛴다.
  final seen = <String>{};
  var duplicates = 0;
  for (final record in records) {
    if (record['run'] == null) continue;
    if (!seen.add(
      '${record['task']}\t${record['arm']}\t${record['model']}\t${record['run']}',
    )) {
      duplicates++;
    }
  }
  num median(List<num> xs) {
    if (xs.isEmpty) return 0;
    final sorted = List<num>.from(xs)..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  stdout.writeln(
    '| task | arm | model | n | correct | err | turns | sec | cost | '
    'reads | dgraph |',
  );
  stdout.writeln('|---|---|---|---|---|---|---|---|---|---|---|');
  final keys = groups.keys.toList()..sort();
  for (final key in keys) {
    final rows = groups[key]!;
    final task = key.split('\t');
    final n = rows.length;
    final correct = rows.where((r) => r['correct'] == true).length;
    // isError·runError·비정상 exitCode 런을 따로 세어, 오답이 하네스
    // 실패인지 에이전트 실패인지 구분한다.
    final errors = rows
        .where(
          (r) =>
              r['isError'] == true ||
              r['runError'] != null ||
              (r['exitCode'] as num? ?? 0) != 0,
        )
        .length;
    final turns = median([for (final r in rows) r['numTurns'] as num? ?? 0]);
    final secs = median([
      for (final r in rows) (r['durationMs'] as num? ?? 0) / 1000,
    ]);
    final cost = median([for (final r in rows) r['costUsd'] as num? ?? 0]);
    final reads = median([for (final r in rows) r['fileReads'] as num? ?? 0]);
    final dgraph = median([
      for (final r in rows) r['dartographCalls'] as num? ?? 0,
    ]);
    stdout.writeln(
      '| ${task[0]} | ${task[1]} | ${task[2]} | $n | $correct/$n | $errors | '
      '$turns | ${secs.toStringAsFixed(1)} | '
      '\$${cost.toStringAsFixed(3)} | $reads | $dgraph |',
    );
  }
  final contaminated = records.where((r) => r['contaminated'] == true).length;
  if (contaminated > 0) {
    stdout.writeln('\ncontaminated without-arm runs excluded: $contaminated');
  }
  if (duplicates > 0) {
    stdout.writeln(
      '\nduplicate (task, arm, model, run) records: $duplicates — '
      'append 모드 재실행 중복, medians shifted',
    );
  }
}

Future<int> _exec(
  String command,
  List<String> args, {
  String? cwd,
  bool quiet = false,
}) async {
  final process = await Process.start(command, args, workingDirectory: cwd);
  if (!quiet) {
    process.stdout.transform(utf8.decoder).listen(stdout.write);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
  } else {
    process.stdout.drain<void>();
    process.stderr.drain<void>();
  }
  final code = await process.exitCode;
  if (code != 0) {
    stderr.writeln('$command ${args.join(' ')} failed: $code');
    exit(code);
  }
  return code;
}

/// 명령의 stdout을 다듬어 돌려준다 — 핀 리비전 대조처럼 출력이 필요한 검사용.
Future<String> _execOut(String command, List<String> args) async {
  final process = await Process.start(command, args);
  final out = await process.stdout.transform(utf8.decoder).join();
  await process.stderr.drain<void>();
  final code = await process.exitCode;
  if (code != 0) {
    _die('$command ${args.join(' ')} failed: $code');
  }
  return out.trim();
}

Never _die(String message) {
  stderr.writeln(message);
  exit(64);
}
