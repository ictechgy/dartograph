import 'dart:convert';
import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
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

  Future<List<Map<String, Object?>>> exchangeDefault(
    Stream<Object?> messages, {
    Future<Directory> Function()? createCacheDirectory,
    IndexPackage? indexPackage,
  }) async {
    final output = StringBuffer();
    await runMcpServer(
      input: messages.map(jsonEncode),
      output: output,
      error: diagnostics,
      allowedRootBase: directory.path,
      createCacheDirectory: createCacheDirectory,
      indexPackage: indexPackage,
    );
    return const LineSplitter()
        .convert(output.toString())
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
  }

  String textOf(Map<String, Object?> response) =>
      (((response['result'] as Map)['content'] as List).single as Map)['text']
          as String;

  File writeSource(String root, String source) =>
      File(p.join(root, 'lib/a.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(source);

  Future<Directory> createCache() async {
    final created = await Directory.systemTemp.createTemp('mcp-cache-test.');
    scratch.add(created);
    addTearDown(() async {
      if (await created.exists()) await created.delete(recursive: true);
    });
    return created;
  }

  Object request(int id, String method, [Object? params]) => {
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': ?params,
  };

  Object query(int id, String root, [String symbol = 'Foo']) =>
      request(id, 'tools/call', {
        'name': dependencyToolName,
        'arguments': {'packageRoot': root, 'symbol': symbol},
      });

  Object explore(int id, String root, Map<String, Object?> arguments) =>
      request(id, 'tools/call', {
        'name': exploreToolName,
        'arguments': {'packageRoot': root, ...arguments},
      });

  test('session cache reuses facts, refreshes edits and cleans up', () async {
    final source = writeSource(directory.path, 'class Foo {}');
    Stream<Object?> messages() async* {
      yield request(1, 'ping');
      expect(scratch, isEmpty);
      yield query(2, directory.path);
      final facts = File(p.join(scratch.single.path, 'package-0/facts.json'));
      expect(facts.existsSync(), isTrue);
      final saved = facts.readAsStringSync();
      final timestamp = DateTime(2000);
      facts.setLastModifiedSync(timestamp);
      yield query(3, directory.path);
      expect(facts.readAsStringSync(), saved);
      expect(facts.lastModifiedSync(), timestamp);
      source.writeAsStringSync('class Bar {}');
      yield query(4, directory.path);
      yield query(5, directory.path, 'Bar');
    }

    final responses = await exchangeDefault(
      messages(),
      createCacheDirectory: createCache,
    );
    expect(textOf(responses[1]), startsWith('exitCode: 0\n'));
    expect(responses[1]['result'], responses[2]['result']);
    expect(textOf(responses[3]), startsWith('exitCode: 64\n'));
    expect(textOf(responses[4]), startsWith('exitCode: 0\n'));
    expect(scratch.single.existsSync(), isFalse);
    expect(diagnostics.toString(), isEmpty);
  });

  test('cache creation failure falls back to full analysis', () async {
    writeSource(directory.path, 'class Foo {}');
    final responses = await exchangeDefault(
      Stream.fromIterable([request(1, 'ping'), query(2, directory.path)]),
      createCacheDirectory: () async {
        throw const FileSystemException('cache unavailable');
      },
    );
    expect(textOf(responses[1]), startsWith('exitCode: 0\n'));
    expect(diagnostics.toString(), contains('temporary cache unavailable'));
  });

  test('cache write failure falls back without changing the result', () async {
    final source = writeSource(directory.path, 'class Foo {}');
    Stream<Object?> messages() async* {
      yield query(1, directory.path);
      final facts = File(p.join(scratch.single.path, 'package-0/facts.json'));
      facts.deleteSync();
      Directory(facts.path).createSync();
      source.writeAsStringSync('class Foo {}\nclass Bar {}');
      yield query(2, directory.path, 'Bar');
      yield query(3, directory.path, 'Bar');
    }

    final responses = await exchangeDefault(
      messages(),
      createCacheDirectory: createCache,
    );
    expect(textOf(responses[1]), startsWith('exitCode: 0\n'));
    expect(responses[1]['result'], responses[2]['result']);
    expect(diagnostics.toString(), contains('temporary cache unavailable'));
    expect(diagnostics.toString(), isNot(contains(scratch.single.path)));
    expect(scratch.single.existsSync(), isFalse);
  });

  test(
    'injected indexer is called each time without creating a cache',
    () async {
      var calls = 0;
      final responses = await exchangeDefault(
        Stream.fromIterable([
          query(1, directory.path),
          query(2, directory.path),
        ]),
        createCacheDirectory: () async => throw StateError('must stay lazy'),
        indexPackage: (_) async {
          calls++;
          return indexed;
        },
      );
      expect(calls, 2);
      expect(responses[0]['result'], responses[1]['result']);
      expect(textOf(responses[0]), startsWith('exitCode: 0\n'));
      expect(diagnostics.toString(), isEmpty);
    },
  );
  test('separate packageRoots get isolated cache directories', () async {
    final other = Directory(p.join(directory.path, 'other'))
      ..createSync(recursive: true);
    writeSource(directory.path, 'class Foo {}');
    writeSource(other.path, 'class Bar {}');
    Stream<Object?> messages() async* {
      yield query(1, directory.path);
      final first = File(p.join(scratch.single.path, 'package-0/facts.json'));
      final saved = first.readAsStringSync();
      yield query(2, other.path, 'Bar');
      expect(first.readAsStringSync(), saved);
      expect(
        File(p.join(scratch.single.path, 'package-1/facts.json')).existsSync(),
        isTrue,
      );
      yield query(3, directory.path, 'Bar');
      yield query(4, other.path, 'Foo');
    }

    final responses = await exchangeDefault(
      messages(),
      createCacheDirectory: createCache,
    );
    expect(textOf(responses[0]), startsWith('exitCode: 0\n'));
    expect(textOf(responses[1]), startsWith('exitCode: 0\n'));
    expect(textOf(responses[2]), startsWith('exitCode: 64\n'));
    expect(textOf(responses[3]), startsWith('exitCode: 64\n'));
    expect(scratch.single.existsSync(), isFalse);
  });

  test('abnormal server exit still deletes the cache directory', () async {
    writeSource(directory.path, 'class Foo {}');
    Stream<Object?> messages() async* {
      yield query(1, directory.path);
      expect(scratch.single.existsSync(), isTrue);
      throw const FileSystemException('client hung up');
    }

    await expectLater(
      exchangeDefault(messages(), createCacheDirectory: createCache),
      throwsA(isA<FileSystemException>()),
    );
    expect(scratch.single.existsSync(), isFalse);
  });

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

  test('tools/list exposes the read-only tools with schemas', () async {
    final responses = await exchange([request(2, 'tools/list')]);

    final tools = ((responses.single['result'] as Map)['tools'] as List)
        .cast<Map<String, Object?>>();
    expect(tools.map((tool) => tool['name']).toList(), [
      exploreToolName,
      impactToolName,
      dependencyToolName,
      verifyToolName,
      'runtime_query',
    ]);
    for (final tool in tools) {
      final schema = tool['inputSchema'] as Map<String, Object?>;
      expect(schema['type'], 'object');
      expect((schema['required'] as List), contains('packageRoot'));
    }
  });

  test('runtime_query answers static facts and never executes code', () async {
    File(p.join(directory.path, 'lib', 'env.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        "import 'dart:io';\n"
        "String? token() => Platform.environment['MCP_RUNTIME_TOKEN'];\n",
      );

    final responses = await exchange([
      request(80, 'tools/call', {
        'name': 'runtime_query',
        'arguments': {'packageRoot': directory.path},
      }),
      request(81, 'tools/call', {
        'name': 'runtime_query',
        'arguments': {'packageRoot': directory.path, 'execute': true},
      }),
      request(82, 'tools/call', {
        'name': 'runtime_query',
        'arguments': {'packageRoot': directory.path, 'env': 'A=B'},
      }),
    ]);

    final result = responses[0]['result'] as Map<String, Object?>;
    expect(result['isError'], isFalse);
    final text =
        ((result['content'] as List)
                .cast<Map<String, Object?>>()
                .single['text'])
            as String;
    expect(text, startsWith('exitCode: 0'));
    final report =
        jsonDecode(text.substring(text.indexOf('\n'))) as Map<String, Object?>;
    expect(report['version'], 1);
    expect(
      ((report['detected'] as Map)['env'] as List).single['name'],
      'MCP_RUNTIME_TOKEN',
    );
    expect(report['execution'], isNull);
    expect(report['verified'], {'present': [], 'defaulted': [], 'missing': []});
    expect(report['unverified'], isEmpty);
    final cliOutput = StringBuffer();
    final cliError = StringBuffer();
    final status = await runDartograph(
      ['runtime', '--no-verify', '--format', 'json', directory.path],
      output: cliOutput,
      error: cliError,
    );
    expect(text, 'exitCode: $status\n$cliOutput');
    expect(cliError.toString(), isEmpty);
    final rejected = responses[1]['result'] as Map<String, Object?>;
    expect(rejected['isError'], isTrue);
    expect(
      ((rejected['content'] as List).single as Map)['text'],
      contains('Unsupported option'),
    );
    final rejectedEnv = responses[2]['result'] as Map<String, Object?>;
    expect(rejectedEnv['isError'], isTrue);
    expect(
      ((rejectedEnv['content'] as List).single as Map)['text'],
      contains('Unsupported option'),
    );
  });

  test(
    'runtime_query rejects all non-static options and invalid limits',
    () async {
      final invalid = <Map<String, Object?>>[
        for (final key in [
          'execute',
          '--execute',
          'verify',
          'noVerify',
          'env',
          'dartDefine',
          'dart-define',
          'format',
          'record',
          'failOn',
          'incremental',
          'kinds',
          'statuses',
        ])
          {key: 'private-input'},
        for (final limit in [0, -1, '1', 1.5, true, null]) {'limit': limit},
      ];
      final responses = await exchangeDefault(
        Stream.fromIterable([
          for (var index = 0; index < invalid.length; index++)
            request(index, 'tools/call', {
              'name': 'runtime_query',
              'arguments': {'packageRoot': directory.path, ...invalid[index]},
            }),
        ]),
        createCacheDirectory: () async => throw StateError('must stay lazy'),
      );
      for (final response in responses) {
        expect((response['result'] as Map)['isError'], isTrue);
        expect(textOf(response), startsWith('Invalid arguments:'));
        expect(textOf(response), isNot(contains('private-input')));
      }
      expect(diagnostics.toString(), isEmpty);
    },
  );

  test(
    'runtime_query limits static facts without creating an index cache',
    () async {
      writeSource(
        directory.path,
        "import 'dart:io';\n"
        "String? first() => Platform.environment['FIRST'];\n"
        "String? second() => Platform.environment['SECOND'];\n",
      );
      final responses = await exchangeDefault(
        Stream.fromIterable([
          request(1, 'tools/call', {
            'name': 'runtime_query',
            'arguments': {'packageRoot': directory.path, 'limit': 1},
          }),
        ]),
        createCacheDirectory: createCache,
      );
      final text = textOf(responses.single);
      expect(text, startsWith('exitCode: 0\n'));
      final report = jsonDecode(text.substring(text.indexOf('\n'))) as Map;
      expect((report['detected'] as Map)['env'], hasLength(1));
      expect((report['truncated'] as Map)['detected'], 1);
      expect(report['execution'], isNull);
      expect(scratch, isEmpty);
    },
  );

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

  test(
    'dependency_query withSource returns declaration source lines',
    () async {
      File(p.join(directory.path, 'lib/a.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('class Foo {\n  int x = 1;\n}\n');
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
        ..addNode(
          GraphNode(
            id: 'project:lib/a.dart::Foo',
            sourceUri: 'project:lib/a.dart',
            line: 1,
          ),
        );
      final local = AnalyzerGraphResult(graph: graph, limitations: const []);
      final responses = await exchangeDefault(
        Stream.fromIterable([
          request(1, 'tools/call', {
            'name': dependencyToolName,
            'arguments': {
              'packageRoot': directory.path,
              'symbol': 'Foo',
              'withSource': true,
              'sourceContext': 1,
            },
          }),
        ]),
        indexPackage: (_) async => local,
      );
      final text = textOf(responses[0]);
      final document =
          jsonDecode(text.substring(text.indexOf('\n') + 1))
              as Map<String, Object?>;
      final subject =
          (document['result'] as Map<String, Object?>)['subject']
              as Map<String, Object?>;
      // line 1에서 위로는 더 갈 수 없으므로 아래 줄만 넓어진다.
      expect(subject['source'], [
        {'line': 1, 'text': 'class Foo {'},
        {'line': 2, 'text': '  int x = 1;'},
      ]);
    },
  );

  test('dependency_query rejects sourceContext without withSource', () async {
    final responses = await exchange([
      request(1, 'tools/call', {
        'name': dependencyToolName,
        'arguments': {
          'packageRoot': directory.path,
          'symbol': 'Foo',
          'sourceContext': 1,
        },
      }),
    ]);
    expect(textOf(responses[0]), contains('sourceContext requires withSource'));
  });

  test(
    'dartograph_explore routes symbol questions with source by default',
    () async {
      File(p.join(directory.path, 'lib/a.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('class Foo {\n  int x = 1;\n}\n');
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'project:lib/a.dart', isLibrary: true))
        ..addNode(
          GraphNode(
            id: 'project:lib/a.dart::Foo',
            sourceUri: 'project:lib/a.dart',
            line: 1,
          ),
        );
      final local = AnalyzerGraphResult(graph: graph, limitations: const []);
      final responses = await exchangeDefault(
        Stream.fromIterable([
          explore(1, directory.path, {'symbol': 'Foo'}),
          explore(2, directory.path, {'symbol': 'Foo', 'withSource': false}),
        ]),
        indexPackage: (_) async => local,
      );

      // 통합 진입점은 소스+근거 한 응답이 기본이라 withSource가 켜져 있다.
      const prefix = 'routed: dependency_query\nexitCode: 0\n';
      final text = textOf(responses[0]);
      expect(text, startsWith(prefix));
      final document =
          jsonDecode(text.substring(prefix.length)) as Map<String, Object?>;
      final subject =
          (document['result'] as Map<String, Object?>)['subject']
              as Map<String, Object?>;
      expect(subject['source'], isNotNull);
      // sourceContext 기본 3이라 파일 끝까지 넓어진다.
      expect((subject['source'] as List).map((line) => (line as Map)['line']), [
        1,
        2,
        3,
      ]);
      // 명시적 withSource: false는 기본값을 덮어쓴다.
      final off = textOf(responses[1]);
      expect(off, startsWith('routed: dependency_query\n'));
      expect(off, isNot(contains('"source"')));
    },
  );

  test('dartograph_explore routes impact and command questions', () async {
    final responses = await exchange([
      explore(1, directory.path, {'impactSymbol': 'project:lib/a.dart::Foo'}),
      explore(2, directory.path, {
        'changed': ['lib/a.dart'],
      }),
      explore(3, directory.path, {'command': 'dead'}),
      explore(4, directory.path, {'command': 'runtime', 'limit': 5}),
    ]);

    expect(
      textOf(responses[0]),
      startsWith('routed: impact_query\nexitCode: 0\n'),
    );
    expect(
      textOf(responses[1]),
      startsWith('routed: impact_query\nexitCode: 0\n'),
    );
    expect(textOf(responses[2]), startsWith('routed: verify_run\nexitCode: '));
    final runtimeText = textOf(responses[3]);
    expect(runtimeText, startsWith('routed: runtime_query\nexitCode: 0\n'));
    final report =
        jsonDecode(runtimeText.substring(runtimeText.indexOf('{')))
            as Map<String, Object?>;
    expect(report['version'], 1);
  });

  test(
    'dartograph_explore answers a shape menu when no intent is given',
    () async {
      final responses = await exchange([
        explore(1, directory.path, const {}),
        explore(2, directory.path, {'depth': 2}),
      ]);

      for (final response in responses) {
        final result = response['result'] as Map<String, Object?>;
        expect(result['isError'], isFalse);
        final text = textOf(response);
        expect(text, startsWith('routed: help\n'));
        expect(text, contains('symbol'));
        expect(text, contains('impactSymbol'));
        expect(text, contains('command'));
      }
    },
  );

  test(
    'dartograph_explore rejects mixed or ambiguous question shapes',
    () async {
      final responses = await exchange([
        // symbol + impactSymbol — 두 질문 형태가 섞였다.
        explore(1, directory.path, {
          'symbol': 'Foo',
          'impactSymbol': 'project:lib/a.dart::Foo',
        }),
        // since + changed — impact seed는 하나만 허용한다.
        explore(2, directory.path, {
          'since': 'HEAD',
          'changed': ['lib/a.dart'],
        }),
        // command + changed — dead는 변경 경로 인자가 없다.
        explore(3, directory.path, {
          'command': 'dead',
          'changed': ['lib/a.dart'],
        }),
        // command + symbol — 검증 경로에 심볼 인자는 의미가 없다.
        explore(4, directory.path, {'command': 'deps', 'symbol': 'Foo'}),
        // runtime + symbol — runtime 경로도 마찬가지다.
        explore(5, directory.path, {'command': 'runtime', 'symbol': 'Foo'}),
      ]);

      expect(textOf(responses[0]), contains('cannot combine'));
      expect(
        textOf(responses[1]),
        contains('exactly one of since, changed, or impactSymbol'),
      );
      expect(
        textOf(responses[2]),
        contains('cannot combine changed with command'),
      );
      expect(
        textOf(responses[3]),
        contains('cannot combine symbol with command'),
      );
      expect(
        textOf(responses[4]),
        contains('cannot combine symbol with command "runtime"'),
      );
      for (final response in responses) {
        expect((response['result'] as Map)['isError'], isTrue);
      }
    },
  );

  test(
    'dartograph_explore forwards per-path modifiers and their validation',
    () async {
      final responses = await exchange([
        // closedApp은 dead 전용 — 경로별 검증이 그대로 적용된다.
        explore(1, directory.path, {'command': 'cycles', 'closedApp': true}),
        // command dead + since는 dead --since로 유효한 조합이다.
        explore(2, directory.path, {'command': 'dead', 'since': 'HEAD~1'}),
      ]);

      expect(textOf(responses[0]), contains('closedApp is only valid'));
      // dead --since는 git 저장소가 아닌 임시 디렉터리에서 실패하지만 인자
      // 검증은 통과해야 한다 — 라우팅 표지만 확인한다.
      expect(textOf(responses[1]), startsWith('routed: verify_run\n'));
    },
  );

  test(
    'DARTOGRAPH_MCP_LEGACY_TOOLS hides legacy tools but keeps them callable',
    () async {
      final output = StringBuffer();
      await runMcpServer(
        input: Stream.fromIterable(
          [
            request(1, 'tools/list'),
            explore(2, directory.path, {'symbol': 'project:lib/a.dart'}),
            query(3, directory.path, 'project:lib/a.dart'),
          ].map(jsonEncode),
        ),
        output: output,
        error: diagnostics,
        indexPackage: (_) async => indexed,
        allowedRootBase: Directory.systemTemp.path,
        environment: {legacyToolsEnvName: '0'},
      );

      final responses = output
          .toString()
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map<String, Object?>)
          .toList();
      final tools = ((responses[0]['result'] as Map)['tools'] as List)
          .cast<Map<String, Object?>>();
      expect(tools.map((tool) => tool['name']).toList(), [exploreToolName]);
      // 목록에서 숨겨진 레거시 도구도 tools/call은 계속 받는다.
      expect((responses[1]['result'] as Map)['isError'], isFalse);
      expect((responses[2]['result'] as Map)['isError'], isFalse);
    },
  );
}
