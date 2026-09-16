import 'dart:convert';
import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/mcp_server.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late AnalyzerGraphResult indexed;
  late List<Directory> scratch;
  late StringBuffer diagnostics;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mcp-test.');
    scratch = [];
    diagnostics = StringBuffer();
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:lib/a.dart::Foo',
          sourceUri: 'project:lib/a.dart',
        ),
      )
      ..addNode(GraphNode(id: 'project:lib/b.dart', isLibrary: true))
      ..addNode(
        GraphNode(
          id: 'project:lib/b.dart::Bar',
          sourceUri: 'project:lib/b.dart',
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/b.dart',
          targetId: 'project:lib/a.dart',
          kind: EdgeKind.import,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'project:lib/b.dart::Bar',
          targetId: 'project:lib/a.dart::Foo',
          kind: EdgeKind.call,
        ),
      );
    indexed = AnalyzerGraphResult(graph: graph, limitations: const []);
  });

  tearDown(() => directory.delete(recursive: true));

  /// JSON-RPC 메시지 목록을 서버에 흘려보내고 응답을 파싱한다.
  Future<List<Map<String, Object?>>> exchange(List<Object?> messages) async {
    final output = StringBuffer();
    final status = await runMcpServer(
      input: Stream.fromIterable(messages.map(jsonEncode)),
      output: output,
      error: diagnostics,
      indexPackage: (root) async {
        if (!Directory(root).existsSync()) {
          throw const FileSystemException('missing package root');
        }
        return indexed;
      },
      createScratch: () async {
        final created = await Directory.systemTemp.createTemp('mcp-scratch.');
        scratch.add(created);
        return created;
      },
      allowedRootBase: Directory.systemTemp.path,
    );
    expect(status, 0);
    return output
        .toString()
        .trim()
        .split('\n')
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
  }

  Object request(int id, String method, [Object? params]) => {
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': ?params,
  };

  test(
    'initialize negotiates the protocol and reports the server version',
    () async {
      final responses = await exchange([
        request(1, 'initialize', {'protocolVersion': mcpProtocolVersion}),
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      ]);

      expect(responses.length, 1);
      final result = responses.single['result'] as Map<String, Object?>;
      expect(result['protocolVersion'], mcpProtocolVersion);
      final info = result['serverInfo'] as Map<String, Object?>;
      expect(info['name'], 'dartograph');
      expect(info['version'], isNotEmpty);
      expect(result['capabilities'], {
        'tools': <String, Object?>{},
        'resources': <String, Object?>{},
        'prompts': <String, Object?>{},
      });
    },
  );

  test(
    'resources/list and resources/read serve the static documents',
    () async {
      final responses = await exchange([
        request(20, 'resources/list'),
        request(21, 'resources/read', {'uri': 'dartograph://usage'}),
        request(22, 'resources/read', {'uri': 'dartograph://skill'}),
        request(23, 'resources/read', {'uri': 'dartograph://config'}),
        request(24, 'resources/read', {'uri': 'dartograph://missing'}),
      ]);

      final listed = ((responses[0]['result'] as Map)['resources'] as List)
          .cast<Map<String, Object?>>();
      expect(listed.map((r) => r['uri']).toList(), [
        'dartograph://usage',
        'dartograph://skill',
        'dartograph://config',
      ]);

      final usage = ((responses[1]['result'] as Map)['contents'] as List)
          .cast<Map<String, Object?>>()
          .single;
      expect(usage['mimeType'], 'text/plain');
      expect(usage['text'] as String, contains('dartograph deps'));

      final skill = ((responses[2]['result'] as Map)['contents'] as List)
          .cast<Map<String, Object?>>()
          .single;
      expect(skill['mimeType'], 'text/markdown');
      expect(skill['text'] as String, contains('dartograph'));

      final config = ((responses[3]['result'] as Map)['contents'] as List)
          .cast<Map<String, Object?>>()
          .single;
      expect(config['mimeType'], 'text/yaml');
      expect(config['text'] as String, contains('entry_points'));

      expect((responses[4]['error'] as Map)['code'], -32002);
    },
  );

  test('prompts/list and prompts/get render workflow prompts', () async {
    final responses = await exchange([
      request(30, 'prompts/list'),
      request(31, 'prompts/get', {
        'name': 'impact-precheck',
        'arguments': {'packageRoot': directory.path, 'since': 'HEAD'},
      }),
      request(32, 'prompts/get', {
        'name': 'dead-code-review',
        'arguments': {'packageRoot': directory.path, 'closedApp': 'true'},
      }),
      request(33, 'prompts/get', {
        'name': 'dependency-audit',
        'arguments': {'packageRoot': directory.path},
      }),
      request(34, 'prompts/get', {
        'name': 'duplication-review',
        'arguments': {'packageRoot': directory.path, 'minTokens': '40'},
      }),
      request(35, 'prompts/get', {'name': 'nope', 'arguments': {}}),
      request(36, 'prompts/get', {
        'name': 'impact-precheck',
        'arguments': <String, Object?>{},
      }),
    ]);

    final listed = ((responses[0]['result'] as Map)['prompts'] as List)
        .cast<Map<String, Object?>>();
    expect(listed.map((p) => p['name']).toList(), [
      'impact-precheck',
      'dead-code-review',
      'dependency-audit',
      'duplication-review',
    ]);

    String textOf(Map<String, Object?> response) =>
        ((((response['result'] as Map)['messages'] as List)
                    .cast<Map<String, Object?>>()
                    .single)['content']
                as Map)['text']
            as String;

    expect(textOf(responses[1]), contains('since "HEAD"'));
    expect(textOf(responses[1]), contains(directory.path));
    expect(textOf(responses[2]), contains('closedApp true'));
    expect(textOf(responses[3]), contains('command "deps"'));
    expect(textOf(responses[4]), contains('command "dup"'));
    expect(textOf(responses[4]), contains('minTokens 40'));
    expect((responses[5]['error'] as Map)['code'], -32602);
    expect((responses[6]['error'] as Map)['code'], -32602);
  });

  test('verify_run rejects closedApp for non-dead commands', () async {
    final responses = await exchange([
      request(40, 'tools/call', {
        'name': verifyToolName,
        'arguments': {
          'packageRoot': directory.path,
          'command': 'cycles',
          'closedApp': true,
        },
      }),
      // 문자열 'true'도 불리언과 같이 해석한다 — 프롬프트 인자 해석과 같은 기준.
      request(41, 'tools/call', {
        'name': verifyToolName,
        'arguments': {
          'packageRoot': directory.path,
          'command': 'cycles',
          'closedApp': 'true',
        },
      }),
    ]);

    for (final response in responses) {
      final result = response['result'] as Map<String, Object?>;
      expect(result['isError'], isTrue);
      expect(
        ((result['content'] as List).single as Map)['text'],
        contains('closedApp is only valid for command dead'),
      );
    }
  });

  test(
    'verify_run validates minTokens for dup and rejects it elsewhere',
    () async {
      final responses = await exchange([
        request(50, 'tools/call', {
          'name': verifyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'command': 'dup',
            'minTokens': 12,
          },
        }),
        request(51, 'tools/call', {
          'name': verifyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'command': 'dead',
            'minTokens': 12,
          },
        }),
        request(52, 'tools/call', {
          'name': verifyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'command': 'dup',
            'minTokens': 1,
          },
        }),
      ]);

      // 첫 호출은 CLI에 `--min-tokens 12`로 전달된다(실행 여부와 무관하게
      // 인자 검증을 통과한다는 것을 나머지 케이스의 오류와 대조해 본다).
      final passed = responses[0]['result'] as Map<String, Object?>;
      expect(passed.containsKey('isError'), isTrue);
      for (final response in responses.sublist(1)) {
        final result = response['result'] as Map<String, Object?>;
        expect(result['isError'], isTrue);
        expect(
          ((result['content'] as List).single as Map)['text'],
          contains('minTokens'),
        );
      }
    },
  );

  test('verify_run validates kinds and forwards them to the CLI', () async {
    final responses = await exchange([
      // cycles는 kinds를 받지 않는다.
      request(60, 'tools/call', {
        'name': verifyToolName,
        'arguments': {
          'packageRoot': directory.path,
          'command': 'cycles',
          'kinds': ['file'],
        },
      }),
      // 빈 목록과 비문자열 항목은 거부한다.
      request(61, 'tools/call', {
        'name': verifyToolName,
        'arguments': {
          'packageRoot': directory.path,
          'command': 'dead',
          'kinds': <String>[],
        },
      }),
      request(62, 'tools/call', {
        'name': verifyToolName,
        'arguments': {
          'packageRoot': directory.path,
          'command': 'dead',
          'kinds': [1],
        },
      }),
      // 쉼표를 포함한 항목은 join(',')을 거치며 두 kind로 새어 나간다.
      request(63, 'tools/call', {
        'name': verifyToolName,
        'arguments': {
          'packageRoot': directory.path,
          'command': 'dead',
          'kinds': ['file,declaration'],
        },
      }),
    ]);

    expect(
      ((responses[0]['result'] as Map)['content'] as List)
          .cast<Map>()
          .single['text'],
      contains('kinds is only valid for command dead, deps, or dup'),
    );
    for (final response in responses.sublist(1)) {
      final result = response['result'] as Map<String, Object?>;
      expect(result['isError'], isTrue);
      expect(
        ((result['content'] as List).single as Map)['text'],
        contains('kinds must be a non-empty list of strings'),
      );
    }
  });

  test(
    'tool calls reject non-string argv values instead of interpolating',
    () async {
      final responses = await exchange([
        // impact_query: since·symbol에 문자열이 아닌 값이 오면 argv로
        // 문자열화하지 않고 거부한다.
        request(70, 'tools/call', {
          'name': impactToolName,
          'arguments': {'packageRoot': directory.path, 'since': 5},
        }),
        request(71, 'tools/call', {
          'name': impactToolName,
          'arguments': {
            'packageRoot': directory.path,
            'symbol': <String, Object?>{'x': 1},
          },
        }),
        // verify_run: baseline·config도 같은 기준이다.
        request(72, 'tools/call', {
          'name': verifyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'command': 'dead',
            'baseline': 7,
          },
        }),
        request(73, 'tools/call', {
          'name': verifyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'command': 'dead',
            'config': <Object?>[],
          },
        }),
        // prompts/get: minTokens가 정수로 해석되지 않으면 인자 오류다.
        request(74, 'prompts/get', {
          'name': 'duplication-review',
          'arguments': {'packageRoot': directory.path, 'minTokens': 'abc'},
        }),
        request(75, 'prompts/get', {
          'name': 'duplication-review',
          'arguments': {'packageRoot': directory.path, 'minTokens': 1},
        }),
      ]);

      for (final response in responses.sublist(0, 4)) {
        final result = response['result'] as Map<String, Object?>;
        expect(result['isError'], isTrue);
        expect(
          ((result['content'] as List).single as Map)['text'],
          contains('must be a non-empty string'),
        );
      }
      for (final response in responses.sublist(4)) {
        expect((response['error'] as Map)['code'], -32602);
      }
    },
  );

  test('id 없는 요청 형태 메시지는 notification이라 응답하지 않는다', () async {
    final responses = await exchange([
      // JSON-RPC notification은 어떤 메서드든 id가 없으면 응답을 받지 않는다.
      {'jsonrpc': '2.0', 'method': 'ping'},
      {'jsonrpc': '2.0', 'method': 'no/such_method'},
      // 응답 형태(result) 메시지도 마찬가지다.
      {'jsonrpc': '2.0', 'id': 7, 'result': <String, Object?>{}},
      // 유효 요청 하나로 응답이 실제로 흐르는지 대조한다.
      request(42, 'ping'),
    ]);

    expect(responses.single['id'], 42);
    expect(responses.single, isNot(contains('error')));
  });

  test('tools/list exposes the three read-only tools with schemas', () async {
    final responses = await exchange([request(2, 'tools/list')]);

    final tools = ((responses.single['result'] as Map)['tools'] as List)
        .cast<Map<String, Object?>>();
    expect(tools.map((tool) => tool['name']).toList(), [
      impactToolName,
      dependencyToolName,
      verifyToolName,
    ]);
    for (final tool in tools) {
      final schema = tool['inputSchema'] as Map<String, Object?>;
      expect(schema['type'], 'object');
      expect((schema['required'] as List), contains('packageRoot'));
    }
  });

  test(
    'impact_query answers a JSON impact document and cleans scratch files',
    () async {
      final responses = await exchange([
        request(3, 'tools/call', {
          'name': impactToolName,
          'arguments': {
            'packageRoot': directory.path,
            'changed': ['lib/a.dart'],
          },
        }),
      ]);

      final result = responses.single['result'] as Map<String, Object?>;
      expect(result['isError'], isFalse);
      final text =
          (result['content'] as List)
                  .cast<Map<String, Object?>>()
                  .single['text']
              as String;
      expect(text, startsWith('exitCode: 0'));
      final document =
          jsonDecode(text.substring(text.indexOf('\n')))
              as Map<String, Object?>;
      expect(document['version'], 1);
      expect((document['coverage'] as Map)['relatedTests'], 0);
      // 임시 파일이 남지 않아야 한다(도구가 만든 scratch 디렉터리 정리).
      expect(scratch, isNotEmpty);
      for (final created in scratch) {
        expect(created.existsSync(), isFalse);
      }
    },
  );

  test('impact_query rejects ambiguous seed inputs', () async {
    final responses = await exchange([
      request(4, 'tools/call', {
        'name': impactToolName,
        'arguments': {
          'packageRoot': directory.path,
          'since': 'HEAD',
          'symbol': 'project:lib/a.dart::Foo',
        },
      }),
    ]);

    final result = responses.single['result'] as Map<String, Object?>;
    expect(result['isError'], isTrue);
    expect(
      ((result['content'] as List).single as Map)['text'],
      contains('exactly one of since, changed, or symbol'),
    );
  });

  test('dependency_query answers a symbol query', () async {
    final responses = await exchange([
      request(5, 'tools/call', {
        'name': dependencyToolName,
        'arguments': {
          'packageRoot': directory.path,
          'symbol': 'project:lib/a.dart',
        },
      }),
    ]);

    final result = responses.single['result'] as Map<String, Object?>;
    expect(result['isError'], isFalse);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    expect(text, contains('"requested"'));
  });

  test('dependency_query rejects a missing selector', () async {
    final responses = await exchange([
      request(6, 'tools/call', {
        'name': dependencyToolName,
        'arguments': {'packageRoot': directory.path},
      }),
    ]);

    final result = responses.single['result'] as Map<String, Object?>;
    expect(result['isError'], isTrue);
  });

  test(
    'verify_run reports the exit code and output for a successful run',
    () async {
      final responses = await exchange([
        request(7, 'tools/call', {
          'name': verifyToolName,
          'arguments': {'packageRoot': directory.path, 'command': 'cycles'},
        }),
      ]);

      final result = responses.single['result'] as Map<String, Object?>;
      expect(result['isError'], isFalse);
      final text =
          ((result['content'] as List).single as Map)['text'] as String;
      expect(text, startsWith('exitCode: 0'));
    },
  );

  test('verify_run rejects a packageRoot that does not exist', () async {
    final responses = await exchange([
      request(8, 'tools/call', {
        'name': verifyToolName,
        'arguments': {
          'packageRoot': p.join(directory.path, 'does-not-exist'),
          'command': 'cycles',
        },
      }),
    ]);

    // 존재하지 않는 루트는 하위 명령 실패로 이어지기 전에 인자 오류로 거부된다.
    final result = responses.single['result'] as Map<String, Object?>;
    expect(result['isError'], isTrue);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    expect(text, contains('existing directory'));
  });

  test('verify_run rejects an invalid command', () async {
    final responses = await exchange([
      request(9, 'tools/call', {
        'name': verifyToolName,
        'arguments': {'packageRoot': directory.path, 'command': 'delete'},
      }),
    ]);

    final result = responses.single['result'] as Map<String, Object?>;
    expect(result['isError'], isTrue);
    expect(
      ((result['content'] as List).single as Map)['text'],
      contains('command must be one of'),
    );
  });

  test(
    'tools/call rejects a packageRoot outside the server boundary',
    () async {
      final output = StringBuffer();
      final boundary = await Directory.systemTemp.createTemp('mcp-boundary.');
      addTearDown(() => boundary.delete(recursive: true));
      await runMcpServer(
        input: Stream.fromIterable([
          jsonEncode(
            request(60, 'tools/call', {
              'name': dependencyToolName,
              // directory는 경계 밖의 임시 디렉터리다.
              'arguments': {'packageRoot': directory.path, 'symbol': 'Foo'},
            }),
          ),
          jsonEncode(request(61, 'ping')),
        ]),
        output: output,
        error: diagnostics,
        indexPackage: (_) async => indexed,
        allowedRootBase: boundary.path,
      );

      final responses = output
          .toString()
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map<String, Object?>)
          .toList();
      final tool = responses[0]['result'] as Map<String, Object?>;
      expect(tool['isError'], isTrue);
      expect(
        ((tool['content'] as List).single as Map)['text'],
        contains('within the server working directory'),
      );
      // 경계 위반 요청 이후에도 서버는 계속 응답한다.
      expect(responses[1]['result'], <String, Object?>{});
    },
  );

  test(
    'oversized lines are rejected and the connection stays usable',
    () async {
      final output = StringBuffer();
      final oversized = utf8.encode(
        '{"jsonrpc":"2.0","id":1,"method":"ping","padding":"${'x' * 4096}"}\n',
      );
      final ping = utf8.encode('{"jsonrpc":"2.0","id":2,"method":"ping"}\n');
      await runMcpServer(
        input: Stream<List<int>>.fromIterable([
          oversized,
          ping,
        ]).transform(boundedUtf8Lines(1024)),
        output: output,
        error: diagnostics,
        indexPackage: (_) async => indexed,
      );

      final responses = output
          .toString()
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map<String, Object?>)
          .toList();
      // 상한에서 잘린 메시지는 파싱 불가라 Invalid JSON으로 답한다.
      expect((responses[0]['error'] as Map)['code'], -32700);
      expect(responses[1]['result'], <String, Object?>{});
    },
  );

  test('protocol errors are answered without crashing the server', () async {
    final output = StringBuffer();
    await runMcpServer(
      input: Stream.fromIterable(const [
        'not json',
        '{"jsonrpc":"2.0","id":10,"method":"no/such"}',
        '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"nope"}}',
        '{"jsonrpc":"2.0","id":12,"method":"ping"}',
      ]),
      output: output,
      error: diagnostics,
      indexPackage: (_) async => indexed,
    );

    final responses = output
        .toString()
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
    expect((responses[0]['error'] as Map)['code'], -32700);
    expect(responses[0]['id'], isNull);
    expect((responses[1]['error'] as Map)['code'], -32601);
    expect((responses[2]['error'] as Map)['code'], -32602);
    expect(responses[3]['result'], <String, Object?>{});
  });
}
