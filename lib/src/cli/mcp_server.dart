import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/tool_info.dart';
import 'dartograph_cli.dart';

/// dartograph가 구현하는 MCP 프로토콜 버전이다(stdio transport).
const mcpProtocolVersion = '2024-11-05';

/// JSON-RPC 2.0 에러 코드다.
const _parseError = -32700;
const _invalidRequest = -32600;
const _methodNotFound = -32601;
const _invalidParams = -32602;
const _internalError = -32603;

/// `impact_query` 도구 이름이다.
const impactToolName = 'impact_query';

/// `dependency_query` 도구 이름이다.
const dependencyToolName = 'dependency_query';

/// `verify_run` 도구 이름이다.
const verifyToolName = 'verify_run';

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
}) async {
  final scratchFactory =
      createScratch ?? () => Directory.systemTemp.createTemp('dartograph-mcp.');
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
      // id가 없는 메시지는 알림으로 간주하고 답하지 않는다.
      if (message.containsKey('id')) {
        _writeError(output, id, _invalidRequest, 'Missing method');
      }
      continue;
    }
    if (method.startsWith('notifications/')) continue;
    switch (method) {
      case 'initialize':
        _writeResult(output, id, {
          'capabilities': {'tools': <String, Object?>{}},
          'protocolVersion': mcpProtocolVersion,
          'serverInfo': {'name': 'dartograph', 'version': toolVersion},
        });
      case 'ping':
        _writeResult(output, id, <String, Object?>{});
      case 'tools/list':
        _writeResult(output, id, {'tools': _toolDefinitions});
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

/// 도구 정의(이름·설명·입력 스키마)를 결정적 순서로 돌려준다.
List<Map<String, Object?>> get _toolDefinitions => [
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
      },
      'required': ['packageRoot'],
      'additionalProperties': false,
    },
  },
  {
    'name': verifyToolName,
    'description':
        'Run a dartograph verification and return its exit code with the raw '
        'output: dead (unreachable declarations), cycles, rules (layer '
        'violations), or metrics. Use format json for a machine-readable '
        'document. Read-only.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'packageRoot': {
          'type': 'string',
          'description': 'Package root directory to analyze.',
        },
        'command': {
          'type': 'string',
          'enum': ['dead', 'cycles', 'rules', 'metrics'],
        },
        'strict': {'type': 'boolean'},
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
];

Future<Map<String, Object?>?> _callTool({
  required String name,
  required Map<String, Object?> arguments,
  required IndexPackage? indexPackage,
  required ChangedFilesSince? changedFilesSince,
  required Future<Directory> Function() createScratch,
}) async {
  if (name != impactToolName &&
      name != dependencyToolName &&
      name != verifyToolName) {
    return null;
  }
  final root = arguments['packageRoot'];
  if (root is! String || root.trim().isEmpty) {
    return _toolError('packageRoot is required and must be a non-empty string');
  }
  switch (name) {
    case impactToolName:
      return _impactTool(
        root: root,
        arguments: arguments,
        indexPackage: indexPackage,
        changedFilesSince: changedFilesSince,
        createScratch: createScratch,
      );
    case dependencyToolName:
      return _dependencyTool(
        root: root,
        arguments: arguments,
        indexPackage: indexPackage,
        createScratch: createScratch,
      );
    case verifyToolName:
      return _verifyTool(
        root: root,
        arguments: arguments,
        indexPackage: indexPackage,
        changedFilesSince: changedFilesSince,
      );
    default:
      return null;
  }
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
      args.addAll(['--since', '${arguments['since']}']);
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
      args.addAll(['--symbol', '${arguments['symbol']}']);
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
  const commands = {'dead', 'cycles', 'rules', 'metrics'};
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
  final since = arguments['since'];
  if (since != null) {
    if (since is! String || since.trim().isEmpty) {
      return _toolError('since must be a non-empty string');
    }
    args.addAll(['--since', since]);
  }
  final baseline = arguments['baseline'];
  if (baseline != null) args.addAll(['--baseline', '$baseline']);
  final config = arguments['config'];
  if (config != null) args.addAll(['--config', '$config']);
  // `cycles`·`rules`·`metrics`는 --format을 받지 않는다(항상 JSON 질의 문서).
  // `dead`만 text·json·github-actions·sarif를 받는다.
  if (format != null && command == 'dead') {
    args.addAll(['--format', '$format']);
  }
  args.add(root);
  return await _runCapture(
    args,
    indexPackage: indexPackage,
    changedFilesSince: changedFilesSince,
  );
}

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
