import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/fact_cache.dart';
import '../core/tool_info.dart';
import '../index/analyzer_graph_index.dart';
import '../index/incremental_cache.dart';
import 'agent_skill.dart';
import 'configuration_template.dart';
import 'dartograph_cli.dart';

/// dartograph가 구현하는 MCP 프로토콜 버전이다(stdio transport).
const mcpProtocolVersion = '2024-11-05';

/// JSON-RPC 2.0 에러 코드다.
const _parseError = -32700;
const _invalidRequest = -32600;
const _methodNotFound = -32601;
const _invalidParams = -32602;
const _internalError = -32603;

/// MCP 리소스 관례상 "알 수 없는 URI"에 쓰는 코드다.
const _resourceNotFound = -32002;

/// `impact_query` 도구 이름이다.
const impactToolName = 'impact_query';

/// `dependency_query` 도구 이름이다.
const dependencyToolName = 'dependency_query';

/// `verify_run` 도구 이름이다.
const verifyToolName = 'verify_run';

const _runtimeToolName = 'runtime_query';

/// `dartograph_explore` 통합 도구 이름이다.
const exploreToolName = 'dartograph_explore';

/// 기존 네 도구의 `tools/list` 노출을 제어하는 환경 변수다.
///
/// 값이 `0` 또는 `false`(대소문자 무관)이면 `dartograph_explore`만 광고한다 —
/// 나머지 도구는 목록에서 빠지지만 `tools/call`은 계속 받는다.
const legacyToolsEnvName = 'DARTOGRAPH_MCP_LEGACY_TOOLS';

/// stdio 프레이밍의 JSON-RPC 메시지 한 줄 상한(바이트)이다. 개행 없는 입력이
/// 라인 버퍼를 무제한으로 키우지 못하게 한다 — 다른 입력 경로(설정·배치
/// 파일)의 1MiB 상한과 맞춘다.
const mcpMaxMessageBytes = 1 << 20;

/// stdin 바이트를 [maxBytes] 상한의 UTF-8 라인 스트림으로 변환한다.
///
/// `LineSplitter`는 개행 전까지 무제한 버퍼링하므로 직접 쓸 수 없다. 상한을
/// 넘는 라인은 [maxBytes]에서 잘라 돌려준다 — 잘린 JSON은 반드시 파싱에
/// 실패하므로 서버가 `Invalid JSON`으로 답하고 연결은 유지된다. 나머지 바이트는
/// 다음 개행까지 버린다.
StreamTransformer<List<int>, String> boundedUtf8Lines(int maxBytes) {
  final buffer = BytesBuilder();
  // 상한을 넘긴 라인의 잔여 바이트를 버리는 중인지다.
  var skipping = false;

  void emitLine(EventSink<String> sink) {
    if (buffer.isNotEmpty) {
      sink.add(utf8.decode(buffer.takeBytes(), allowMalformed: true));
    }
    skipping = false;
  }

  return StreamTransformer.fromHandlers(
    handleData: (chunk, sink) {
      var offset = 0;
      while (offset < chunk.length) {
        final newline = chunk.indexOf(0x0A, offset);
        final end = newline == -1 ? chunk.length : newline;
        if (!skipping && end > offset) {
          final piece = chunk.sublist(offset, end);
          final room = maxBytes - buffer.length;
          buffer.add(piece.length <= room ? piece : piece.sublist(0, room));
          if (piece.length > room) skipping = true;
        }
        if (newline == -1) break;
        emitLine(sink);
        offset = newline + 1;
      }
    },
    handleDone: (sink) {
      emitLine(sink);
      sink.close();
    },
  );
}

/// dartograph의 분석·질의 능력을 MCP 도구로 노출하는 stdio 서버를 실행한다.
///
/// stdout에는 JSON-RPC 응답만 쓰고, 진단은 stderr로 보낸다. 각 도구 호출은
/// 기존 CLI와 **같은** 실행 경로(`runDartograph`)를 재사용하므로 출력 스키마와
/// 종료 코드가 CLI와 어긋나지 않는다. 도구는 읽기 전용이며 저장소를 수정하지
/// 않는다. 요청이 유효한 JSON-RPC 메시지가 아니면 그 요청만 오류로 답한다.
Future<int> runMcpServer({
  required Stream<String> input,
  required StringSink output,
  required StringSink error,
  IndexPackage? indexPackage,
  ChangedFilesSince? changedFilesSince,
  Future<Directory> Function()? createScratch,
  Future<Directory> Function()? createCacheDirectory,
  String? allowedRootBase,
  Map<String, String>? environment,
}) async {
  final scratchFactory =
      createScratch ?? () => Directory.systemTemp.createTemp('dartograph-mcp.');
  // 도구 인자 packageRoot는 이 경계 안으로 해석돼야 한다 — 클라이언트가 서버
  // 작업 디렉터리 밖의 임의 디렉터리를 스캔하게 하지 않는다.
  final rootBoundary = Directory(
    allowedRootBase ?? Directory.current.path,
  ).absolute.resolveSymbolicLinksSync();
  final session = _McpIndexSession(
    createCacheDirectory ??
        () => Directory.systemTemp.createTemp('dartograph-mcp-cache.'),
    error,
  );
  try {
    return await _serveMcpRequests(
      input: input,
      output: output,
      error: error,
      indexPackage: indexPackage ?? session.index,
      changedFilesSince: changedFilesSince,
      scratchFactory: scratchFactory,
      rootBoundary: rootBoundary,
      environment: environment ?? Platform.environment,
    );
  } finally {
    await session.close();
  }
}

Future<int> _serveMcpRequests({
  required Stream<String> input,
  required StringSink output,
  required StringSink error,
  required IndexPackage indexPackage,
  required ChangedFilesSince? changedFilesSince,
  required Future<Directory> Function() scratchFactory,
  required String rootBoundary,
  required Map<String, String> environment,
}) async {
  await for (final line in input) {
    if (line.trim().isEmpty) continue;
    Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      _writeError(output, null, _parseError, 'Invalid JSON');
      continue;
    }
    if (message is! Map<String, Object?>) {
      _writeError(output, null, _invalidRequest, 'Invalid request');
      continue;
    }
    final id = message['id'];
    final method = message['method'];
    if (method is! String) {
      // 응답 형태(result·error) 메시지와 id 없는 알림에는 답하지 않는다.
      if (message.containsKey('id') &&
          !message.containsKey('result') &&
          !message.containsKey('error')) {
        _writeError(output, id, _invalidRequest, 'Missing method');
      }
      continue;
    }
    if (method.startsWith('notifications/')) continue;
    // id가 없는 요청 형태 메시지는 JSON-RPC notification이다 — notifications/
    // 접두사만이 아니라 어떤 메서드든 id가 없으면 답을 보내지 않는다.
    if (!message.containsKey('id')) continue;
    switch (method) {
      case 'initialize':
        _writeResult(output, id, {
          'capabilities': {
            'tools': <String, Object?>{},
            'resources': <String, Object?>{},
            'prompts': <String, Object?>{},
          },
          'protocolVersion': mcpProtocolVersion,
          'serverInfo': {'name': 'dartograph', 'version': toolVersion},
        });
      case 'ping':
        _writeResult(output, id, <String, Object?>{});
      case 'tools/list':
        _writeResult(output, id, {'tools': _listedTools(environment)});
      case 'resources/list':
        _writeResult(output, id, {'resources': _resourceDefinitions});
      case 'resources/read':
        final params = message['params'];
        if (params is! Map<String, Object?>) {
          _writeError(output, id, _invalidParams, 'params must be an object');
          continue;
        }
        final uri = params['uri'];
        if (uri is! String) {
          _writeError(
            output,
            id,
            _invalidParams,
            'params.uri must be a string',
          );
          continue;
        }
        final resource = _readResource(uri);
        if (resource == null) {
          _writeError(output, id, _resourceNotFound, 'Unknown resource: $uri');
          continue;
        }
        _writeResult(output, id, {
          'contents': [resource],
        });
      case 'prompts/list':
        _writeResult(output, id, {'prompts': _promptDefinitions});
      case 'prompts/get':
        final params = message['params'];
        if (params is! Map<String, Object?>) {
          _writeError(output, id, _invalidParams, 'params must be an object');
          continue;
        }
        final name = params['name'];
        if (name is! String) {
          _writeError(
            output,
            id,
            _invalidParams,
            'params.name must be a string',
          );
          continue;
        }
        if (!_promptDefinitions.any((prompt) => prompt['name'] == name)) {
          _writeError(output, id, _invalidParams, 'Unknown prompt: $name');
          continue;
        }
        final prompt = _getPrompt(
          name,
          params['arguments'] is Map<String, Object?>
              ? params['arguments']! as Map<String, Object?>
              : const <String, Object?>{},
        );
        if (prompt == null) {
          _writeError(
            output,
            id,
            _invalidParams,
            'prompt arguments require a non-empty packageRoot; minTokens '
            'must be an integer >= 2 when given',
          );
          continue;
        }
        _writeResult(output, id, prompt);
      case 'tools/call':
        final params = message['params'];
        if (params is! Map<String, Object?>) {
          _writeError(output, id, _invalidParams, 'params must be an object');
          continue;
        }
        final name = params['name'];
        if (name is! String) {
          _writeError(
            output,
            id,
            _invalidParams,
            'params.name must be a string',
          );
          continue;
        }
        final arguments = params['arguments'];
        Map<String, Object?>? result;
        try {
          result = await _callTool(
            name: name,
            arguments: arguments is Map<String, Object?>
                ? arguments
                : const <String, Object?>{},
            indexPackage: indexPackage,
            changedFilesSince: changedFilesSince,
            createScratch: scratchFactory,
            rootBoundary: rootBoundary,
          );
        } on Object catch (exception) {
          // 도구 실행 중 예상 못 한 예외는 프로토콜 오류로 답하고 진단은
          // stderr로 보낸다(stdout에는 JSON-RPC만).
          error.writeln('dartograph mcp: tool $name failed: $exception');
          _writeError(output, id, _internalError, 'Tool execution failed');
          continue;
        }
        if (result == null) {
          _writeError(output, id, _invalidParams, 'Unknown tool: $name');
          continue;
        }
        _writeResult(output, id, result);
      default:
        _writeError(output, id, _methodNotFound, 'Unknown method: $method');
    }
  }
  return ExitStatus.success.code;
}

final class _McpIndexSession {
  _McpIndexSession(this.createDirectory, this.error);

  final Future<Directory> Function() createDirectory;
  final StringSink error;
  final directories = <String, String>{};
  Directory? directory;
  bool isDisabled = false;

  Future<AnalyzerGraphResult> index(String root) async {
    if (isDisabled) return _fullIndex(root);
    try {
      directory ??= await createDirectory();
    } on Object {
      return _fallback(root);
    }
    final cachePath = directories.putIfAbsent(
      root,
      () => p.join(directory!.path, 'package-${directories.length}'),
    );
    final result = await AnalyzerGraphIndex(
      incremental: IncrementalCache(cachePath),
    ).index(root);
    if (result.limitationDetails.any(
      (detail) => detail.startsWith(incrementalCacheWriteFailurePrefix),
    )) {
      return _fallback(root);
    }
    return result;
  }

  Future<AnalyzerGraphResult> _fallback(String root) {
    isDisabled = true;
    error.writeln(
      'dartograph mcp: temporary cache unavailable; using full analysis for '
      'this session. Check OS temporary storage permissions and free space.',
    );
    return _fullIndex(root);
  }

  Future<AnalyzerGraphResult> _fullIndex(String root) =>
      AnalyzerGraphIndex(cache: const _McpUncachedFacts()).index(root);

  Future<void> close() async {
    final owned = directory;
    if (owned == null) return;
    try {
      await owned.delete(recursive: true);
    } on FileSystemException {
      error.writeln(
        'dartograph mcp: temporary cache cleanup failed; check OS temporary '
        'storage permissions and clean up abandoned dartograph-mcp-cache directories.',
      );
    }
  }
}

final class _McpUncachedFacts implements FactCache {
  const _McpUncachedFacts();

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String payload) async {}
}

/// 도구 정의(이름·설명·입력 스키마)를 결정적 순서로 돌려준다.
List<Map<String, Object?>> get _toolDefinitions => [
  {
    'name': exploreToolName,
    'description':
        'Single entry point for dependency and reachability questions about '
        'a Dart/Flutter package. Give packageRoot plus exactly one question '
        'shape: symbol or batch (declarations, members, callers/dependents, '
        'retention evidence, and the source lines in one response — no '
        'separate file read needed); impactSymbol, since, or changed (what '
        'a change or declaration affects: impacted symbols, call sites, '
        'related tests, risk score); or command (dead, deps, dup, cycles, '
        'rules, metrics, or runtime — run a verification or static-facts '
        'lookup). The first response line names the routed path. Findings '
        'are graph evidence with stated limitations, not deletion proof. '
        'Read-only.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'packageRoot': {
          'type': 'string',
          'description': 'Package root directory to analyze.',
        },
        'symbol': {
          'type': 'string',
          'description':
              'One symbol id or name — answers a dependency/evidence '
              'question with source lines included.',
        },
        'batch': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Several symbol ids or names (1-1000) — same question shape '
              'as symbol, batched.',
        },
        'impactSymbol': {
          'type': 'string',
          'description':
              'One symbol id — answers what depends on that declaration '
              '(pre-change blast radius).',
        },
        'since': {
          'type': 'string',
          'description':
              'Git revision — with no command: the impact question measured '
              'from this point; with command dead: dead --since.',
        },
        'changed': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Project-relative changed paths (1-1000) — the impact '
              'question for a pending edit set.',
        },
        'command': {
          'type': 'string',
          'enum': [
            'dead',
            'deps',
            'dup',
            'cycles',
            'rules',
            'metrics',
            'runtime',
          ],
          'description':
              'Run a verification (dead, deps, dup, cycles, rules, '
              'metrics) or a static runtime-facts lookup (runtime).',
        },
        'strict': {
          'type': 'boolean',
          'description': 'For command cycles, rules, or metrics.',
        },
        'closedApp': {
          'type': 'boolean',
          'description':
              'For command dead only: do not retain the public API '
              '(standalone application mode).',
        },
        'minTokens': {
          'type': 'integer',
          'description': 'For command dup only: minimum token window (≥ 2).',
        },
        'kinds': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'For command dead, deps, or dup only: report only these '
              'finding kinds.',
        },
        'baseline': {
          'type': 'string',
          'description':
              'Baseline file written by `dartograph baseline` — valid for '
              'command and symbol/batch questions.',
        },
        'config': {
          'type': 'string',
          'description': 'For command rules only: layers.yaml path.',
        },
        'format': {
          'type': 'string',
          'enum': ['text', 'json', 'markdown', 'github-actions', 'sarif'],
          'description': 'For command questions only.',
        },
        'depth': {'type': 'integer', 'minimum': 1},
        'limit': {'type': 'integer', 'minimum': 1},
        'withSource': {
          'type': 'boolean',
          'description':
              'For symbol/batch questions: include source lines at each '
              'declaration location (project files only). Default true.',
        },
        'sourceContext': {
          'type': 'integer',
          'minimum': 0,
          'description':
              'For symbol/batch questions with source: lines before and '
              'after each declaration line. Default 3.',
        },
      },
      'required': ['packageRoot'],
      'additionalProperties': false,
    },
  },
  {
    'name': impactToolName,
    'description':
        'Pre-check what a code change affects before making it. Give a git '
        'revision (since), project-relative changed paths (changed), or one '
        'symbol id (symbol). Returns changed libraries/symbols, transitively '
        'impacted symbols with shortest usage paths and depths, call sites '
        'into changed declarations, related test libraries, a risk score with '
        'factors, and the coverage of what inspecting changed files alone '
        'would miss. Read-only.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'packageRoot': {
          'type': 'string',
          'description': 'Package root directory to analyze.',
        },
        'since': {
          'type': 'string',
          'description': 'Git revision (commit, branch, tag, HEAD~1).',
        },
        'changed': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Project-relative changed file paths (1-1000).',
        },
        'symbol': {
          'type': 'string',
          'description': 'One graph symbol id whose dependents to report.',
        },
        'depth': {'type': 'integer', 'minimum': 1},
        'limit': {'type': 'integer', 'minimum': 1},
      },
      'required': ['packageRoot'],
      'additionalProperties': false,
    },
  },
  {
    'name': dependencyToolName,
    'description':
        'Answer dependency and reachability questions for one or more '
        'Dart/Flutter symbols: both-direction neighbors, members, retention '
        'roots and paths, baseline state, and notFound/ambiguous state. Use '
        'batch to answer several symbols from one graph. Read-only.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'packageRoot': {
          'type': 'string',
          'description': 'Package root directory to analyze.',
        },
        'symbol': {'type': 'string', 'description': 'One symbol id or name.'},
        'batch': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Several symbol ids or names (1-1000).',
        },
        'depth': {'type': 'integer', 'minimum': 1},
        'limit': {'type': 'integer', 'minimum': 1},
        'baseline': {
          'type': 'string',
          'description': 'Baseline file written by `dartograph baseline`.',
        },
        'withSource': {
          'type': 'boolean',
          'description':
              'Include the source lines at each reported declaration '
              'location (project files only).',
        },
        'sourceContext': {
          'type': 'integer',
          'minimum': 0,
          'description':
              'With withSource: lines before and after each declaration line. '
              'Omit for 0.',
        },
      },
      'required': ['packageRoot'],
      'additionalProperties': false,
    },
  },
  {
    'name': verifyToolName,
    'description':
        'Run a dartograph verification and return its exit code with the raw '
        'output: dead (unreachable declarations), deps (pubspec hygiene '
        'audit), cycles, rules (layer violations), or metrics. Use format '
        'json for a machine-readable document. Read-only.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'packageRoot': {
          'type': 'string',
          'description': 'Package root directory to analyze.',
        },
        'command': {
          'type': 'string',
          'enum': ['dead', 'deps', 'dup', 'cycles', 'rules', 'metrics'],
        },
        'strict': {'type': 'boolean'},
        'minTokens': {
          'type': 'integer',
          'description': 'For dup only: minimum duplicated token window.',
        },
        'kinds': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'For dead, deps, or dup: report only these finding kinds.',
        },
        'closedApp': {
          'type': 'boolean',
          'description':
              'For dead only: do not retain the public API (standalone '
              'application mode).',
        },
        'since': {
          'type': 'string',
          'description': 'Git revision for dead --since.',
        },
        'baseline': {'type': 'string'},
        'config': {
          'type': 'string',
          'description': 'layers.yaml path for rules.',
        },
        'format': {
          'type': 'string',
          'enum': ['text', 'json', 'markdown', 'github-actions', 'sarif'],
        },
      },
      'required': ['packageRoot', 'command'],
      'additionalProperties': false,
    },
  },
  {
    'name': _runtimeToolName,
    'description':
        'Look up static runtime dependency facts (environment variables, '
        'dart-define, dynamic loading, config files, assets, external '
        'services). Returns runtime --no-verify --format json output. '
        'No host environment or file presence verification, and no code '
        'execution. Read-only.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'packageRoot': {
          'type': 'string',
          'description': 'Package root directory to analyze.',
        },
        'limit': {'type': 'integer', 'minimum': 1},
      },
      'required': ['packageRoot'],
      'additionalProperties': false,
    },
  },
];

/// `tools/list`가 광고하는 도구 정의다.
///
/// [legacyToolsEnvName]가 `0`·`false`이면 `dartograph_explore`만 노출한다 —
/// 나머지 도구는 목록에서 빠지지만 `tools/call`은 계속 받는다. 기존 클라이언트
/// 설정과 프롬프트 안내(레거시 이름 지목)가 목록 축소로 깨지지 않게 하는
/// 절충이다.
List<Map<String, Object?>> _listedTools(Map<String, String> environment) {
  final value = environment[legacyToolsEnvName];
  if (value != null && {'0', 'false'}.contains(value.toLowerCase())) {
    return _toolDefinitions
        .where((tool) => tool['name'] == exploreToolName)
        .toList();
  }
  return _toolDefinitions;
}

/// 서버가 노출하는 정적 리소스다. 프로젝트별 동적 상태는 도구가 답한다 —
/// 리소스는 호출 사이에 바뀌지 않는 문서만 노출한다.
List<Map<String, Object?>> get _resourceDefinitions => [
  {
    'uri': 'dartograph://usage',
    'name': 'usage',
    'description':
        'The full dartograph CLI contract: every command, flag, exit code, '
        'and output-format rule.',
    'mimeType': 'text/plain',
  },
  {
    'uri': 'dartograph://skill',
    'name': 'agent-skill',
    'description':
        'The agent skill document (dartograph skill output): query patterns, '
        'symbol id shapes, and interpretation rules for AI callers.',
    'mimeType': 'text/markdown',
  },
  {
    'uri': 'dartograph://config',
    'name': 'config-template',
    'description':
        'The commented dartograph.yaml template (dartograph init output): '
        'entry_points and source_packages with their validation rules.',
    'mimeType': 'text/yaml',
  },
];

/// 정적 리소스 URI를 본문으로 해석한다. 모르는 URI는 null이다.
Map<String, Object?>? _readResource(String uri) => switch (uri) {
  'dartograph://usage' => {
    'uri': uri,
    'mimeType': 'text/plain',
    'text': cliUsageText,
  },
  'dartograph://skill' => {
    'uri': uri,
    'mimeType': 'text/markdown',
    'text': agentSkillMarkdown,
  },
  'dartograph://config' => {
    'uri': uri,
    'mimeType': 'text/yaml',
    'text': configurationTemplate,
  },
  _ => null,
};

/// 에이전트가 자주 쓰는 작업 흐름의 프롬프트 정의다.
List<Map<String, Object?>> get _promptDefinitions => [
  {
    'name': 'impact-precheck',
    'description':
        'Pre-check what an edit affects before making it: impacted symbols '
        'with usage paths, call sites, related tests, and a risk score.',
    'arguments': [
      {
        'name': 'packageRoot',
        'description': 'Package root directory to analyze.',
        'required': true,
      },
      {
        'name': 'since',
        'description':
            'Git revision the change is measured from (e.g. HEAD, main).',
        'required': false,
      },
    ],
  },
  {
    'name': 'dead-code-review',
    'description':
        'Review unreachable declarations as candidates for removal. Use '
        'closedApp only for standalone applications, never published '
        'libraries.',
    'arguments': [
      {
        'name': 'packageRoot',
        'description': 'Package root directory to analyze.',
        'required': true,
      },
      {
        'name': 'closedApp',
        'description':
            'Set to "true" for a standalone application (public API is not '
            'retained). Omit or "false" for published libraries.',
        'required': false,
      },
    ],
  },
  {
    'name': 'dependency-audit',
    'description':
        'Audit pubspec hygiene: unused declarations, dev_dependencies used '
        'from lib/, and package: imports nothing declares.',
    'arguments': [
      {
        'name': 'packageRoot',
        'description': 'Package root directory to analyze.',
        'required': true,
      },
    ],
  },
  {
    'name': 'duplication-review',
    'description':
        'Review duplicated code blocks as consolidation candidates. '
        'Findings are token-structural matches, not proof of semantic '
        'equivalence.',
    'arguments': [
      {
        'name': 'packageRoot',
        'description': 'Package root directory to analyze.',
        'required': true,
      },
      {
        'name': 'minTokens',
        'description':
            'Minimum duplicated token window (integer ≥ 2; omit for the '
            'CLI default).',
        'required': false,
      },
    ],
  },
];

/// 프롬프트 이름과 인자를 렌더링한다. 모르는 이름·누락 packageRoot·잘못된
/// minTokens는 null이다 — 호출자가 이름과 인자 오류를 구분해 보고한다.
Map<String, Object?>? _getPrompt(String name, Map<String, Object?> arguments) {
  final packageRoot = arguments['packageRoot'];
  if (packageRoot is! String || packageRoot.trim().isEmpty) return null;
  final minTokens = arguments['minTokens'];
  if (minTokens != null) {
    // 프롬프트 인자는 문자열로 올 수 있다 — 정수로 해석 가능하고 ≥2면 받는다.
    final parsed = minTokens is int ? minTokens : int.tryParse('$minTokens');
    if (parsed == null || parsed < 2) return null;
  }
  final text = switch (name) {
    'impact-precheck' => _impactPrompt(packageRoot, arguments['since']),
    'dead-code-review' => _deadPrompt(packageRoot, arguments['closedApp']),
    'dependency-audit' =>
      'Audit the pubspec dependencies of the package at "$packageRoot".\n\n'
          '1. Call verify_run with command "deps", format "json", and '
          'packageRoot "$packageRoot".\n'
          '2. Review each finding: unused-dependency and '
          'unused-dev-dependency mean no analyzed source references the '
          'package (tool contracts like executables, builders, and lint '
          'includes already count as used); dev-dependency-in-lib means a '
          'dev dependency leaked into published code; undeclared-dependency '
          'means an import resolves through no declared section.\n'
          '3. Treat findings as review candidates — runtime loading and '
          'generated-code references are invisible to this audit.',
    'duplication-review' =>
      'Review duplicated code blocks in the package at "$packageRoot".\n\n'
          '1. Call verify_run with command "dup", format "json", and '
          'packageRoot "$packageRoot"'
          '${arguments['minTokens'] != null ? ', minTokens ${arguments['minTokens']}' : ''}.\n'
          '2. For each duplicate-block finding, open the listed instances and '
          'decide whether the match is accidental parallelism or a real '
          'consolidation candidate.\n'
          '3. Findings are token-structural matches — semantic equivalence is '
          'not verified, generated sources are excluded, and nothing here is '
          'a deletion or merge instruction.',
    _ => null,
  };
  if (text == null) return null;
  return {
    'description': _promptDefinitions
        .where((prompt) => prompt['name'] == name)
        .first['description'],
    'messages': [
      {
        'role': 'user',
        'content': {'type': 'text', 'text': text},
      },
    ],
  };
}

/// impact-precheck 프롬프트 본문이다.
String _impactPrompt(String packageRoot, Object? since) {
  final seed = since is String && since.trim().isNotEmpty
      ? 'call impact_query with packageRoot "$packageRoot" and since "$since"'
      : 'call impact_query with packageRoot "$packageRoot" and one seed: '
            'since (a git revision), changed (edited project-relative paths), '
            'or symbol (one symbol id)';
  return 'Pre-check the impact of the pending change in "$packageRoot" '
      'BEFORE editing.\n\n'
      '1. First $seed.\n'
      '2. Read impacted symbols with their shortest usage paths, callSites '
      'into changed declarations, the affected test libraries, and the risk '
      'score factors.\n'
      '3. Impact is observed dependency reachability — an unlisted '
      'declaration is not proven unaffected. Report the coverage block when '
      'it is non-zero.';
}

/// dead-code-review 프롬프트 본문이다.
String _deadPrompt(String packageRoot, Object? closedApp) {
  final closed = closedApp == true || closedApp == 'true';
  return 'Review unreachable declarations in "$packageRoot" as candidates '
      'for removal.\n\n'
      '1. Call verify_run with command "dead", format "json", packageRoot '
      '"$packageRoot"${closed ? ', and closedApp true' : ''}.\n'
      '${closed ? '   closed-app mode does not retain the public API — only use it because this is a standalone application.\n' : '   Public API stays retained because the package may be consumed as a library; pass closedApp only for standalone applications.\n'}'
      '2. For any finding worth removing, call dependency_query on the '
      'symbol to inspect its retention roots and usage evidence.\n'
      '3. Never treat a finding as proof of deletion safety — check the '
      'limitations list first.';
}

Future<Map<String, Object?>?> _callTool({
  required String name,
  required Map<String, Object?> arguments,
  required IndexPackage? indexPackage,
  required ChangedFilesSince? changedFilesSince,
  required Future<Directory> Function() createScratch,
  required String rootBoundary,
}) async {
  if (name != exploreToolName &&
      name != impactToolName &&
      name != dependencyToolName &&
      name != verifyToolName &&
      name != _runtimeToolName) {
    return null;
  }
  final root = arguments['packageRoot'];
  if (root is! String || root.trim().isEmpty) {
    return _toolError('packageRoot is required and must be a non-empty string');
  }
  final resolvedRoot = _resolveToolRoot(root, rootBoundary);
  if (resolvedRoot == null) {
    return _toolError(
      'packageRoot must be an existing directory within the server '
      'working directory',
    );
  }
  switch (name) {
    case exploreToolName:
      return _exploreTool(
        root: resolvedRoot,
        arguments: arguments,
        indexPackage: indexPackage,
        changedFilesSince: changedFilesSince,
        createScratch: createScratch,
      );
    case impactToolName:
      return _impactTool(
        root: resolvedRoot,
        arguments: arguments,
        indexPackage: indexPackage,
        changedFilesSince: changedFilesSince,
        createScratch: createScratch,
      );
    case dependencyToolName:
      return _dependencyTool(
        root: resolvedRoot,
        arguments: arguments,
        indexPackage: indexPackage,
        createScratch: createScratch,
      );
    case verifyToolName:
      return _verifyTool(
        root: resolvedRoot,
        arguments: arguments,
        indexPackage: indexPackage,
        changedFilesSince: changedFilesSince,
      );
    case _runtimeToolName:
      return _runtimeTool(root: resolvedRoot, arguments: arguments);
    default:
      return null;
  }
}

/// 도구 인자 `packageRoot`를 실제 디렉터리로 해석해 [boundary] 안임을
/// 확인한다. 존재하지 않거나 경계를 벗어나면 `null`을 돌려준다. 해석된
/// 경로를 그대로 도구에 넘겨 `a/../b` 같은 우회와 cwd 기준 상대 경로
/// 불일치를 없앤다.
String? _resolveToolRoot(String root, String boundary) {
  final String resolved;
  try {
    resolved = Directory(root).absolute.resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
  if (!FileSystemEntity.isDirectorySync(resolved)) return null;
  return isPathWithinRoot(resolved, boundary) ? resolved : null;
}

Future<Map<String, Object?>> _impactTool({
  required String root,
  required Map<String, Object?> arguments,
  required IndexPackage? indexPackage,
  required ChangedFilesSince? changedFilesSince,
  required Future<Directory> Function() createScratch,
}) async {
  final seeds = [
    arguments['since'],
    arguments['changed'],
    arguments['symbol'],
  ].whereType<Object>().length;
  if (seeds != 1) {
    return _toolError('provide exactly one of since, changed, or symbol');
  }
  final args = <String>['impact'];
  final scratch = <Directory>[];
  try {
    if (arguments['since'] != null) {
      final since = arguments['since'];
      if (since is! String || since.trim().isEmpty) {
        return _toolError('since must be a non-empty string');
      }
      args.addAll(['--since', since]);
    } else if (arguments['changed'] != null) {
      final changed = arguments['changed'];
      if (changed is! List || changed.isEmpty || changed.length > 1000) {
        return _toolError('changed must be an array of 1-1000 paths');
      }
      if (changed.any((item) => item is! String || item.trim().isEmpty)) {
        return _toolError('changed entries must be non-empty strings');
      }
      final file = await _writeScratch(
        createScratch,
        scratch,
        changed.cast<String>(),
      );
      args.addAll(['--changed', file.path]);
    } else {
      final symbol = arguments['symbol'];
      if (symbol is! String || symbol.trim().isEmpty) {
        return _toolError('symbol must be a non-empty string');
      }
      args.addAll(['--symbol', symbol]);
    }
    final depth = _positiveInt(arguments['depth']);
    if (depth != null) args.addAll(['--depth', '$depth']);
    final limit = _positiveInt(arguments['limit']);
    if (limit != null) args.addAll(['--limit', '$limit']);
    args.addAll(['--format', 'json', root]);
    return await _runCapture(
      args,
      indexPackage: indexPackage,
      changedFilesSince: changedFilesSince,
    );
  } finally {
    for (final directory in scratch) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // 정리 실패는 도구 결과가 아니다. OS 임시 디렉터리에 남는다.
      }
    }
  }
}

Future<Map<String, Object?>> _dependencyTool({
  required String root,
  required Map<String, Object?> arguments,
  required IndexPackage? indexPackage,
  required Future<Directory> Function() createScratch,
}) async {
  final symbol = arguments['symbol'];
  final batch = arguments['batch'];
  if ((symbol == null) == (batch == null)) {
    return _toolError('provide exactly one of symbol or batch');
  }
  final args = <String>['query'];
  final scratch = <Directory>[];
  try {
    if (symbol != null) {
      if (symbol is! String || symbol.trim().isEmpty) {
        return _toolError('symbol must be a non-empty string');
      }
      args.add(symbol);
    } else {
      if (batch is! List || batch.isEmpty || batch.length > 1000) {
        return _toolError('batch must be an array of 1-1000 symbols');
      }
      if (batch.any((item) => item is! String || item.trim().isEmpty)) {
        return _toolError('batch entries must be non-empty strings');
      }
      final file = await _writeScratch(
        createScratch,
        scratch,
        batch.cast<String>(),
      );
      args.addAll(['--batch', file.path]);
    }
    final depth = _positiveInt(arguments['depth']);
    if (depth != null) args.addAll(['--depth', '$depth']);
    final limit = _positiveInt(arguments['limit']);
    if (limit != null) args.addAll(['--limit', '$limit']);
    final baseline = arguments['baseline'];
    if (baseline != null) {
      if (baseline is! String || baseline.trim().isEmpty) {
        return _toolError('baseline must be a non-empty string');
      }
      args.addAll(['--baseline', baseline]);
    }
    final withSource = arguments['withSource'];
    final sourceContext = arguments['sourceContext'];
    if (withSource != null && withSource is! bool) {
      return _toolError('withSource must be a boolean');
    }
    if (sourceContext != null) {
      // 의도 없는 소스 문맥 지정을 조용히 무시하지 않는다.
      if (withSource != true) {
        return _toolError('sourceContext requires withSource true');
      }
      if (sourceContext is! int || sourceContext < 0) {
        return _toolError('sourceContext must be an integer >= 0');
      }
    }
    if (withSource == true) {
      args.add('--with-source');
      if (sourceContext != null) {
        args.addAll(['--source-context', '$sourceContext']);
      }
    }
    args.add(root);
    return await _runCapture(args, indexPackage: indexPackage);
  } finally {
    for (final directory in scratch) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // 위와 같다.
      }
    }
  }
}

Future<Map<String, Object?>> _verifyTool({
  required String root,
  required Map<String, Object?> arguments,
  required IndexPackage? indexPackage,
  required ChangedFilesSince? changedFilesSince,
}) async {
  final command = arguments['command'];
  const commands = {'dead', 'deps', 'dup', 'cycles', 'rules', 'metrics'};
  if (command is! String || !commands.contains(command)) {
    return _toolError('command must be one of ${commands.join(', ')}');
  }
  final format = arguments['format'];
  const formats = {'text', 'json', 'markdown', 'github-actions', 'sarif'};
  if (format != null && (format is! String || !formats.contains(format))) {
    return _toolError('format must be one of ${formats.join(', ')}');
  }
  final args = <String>[command];
  if (arguments['strict'] == true) args.add('--strict');
  // closed-app은 dead의 전제를 바꾸는 플래그다 — 다른 명령에 붙이면 호출
  // 의도가 없는데 조용히 무시되므로 오류로 답한다. 'true' 문자열도 불리언과
  // 같이 해석한다(_deadPrompt의 인자 해석과 같은 기준).
  if (arguments['closedApp'] == true || arguments['closedApp'] == 'true') {
    if (command != 'dead') {
      return _toolError('closedApp is only valid for command dead');
    }
    args.add('--closed-app');
  }
  final since = arguments['since'];
  if (since != null) {
    if (since is! String || since.trim().isEmpty) {
      return _toolError('since must be a non-empty string');
    }
    args.addAll(['--since', since]);
  }
  final baseline = arguments['baseline'];
  if (baseline != null) {
    if (baseline is! String || baseline.trim().isEmpty) {
      return _toolError('baseline must be a non-empty string');
    }
    args.addAll(['--baseline', baseline]);
  }
  final config = arguments['config'];
  if (config != null) {
    if (config is! String || config.trim().isEmpty) {
      return _toolError('config must be a non-empty string');
    }
    args.addAll(['--config', config]);
  }
  final minTokens = arguments['minTokens'];
  if (minTokens != null) {
    // closed-app과 같은 이유로 의도 없는 인자를 조용히 무시하지 않는다.
    if (command != 'dup') {
      return _toolError('minTokens is only valid for command dup');
    }
    if (minTokens is! int || minTokens < 2) {
      return _toolError('minTokens must be an integer ≥ 2');
    }
    args.addAll(['--min-tokens', '$minTokens']);
  }
  final kinds = arguments['kinds'];
  if (kinds != null) {
    // minTokens와 같은 이유로 의도 없는 인자를 조용히 무시하지 않는다.
    if (command != 'dead' && command != 'deps' && command != 'dup') {
      return _toolError('kinds is only valid for command dead, deps, or dup');
    }
    if (kinds is! List ||
        kinds.isEmpty ||
        kinds.any(
          (item) =>
              item is! String || item.trim().isEmpty || item.contains(','),
        )) {
      return _toolError(
        'kinds must be a non-empty list of strings without commas',
      );
    }
    args.addAll(['--kinds', kinds.join(',')]);
  }
  // `dead`·`deps`·`dup`는 5형식을, `cycles`·`rules`·`metrics`는 text·json·sarif를
  // 받는다. 후자에 markdown·github-actions를 주면 CLI가 usage(64)로 거부하지만,
  // 도구가 먼저 인자 오류로 해 원인을 분명히 한다.
  if (format != null &&
      (command == 'dead' || command == 'deps' || command == 'dup')) {
    args.addAll(['--format', '$format']);
  } else if (format != null &&
      (command == 'cycles' || command == 'rules' || command == 'metrics')) {
    if (format != 'text' && format != 'json' && format != 'sarif') {
      return _toolError('format for $command must be one of text, json, sarif');
    }
    args.addAll(['--format', '$format']);
  }
  args.add(root);
  return await _runCapture(
    args,
    indexPackage: indexPackage,
    changedFilesSince: changedFilesSince,
  );
}

Future<Map<String, Object?>> _runtimeTool({
  required String root,
  required Map<String, Object?> arguments,
}) async {
  if (arguments.keys.any((key) => key != 'packageRoot' && key != 'limit')) {
    return _toolError(
      'Unsupported option; only packageRoot and limit are allowed',
    );
  }
  final args = <String>['runtime', '--no-verify', '--format', 'json'];
  final limit = arguments['limit'];
  if (arguments.containsKey('limit') && (limit is! int || limit < 1)) {
    return _toolError('limit must be an integer >= 1');
  }
  if (limit != null) args.addAll(['--limit', '$limit']);
  args.add(root);
  return await _runCapture(args);
}

/// `dartograph_explore`의 통합 진입점이다.
///
/// 어떤 인자가 왔는지로 아래 경로 중 하나에 **결정적으로** 라우팅한다 —
/// `command`가 있으면 검증·런타임 경로, `since`·`changed`·`impactSymbol`이
/// 있으면 impact 경로, `symbol`·`batch`가 있으면 query 경로다. 경로에 의미가
/// 없는 인자는 조용히 무시하지 않고 거부하며, 어떤 질문 형태도 없으면 형태
/// 안내를 돌려준다. 응답 첫 줄의 `routed:`가 실제로 답한 경로를 밝힌다.
Future<Map<String, Object?>> _exploreTool({
  required String root,
  required Map<String, Object?> arguments,
  required IndexPackage? indexPackage,
  required ChangedFilesSince? changedFilesSince,
  required Future<Directory> Function() createScratch,
}) async {
  final command = arguments['command'];
  if (command != null) {
    if (command == 'runtime') {
      final strays = _strayKeys(arguments, const {'command', 'limit'});
      if (strays != null) {
        return _toolError('cannot combine $strays with command "runtime"');
      }
      return _routed(
        await _runtimeTool(
          root: root,
          arguments: {'limit': arguments['limit']},
        ),
        _runtimeToolName,
      );
    }
    const verifyKeys = {
      'command',
      'strict',
      'minTokens',
      'kinds',
      'closedApp',
      'since',
      'baseline',
      'config',
      'format',
    };
    final strays = _strayKeys(arguments, verifyKeys);
    if (strays != null) {
      return _toolError('cannot combine $strays with command');
    }
    return _routed(
      await _verifyTool(
        root: root,
        arguments: arguments,
        indexPackage: indexPackage,
        changedFilesSince: changedFilesSince,
      ),
      verifyToolName,
    );
  }
  final impactSeeds = [
    'since',
    'changed',
    'impactSymbol',
  ].where((key) => arguments[key] != null).toList();
  if (impactSeeds.isNotEmpty) {
    const impactKeys = {'since', 'changed', 'impactSymbol', 'depth', 'limit'};
    final strays = _strayKeys(arguments, impactKeys);
    if (strays != null) {
      return _toolError(
        'cannot combine $strays with since, changed, or impactSymbol',
      );
    }
    if (impactSeeds.length != 1) {
      return _toolError(
        'provide exactly one of since, changed, or impactSymbol',
      );
    }
    return _routed(
      await _impactTool(
        root: root,
        arguments: {
          // impactSymbol은 impact --symbol seed로 재배치한다 — 같은 실행
          // 경로를 쓰되 질문 형태(심볼 → 영향)가 명시적으로 남는다.
          if (arguments['impactSymbol'] != null)
            'symbol': arguments['impactSymbol'],
          if (arguments['since'] != null) 'since': arguments['since'],
          if (arguments['changed'] != null) 'changed': arguments['changed'],
          if (arguments['depth'] != null) 'depth': arguments['depth'],
          if (arguments['limit'] != null) 'limit': arguments['limit'],
        },
        indexPackage: indexPackage,
        changedFilesSince: changedFilesSince,
        createScratch: createScratch,
      ),
      impactToolName,
    );
  }
  if (arguments['symbol'] != null || arguments['batch'] != null) {
    const queryKeys = {
      'symbol',
      'batch',
      'depth',
      'limit',
      'baseline',
      'withSource',
      'sourceContext',
    };
    final strays = _strayKeys(arguments, queryKeys);
    if (strays != null) {
      return _toolError('cannot combine $strays with symbol or batch');
    }
    final query = Map<String, Object?>.of(arguments);
    // 통합 진입점의 약속은 "소스+근거 한 응답"이므로 withSource를 기본으로
    // 켠다 — 호출자가 false·sourceContext를 명시하면 그 값이 우선한다.
    query['withSource'] ??= true;
    if (query['withSource'] == true) query['sourceContext'] ??= 3;
    return _routed(
      await _dependencyTool(
        root: root,
        arguments: query,
        indexPackage: indexPackage,
        createScratch: createScratch,
      ),
      dependencyToolName,
    );
  }
  return _exploreHelp();
}

/// [allowed]·`packageRoot` 밖의 인자 키를 정렬된 문자열로 돌려준다 — 없으면
/// null이다. `packageRoot`는 모든 경로의 공통 인자라 항상 허용한다.
String? _strayKeys(Map<String, Object?> arguments, Set<String> allowed) {
  final strays =
      arguments.keys
          .where((key) => key != 'packageRoot' && !allowed.contains(key))
          .toList()
        ..sort();
  return strays.isEmpty ? null : strays.join(', ');
}

/// 도구 응답 첫 줄에 `routed:` 표지를 붙인다.
///
/// 통합 진입점이 어떤 경로로 답했는지를 결과 안에 남긴다 — 라우팅이 호출자의
/// 기대와 다를 때 출력 형태만 보고 해석을 어긋내는 대신 표지로 바로 알 수
/// 있게 한다.
Map<String, Object?> _routed(Map<String, Object?> result, String tool) {
  final content = result['content'];
  if (content is List && content.isNotEmpty) {
    final first = content.first;
    if (first is Map && first['text'] is String) {
      first['text'] = 'routed: $tool\n${first['text']}';
    }
  }
  return result;
}

/// 질문 형태 없이 호출된 `dartograph_explore`의 안내 응답이다.
///
/// 오류가 아니라 메뉴다 — 이 도구의 존재 이유가 안내(steering)라서, 비어
/// 있는 호출에는 다음 호출이 바로 쓸 수 있는 형태 목록을 돌려준다.
Map<String, Object?> _exploreHelp() => {
  'content': [
    {
      'type': 'text',
      'text':
          'routed: help\n'
          'dartograph_explore needs packageRoot plus exactly one question '
          'shape:\n'
          '- symbol "<name or id>" or batch ["a", "b"] — declarations, '
          'members, callers/dependents (usedBy), retention evidence, and '
          'the source lines in one response.\n'
          '- impactSymbol "<id>" — what depends on one declaration '
          '(pre-change blast radius).\n'
          '- since "<git-rev>" or changed ["lib/a.dart"] — what a change '
          'set affects: impacted symbols, call sites, related tests, risk '
          'score.\n'
          '- command "dead" | "deps" | "dup" | "cycles" | "rules" | '
          '"metrics" — run a verification; command "runtime" lists static '
          'runtime facts.\n'
          'Findings are graph evidence with stated limitations, not '
          'deletion proof.',
    },
  ],
  'isError': false,
};

/// 기존 CLI 실행 경로를 그대로 재사용해 출력과 종료 코드를 모은다.
Future<Map<String, Object?>> _runCapture(
  List<String> arguments, {
  IndexPackage? indexPackage,
  ChangedFilesSince? changedFilesSince,
}) async {
  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final status = await runDartograph(
    arguments,
    output: stdoutBuffer,
    error: stderrBuffer,
    indexPackage: indexPackage,
    changedFilesSince: changedFilesSince,
  );
  final text = stdoutBuffer.toString();
  final diagnostics = stderrBuffer.toString();
  final failed =
      status == ExitStatus.failure.code || status == ExitStatus.usage.code;
  final buffer = StringBuffer();
  buffer.writeln('exitCode: $status');
  if (text.isNotEmpty) buffer.write(text);
  if (failed && diagnostics.isNotEmpty) buffer.write(diagnostics);
  return {
    'content': [
      {'type': 'text', 'text': buffer.toString()},
    ],
    'isError': failed,
  };
}

Map<String, Object?> _toolError(String message) => {
  'content': [
    {'type': 'text', 'text': 'Invalid arguments: $message'},
  ],
  'isError': true,
};

int? _positiveInt(Object? value) {
  if (value is int && value >= 1) return value;
  return null;
}

Future<File> _writeScratch(
  Future<Directory> Function() createScratch,
  List<Directory> scratch,
  List<String> values,
) async {
  final directory = await createScratch();
  scratch.add(directory);
  final file = File(p.join(directory.path, 'input.json'));
  await file.writeAsString(jsonEncode(values));
  return file;
}

void _writeResult(StringSink output, Object? id, Object? result) {
  output.writeln(jsonEncode({'id': id, 'jsonrpc': '2.0', 'result': result}));
}

void _writeError(StringSink output, Object? id, int code, String message) {
  output.writeln(
    jsonEncode({
      'error': {'code': code, 'message': message},
      'id': id,
      'jsonrpc': '2.0',
    }),
  );
}
