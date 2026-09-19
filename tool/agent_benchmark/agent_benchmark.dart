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
    stdout.writeln(_usage);
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
      [--only <task,task>] [--runs-offset <n>]

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
  String get model => values['model'] ?? 'sonnet';
  String? get only => values['only'];
  String? get flutterBin => values['flutter-bin'];
  bool get includeInvalid => values.containsKey('include-invalid');

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
    if (!Directory(dir).existsSync()) {
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
  final specs = _loadSpecs(tasksPath);
  final repoByName = {for (final r in specs.repos) r.name: r};
  final transcripts = Directory('$outDir/transcripts')
    ..createSync(recursive: true);
  final summaryFile = File('$outDir/summary.jsonl');
  final summarySink = summaryFile.openWrite(mode: FileMode.append);
  final only = options.onlySet;
  final arms = options.arm == 'both'
      ? const ['without', 'with']
      : [options.arm];
  for (final task in specs.tasks) {
    if (only != null && !only.contains(task.id)) continue;
    final repo = repoByName[task.repo] ?? _die('unknown repo ${task.repo}');
    for (final arm in arms) {
      final root = _packageRoot(reposDir, repo, arm);
      for (
        var i = options.runsOffset;
        i < options.runsOffset + options.runs;
        i++
      ) {
        final name = '${task.id}-$arm-$i';
        stdout.writeln('== $name');
        final record = await _runOnce(
          task: task,
          root: root,
          arm: arm,
          model: options.model,
          maxTurns: options.maxTurns,
          transcript: File('${transcripts.path}/$name.jsonl'),
        );
        summarySink.writeln(jsonEncode(record));
        await summarySink.flush();
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
  required int maxTurns,
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
  if (isWith) {
    args.addAll(['--mcp-config', '$root/.mcp.json']);
  }
  // without arm: PATH에서 pub cache를 빼 dartograph를 부르지 못하게 하고,
  // strict-mcp-config가 빈 MCP 목록을 강제한다.
  final env = Map<String, String>.from(Platform.environment);
  if (!isWith) {
    env['PATH'] = (env['PATH'] ?? '')
        .split(':')
        .where((p) => !p.contains('.pub-cache'))
        .join(':');
  }
  final process = await Process.start(
    'claude',
    args,
    workingDirectory: root,
    environment: env,
  );
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
  await for (final line
      in process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    sink.writeln(line);
    Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (event is! Map<String, Object?>) continue;
    switch (event['type']) {
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
  await sink.close();
  await process.stderr.drain<void>();
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
    'exitCode': exitCode,
    'isError': isError,
    'numTurns': numTurns,
    'durationMs': durationMs,
    'costUsd': costUsd,
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
    'correct': hits.length == task.expected.length && !isError,
    'result': resultText,
    'at': DateTime.now().toIso8601String(),
  };
}

/// summary.jsonl을 task × arm 중앙값으로 집계해 마크다운 표를 낸다.
void _runScore(_Options options) {
  final outDir = options.out ?? _die('--out is required');
  final file = File('$outDir/summary.jsonl');
  if (!file.existsSync()) _die('${file.path} missing');
  final records = <Map<String, Object?>>[
    for (final line in file.readAsLinesSync())
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
  ];
  final groups = <String, List<Map<String, Object?>>>{};
  for (final record in records) {
    if (record['contaminated'] == true && !options.includeInvalid) continue;
    groups
        .putIfAbsent('${record['task']}\t${record['arm']}', () => [])
        .add(record);
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
    '| task | arm | n | correct | turns | sec | cost | reads | dgraph |',
  );
  stdout.writeln('|---|---|---|---|---|---|---|---|---|');
  final keys = groups.keys.toList()..sort();
  for (final key in keys) {
    final rows = groups[key]!;
    final task = key.split('\t');
    final n = rows.length;
    final correct = rows.where((r) => r['correct'] == true).length;
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
      '| ${task[0]} | ${task[1]} | $n | $correct/$n | $turns | '
      '${secs.toStringAsFixed(1)} | \$${cost.toStringAsFixed(3)} | '
      '$reads | $dgraph |',
    );
  }
  final contaminated = records.where((r) => r['contaminated'] == true).length;
  if (contaminated > 0) {
    stdout.writeln('\ncontaminated without-arm runs excluded: $contaminated');
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

Never _die(String message) {
  stderr.writeln(message);
  exit(64);
}
