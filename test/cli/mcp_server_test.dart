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
      // 호스트 환경 변수(DARTOGRAPH_MCP_LEGACY_TOOLS 등)가 테스트 결과를
      // 바꾸지 않게 빈 환경을 주입한다.
      environment: const {},
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
      environment: const {},
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

  test('session dup reuses the token facts that other tools cached', () async {
    // 이름만 다른 두 사본이다(fixtures/duplication과 같은 구조).
    for (final (name, input, limit) in const [
      ('alpha', 'input', 'limit'),
      ('beta', 'value', 'cap'),
    ]) {
      File(p.join(directory.path, 'lib', '$name.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'int normalize$name(int $input, int $limit) {\n'
          '  if ($input <= 0) {\n    return 0;\n  }\n'
          '  var result = 0;\n'
          '  for (var i = 0; i < $input; i++) {\n'
          '    result += i * 2;\n'
          '    if (result > $limit) {\n      result = result - $limit;\n    }\n'
          '  }\n'
          '  while (result > 10) {\n    result = result - 7;\n  }\n'
          '  return result;\n}\n',
        );
    }
    final cliOutput = StringBuffer();
    final cliStatus = await runDartograph(
      ['dup', '--format', 'json', '--min-tokens', '20', directory.path],
      output: cliOutput,
      error: StringBuffer(),
      userCacheEnvironment: const {},
    );
    expect(cliStatus, ExitStatus.findings.code);
    Object dup(int id) => request(id, 'tools/call', {
      'name': verifyToolName,
      'arguments': {
        'packageRoot': directory.path,
        'command': 'dup',
        'format': 'json',
        'minTokens': 20,
      },
    });
    Stream<Object?> messages() async* {
      yield query(1, directory.path, 'normalizealpha');
      // dup이 아닌 도구가 모든 파일을 해석하며 토큰 사실을 따로 저장해 둔다.
      final tokens = File(p.join(scratch.single.path, 'package-0/tokens.json'));
      expect(tokens.existsSync(), isTrue);
      final saved = tokens.readAsStringSync();
      yield dup(2);
      expect(tokens.readAsStringSync(), saved);
      yield dup(3);
    }

    final responses = await exchangeDefault(
      messages(),
      createCacheDirectory: createCache,
    );
    expect(textOf(responses[1]), 'exitCode: $cliStatus\n$cliOutput');
    expect(responses[2]['result'], responses[1]['result']);
    expect(diagnostics.toString(), isEmpty);
  });

  test('a stale package_config entry keeps the CLI exit code', () async {
    writeSource(directory.path, 'class Foo {}');
    File(
      p.join(directory.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: app\nenvironment:\n  sdk: ^3.11.0\n');
    // 지운 path 의존처럼 rootUri 디렉터리가 사라진 항목이다. 세션은 항상
    // 증분 캐시를 쓰는데, 그 키 열거만 이 항목에서 실패해 종료 2가 됐다.
    File(p.join(directory.path, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'gone',
              'rootUri': '${p.toUri(p.join(directory.path, 'gone'))}/',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
    final cli = await runDartograph(
      ['dead', '--format', 'json', directory.path],
      output: StringBuffer(),
      error: StringBuffer(),
    );

    final responses = await exchangeDefault(
      Stream.fromIterable([
        request(1, 'tools/call', {
          'name': verifyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'command': 'dead',
            'format': 'json',
          },
        }),
      ]),
      createCacheDirectory: createCache,
    );

    // 미참조 Foo는 dead finding이다(종료 1).
    expect(cli, 1);
    expect(textOf(responses.single), startsWith('exitCode: $cli\n'));
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

  test(
    'option-shaped tool values are rejected before they reach the CLI',
    () async {
      writeSource(directory.path, 'class Foo {}');
      Object tool(int id, String name, Map<String, Object?> arguments) =>
          request(id, 'tools/call', {
            'name': name,
            'arguments': {'packageRoot': directory.path, ...arguments},
          });
      final responses = await exchange([
        // 값 자리의 `--record`는 뒤따르는 packageRoot를 원장 디렉터리로 삼아
        // 읽기 전용 도구가 분석 대상 저장소에 ledger.jsonl을 썼다.
        query(1, directory.path, '--record'),
        tool(2, verifyToolName, {
          'command': 'dead',
          'kinds': ['--record'],
        }),
        tool(3, verifyToolName, {'command': 'dead', 'since': '--record'}),
        tool(4, verifyToolName, {'command': 'dead', 'baseline': '--record'}),
        tool(5, verifyToolName, {'command': 'rules', 'config': '--record'}),
        tool(6, impactToolName, {'since': '--incremental'}),
        tool(7, impactToolName, {'symbol': '--workspace'}),
        tool(8, dependencyToolName, {
          'batch': ['Foo', '-x'],
        }),
        tool(9, dependencyToolName, {'symbol': 'Foo', 'baseline': '--record'}),
        explore(10, directory.path, {'impactSymbol': '--record'}),
        explore(11, directory.path, {
          'command': 'dead',
          'kinds': ['declaration', '-x'],
        }),
      ]);

      expect(responses, hasLength(11));
      for (final response in responses) {
        final result = response['result'] as Map<String, Object?>;
        expect(result['isError'], isTrue);
        // CLI usage(64)가 아니라 MCP 계층의 인자 오류로 거부된다.
        expect(textOf(response), contains('Invalid arguments: '));
        expect(textOf(response), isNot(contains('exitCode:')));
      }
      expect(
        File(p.join(directory.path, 'ledger.jsonl')).existsSync(),
        isFalse,
      );
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
      expect((schema['properties'] as Map).keys, contains('workspace'));
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
      contains('exactly one of since, changed, symbol, or beforeRoot'),
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

  test('verify_run runs deps and dup with the github-actions format', () async {
    // 도구 스키마가 deps·dup에 광고하는 형식이다. CLI가 이 철자를 거부하면
    // 도구가 스스로 허용한 값이 usage(64)·isError가 된다.
    final responses = await exchange([
      for (final (id, command) in [(10, 'deps'), (11, 'dup')])
        request(id, 'tools/call', {
          'name': verifyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'command': command,
            'format': 'github-actions',
          },
        }),
    ]);

    expect(responses, hasLength(2));
    for (final response in responses) {
      final result = response['result'] as Map<String, Object?>;
      expect(result['isError'], isFalse, reason: textOf(response));
      expect(textOf(response), startsWith('exitCode: 0\n::'));
    }
  });

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
    'config and baseline paths must be regular files inside the boundary',
    () async {
      // exchangeDefault의 경계는 directory다. outside는 그 밖의 임시 디렉터리다.
      final outside = await Directory.systemTemp.createTemp('mcp-outside.');
      addTearDown(() => outside.delete(recursive: true));
      // 경계 밖 YAML의 첫 최상위 키가 rules 진단에 실려 돌아왔다.
      final secret = File(p.join(outside.path, 'layers.yaml'))
        ..writeAsStringSync('outside_only_key: 1\n');
      final foreignBaseline = File(p.join(outside.path, 'baseline.json'))
        ..writeAsStringSync(
          '{"fingerprints":[],"formatVersion":1,"tool":"dartograph"}\n',
        );
      final escape = Link(p.join(directory.path, 'escape.yaml'))
        ..createSync(secret.path);
      final layers = File(p.join(directory.path, 'layers.yaml'))
        ..writeAsStringSync(
          'layers:\n  - name: first\n    match: [x]\nrules: []\n',
        );
      final alias = Link(p.join(directory.path, 'alias.yaml'))
        ..createSync(layers.path);
      // 미참조 Bar 선언 finding 하나를 억제하는 경계 안 baseline이다.
      final baseline = File(p.join(directory.path, 'baseline.json'))
        ..writeAsStringSync(
          r'{"fingerprints":["{\"id\":\"project:lib/b.dart::Bar\",'
          r'\"kind\":\"declaration\"}"],"formatVersion":1,'
          '"tool":"dartograph"}\n',
        );
      Object verify(int id, Map<String, Object?> arguments) =>
          request(id, 'tools/call', {
            'name': verifyToolName,
            'arguments': {'packageRoot': directory.path, ...arguments},
          });

      final responses = await exchangeDefault(
        Stream.fromIterable([
          verify(1, {'command': 'rules', 'config': secret.path}),
          verify(2, {
            'command': 'rules',
            'config': p.join(outside.path, 'missing.yaml'),
          }),
          verify(3, {'command': 'rules', 'config': escape.path}),
          verify(4, {
            'command': 'dead',
            'format': 'json',
            'baseline': foreignBaseline.path,
          }),
          request(5, 'tools/call', {
            'name': dependencyToolName,
            'arguments': {
              'packageRoot': directory.path,
              'symbol': 'Foo',
              'baseline': foreignBaseline.path,
            },
          }),
          explore(6, directory.path, {
            'symbol': 'Foo',
            'baseline': foreignBaseline.path,
          }),
          explore(7, directory.path, {
            'command': 'dead',
            'format': 'json',
            'baseline': foreignBaseline.path,
          }),
          // 경계 안의 정규 파일은 링크·서버 작업 디렉터리 기준 상대 경로로도
          // 받는다.
          verify(8, {'command': 'rules', 'config': layers.path}),
          verify(9, {'command': 'rules', 'config': alias.path}),
          verify(10, {'command': 'rules', 'config': p.relative(layers.path)}),
          verify(11, {
            'command': 'dead',
            'format': 'json',
            'baseline': baseline.path,
          }),
          verify(12, {'command': 'dead', 'format': 'json'}),
        ]),
        indexPackage: (_) async => indexed,
      );

      expect(responses, hasLength(12));
      for (final response in responses.take(7)) {
        expect((response['result'] as Map)['isError'], isTrue);
        expect(textOf(response), contains('Invalid arguments: '));
        expect(textOf(response), isNot(contains('exitCode:')));
        expect(textOf(response), isNot(contains('outside_only_key')));
      }
      // 부재·경계 밖·탈출 링크가 같은 문구라 경계 밖 파일의 존재가 새지 않는다.
      expect(textOf(responses[1]), textOf(responses[0]));
      expect(textOf(responses[2]), textOf(responses[0]));
      expect(textOf(responses[7]), startsWith('exitCode: 0\n'));
      expect(responses[8]['result'], responses[7]['result']);
      expect(responses[9]['result'], responses[7]['result']);
      // 해석된 경계 안 baseline이 실제로 읽혀 finding 하나를 억제한다.
      expect(textOf(responses[10]), startsWith('exitCode: 1\n'));
      expect(textOf(responses[10]), contains('"suppressedCount":1'));
      expect(textOf(responses[11]), startsWith('exitCode: 1\n'));
      expect(textOf(responses[11]), contains('"suppressedCount":0'));
    },
    skip: Platform.isWindows,
  );

  test(
    'FIFO and device paths for config or baseline do not block the server',
    () async {
      final fifo = p.join(directory.path, 'layers.pipe');
      final mkfifo = await Process.run('mkfifo', [fifo]);
      expect(mkfifo.exitCode, 0, reason: mkfifo.stderr as String);
      final device = Link(p.join(directory.path, 'baseline.json'))
        ..createSync('/dev/null');
      Object verify(int id, Map<String, Object?> arguments) =>
          request(id, 'tools/call', {
            'name': verifyToolName,
            'arguments': {'packageRoot': directory.path, ...arguments},
          });

      // 서버는 요청을 차례로 처리한다. 쓰는 쪽이 없는 FIFO를 읽으려 들면 이어지는
      // ping까지 영구히 막혔다.
      final responses = await exchangeDefault(
        Stream.fromIterable([
          verify(1, {'command': 'rules', 'config': fifo}),
          verify(2, {'command': 'dead', 'format': 'json', 'baseline': fifo}),
          request(3, 'tools/call', {
            'name': dependencyToolName,
            'arguments': {
              'packageRoot': directory.path,
              'symbol': 'Foo',
              'baseline': fifo,
            },
          }),
          verify(4, {
            'command': 'dead',
            'format': 'json',
            'baseline': device.path,
          }),
          request(5, 'ping'),
        ]),
        indexPackage: (_) async => indexed,
      );

      expect(responses, hasLength(5));
      for (final response in responses.take(4)) {
        expect((response['result'] as Map)['isError'], isTrue);
        expect(textOf(response), startsWith('Invalid arguments: '));
      }
      expect(responses.last['result'], <String, Object?>{});
    },
    skip: Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 30)),
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
      // 초과 메시지는 전체를 거부하고 Invalid JSON으로 답한다.
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
          explore(3, directory.path, {'symbol': 'Foo', 'sourceContext': 0}),
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
      // 명시적 sourceContext: 0도 기본 3을 덮어써 선언 줄만 온다.
      final zero = textOf(responses[2]);
      expect(zero, startsWith(prefix));
      final zeroDocument =
          jsonDecode(zero.substring(prefix.length)) as Map<String, Object?>;
      final zeroSubject =
          (zeroDocument['result'] as Map<String, Object?>)['subject']
              as Map<String, Object?>;
      expect(zeroSubject['source'], [
        {'line': 1, 'text': 'class Foo {'},
      ]);
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
      // limit 없는 runtime 호출 — 재배치된 인자에 null이 새면 안 된다.
      explore(5, directory.path, {'command': 'runtime'}),
      explore(6, directory.path, {
        'batch': ['project:lib/a.dart'],
      }),
      // since는 command 없이 오면 impact seed다.
      explore(7, directory.path, {'since': 'HEAD~1'}),
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
    for (final response in responses.sublist(3, 5)) {
      final runtimeText = textOf(response);
      expect(runtimeText, startsWith('routed: runtime_query\nexitCode: 0\n'));
      final report =
          jsonDecode(runtimeText.substring(runtimeText.indexOf('{')))
              as Map<String, Object?>;
      expect(report['version'], 1);
    }
    expect(
      textOf(responses[5]),
      startsWith('routed: dependency_query\nexitCode: 0\n'),
    );
    // 임시 디렉터리는 git 저장소가 아니므로 since 해석은 실패할 수 있다 —
    // 라우팅 표지만 확인한다.
    expect(textOf(responses[6]), startsWith('routed: impact_query\n'));
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
      // 형태를 이루지 못한 인자는 메뉴에 함께 적힌다 — 오타(`symbols` 같은)와
      // 빈 호출이 구분된다.
      expect(
        textOf(responses[0]),
        isNot(contains('arguments received without a question shape:')),
      );
      expect(
        textOf(responses[1]),
        contains('arguments received without a question shape: depth'),
      );
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
        // runtime + 수정자 — limit만 허용된다.
        explore(6, directory.path, {'command': 'runtime', 'strict': true}),
        // 여러 stray는 정렬돼 함께 보고된다.
        explore(7, directory.path, {
          'command': 'dead',
          'changed': ['lib/a.dart'],
          'symbol': 'Foo',
        }),
      ]);

      expect(textOf(responses[0]), contains('cannot combine'));
      expect(
        textOf(responses[1]),
        contains('exactly one of since, changed, impactSymbol, or beforeRoot'),
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
      expect(
        textOf(responses[5]),
        contains('cannot combine strict with command "runtime"'),
      );
      expect(
        textOf(responses[6]),
        contains('cannot combine changed, symbol with command'),
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

  test('DARTOGRAPH_MCP_LEGACY_TOOLS gates only on 0 or false', () async {
    Future<List<String>> listedToolNames(String value) async {
      final output = StringBuffer();
      await runMcpServer(
        input: Stream.fromIterable([jsonEncode(request(1, 'tools/list'))]),
        output: output,
        error: diagnostics,
        indexPackage: (_) async => indexed,
        allowedRootBase: Directory.systemTemp.path,
        environment: {legacyToolsEnvName: value},
      );
      final tools =
          (((jsonDecode(output.toString().trim()) as Map)['result']
                      as Map)['tools']
                  as List)
              .cast<Map<String, Object?>>();
      return tools.map((tool) => tool['name'] as String).toList();
    }

    // 끄는 값은 '0'·'false'뿐 — 대소문자 무관하고 그 외 값은 전부 광고한다.
    expect(await listedToolNames('false'), [exploreToolName]);
    expect(await listedToolNames('FALSE'), [exploreToolName]);
    expect(await listedToolNames('1'), [
      exploreToolName,
      impactToolName,
      dependencyToolName,
      verifyToolName,
      'runtime_query',
    ]);
  });

  test(
    'tools validate the workspace flag and forward --workspace to the CLI',
    () async {
      writeSource(directory.path, 'class Foo {}');
      final responses = await exchange([
        // 불리언이 아닌 workspace는 모든 도구에서 인자 오류다.
        request(1, 'tools/call', {
          'name': dependencyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'symbol': 'Foo',
            'workspace': 'yes',
          },
        }),
        request(2, 'tools/call', {
          'name': verifyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'command': 'cycles',
            'workspace': 'yes',
          },
        }),
        request(3, 'tools/call', {
          'name': impactToolName,
          'arguments': {
            'packageRoot': directory.path,
            'symbol': 'Foo',
            'workspace': 'yes',
          },
        }),
        request(4, 'tools/call', {
          'name': 'runtime_query',
          'arguments': {'packageRoot': directory.path, 'workspace': 'yes'},
        }),
        // workspace: true — 주입된 고정 색인 함수는 --workspace를 반영할 수
        // 없다. 조용히 단일 패키지 결과를 내지 않고 usage(64)로 거부돼야 한다
        // (실제 집계는 세션 색인 테스트가 CLI와 비교한다).
        request(5, 'tools/call', {
          'name': dependencyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'symbol': 'Foo',
            'workspace': true,
          },
        }),
        request(6, 'tools/call', {
          'name': verifyToolName,
          'arguments': {
            'packageRoot': directory.path,
            'command': 'cycles',
            'workspace': true,
          },
        }),
        // runtime은 indexPackage를 타지 않는다 — --workspace가 실제로
        // 전달돼야 workspace 없는 루트에서 분석 실패(exit 2)가 된다.
        request(7, 'tools/call', {
          'name': 'runtime_query',
          'arguments': {'packageRoot': directory.path, 'workspace': true},
        }),
        // 통합 진입점 — 형태별 허용 키와 재배치에 workspace가 포함된다.
        explore(8, directory.path, {'symbol': 'Foo', 'workspace': true}),
        explore(9, directory.path, {'command': 'cycles', 'workspace': true}),
        explore(10, directory.path, {'command': 'runtime', 'workspace': true}),
        explore(11, directory.path, {'command': 'runtime', 'workspace': 'yes'}),
      ]);

      for (var index = 0; index < 4; index++) {
        expect(
          textOf(responses[index]),
          contains('workspace must be a boolean'),
        );
      }
      expect(textOf(responses[4]), startsWith('exitCode: 64\n'));
      expect(textOf(responses[4]), contains('--workspace'));
      expect(textOf(responses[5]), startsWith('exitCode: 64\n'));
      expect(textOf(responses[6]), startsWith('exitCode: 2\n'));
      expect(
        textOf(responses[7]),
        startsWith('routed: dependency_query\nexitCode: 64\n'),
      );
      expect(
        textOf(responses[8]),
        startsWith('routed: verify_run\nexitCode: 64\n'),
      );
      expect(
        textOf(responses[9]),
        startsWith('routed: runtime_query\nexitCode: 2\n'),
      );
      expect(textOf(responses[10]), contains('workspace must be a boolean'));
    },
  );

  test(
    'session index aggregates workspace members like CLI --workspace',
    () async {
      // b가 a를 import하는 두 멤버 workspace다. a의 비공개 _Unused는 집계
      // 그래프에서만 미도달 finding이 되고, a의 변경은 집계해야 b에 닿는다.
      final workspaceRoot = p.join(directory.path, 'ws');
      void write(String path, String contents) =>
          File(p.join(workspaceRoot, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(contents);
      write(
        'pubspec.yaml',
        'name: ws_root\nenvironment:\n  sdk: ^3.8.0\n'
            'workspace:\n  - pkgs/a\n  - pkgs/b\n',
      );
      // 루트에도 소스가 있어야 집계하지 않은 실행도 세션 캐시에 사실을 쓴다.
      write('lib/ws_root.dart', 'class RootPackage {}\n');
      write(
        'pkgs/a/pubspec.yaml',
        'name: a\nenvironment:\n  sdk: ^3.8.0\nresolution: workspace\n',
      );
      write('pkgs/a/lib/a.dart', 'int helper() => 1;\n\nclass _Unused {}\n');
      write(
        'pkgs/b/pubspec.yaml',
        'name: b\nenvironment:\n  sdk: ^3.8.0\nresolution: workspace\n'
            'dependencies:\n  a:\n',
      );
      write(
        'pkgs/b/lib/b.dart',
        "import 'package:a/a.dart';\n\nint useHelper() => helper() + 1;\n",
      );
      final pubGet = await Process.run(Platform.resolvedExecutable, const [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: workspaceRoot);
      expect(pubGet.exitCode, 0, reason: '${pubGet.stderr}');
      // workspace를 선언하지 않은 루트다. CLI --workspace는 분석 실패(2)다.
      final plainRoot = p.join(directory.path, 'plain');
      writeSource(plainRoot, 'class Plain {}');
      File(p.join(plainRoot, 'pubspec.yaml')).writeAsStringSync('name: p\n');

      // CLI 기준값을 MCP 응답 본문 모양(exitCode 줄 + stdout, 실패면 stderr)
      // 으로 만든다. 사용자 캐시를 건드리지 않게 실행마다 증분 캐시를 둔다.
      final cliCaches = await Directory.systemTemp.createTemp('mcp-cli-cache.');
      addTearDown(() => cliCaches.delete(recursive: true));
      var cliRuns = 0;
      Future<String> cli(List<String> arguments) async {
        final output = StringBuffer();
        final error = StringBuffer();
        final status = await runDartograph(
          [
            arguments.first,
            '--incremental',
            p.join(cliCaches.path, 'run-${cliRuns++}'),
            ...arguments.skip(1),
          ],
          output: output,
          error: error,
        );
        final failed =
            status == ExitStatus.failure.code ||
            status == ExitStatus.usage.code;
        return 'exitCode: $status\n$output${failed ? error : ''}';
      }

      final changes = File(p.join(cliCaches.path, 'changes.json'))
        ..writeAsStringSync(jsonEncode(['pkgs/a/lib/a.dart']));
      final dead = await cli([
        'dead',
        '--workspace',
        '--format',
        'json',
        workspaceRoot,
      ]);
      final impact = await cli([
        'impact',
        '--changed',
        changes.path,
        '--workspace',
        '--format',
        'json',
        workspaceRoot,
      ]);
      final found = await cli([
        'query',
        'helper',
        '--workspace',
        workspaceRoot,
      ]);
      final single = await cli(['dead', '--format', 'json', workspaceRoot]);
      final plain = await cli([
        'dead',
        '--workspace',
        '--format',
        'json',
        plainRoot,
      ]);
      // 손으로 확인한 기대값이다. 집계 그래프만 멤버의 미도달 선언과 멤버
      // 사이 영향을 본다.
      expect(dead, startsWith('exitCode: 1\n'));
      expect(dead, contains('a.dart::_Unused'));
      expect(impact, startsWith('exitCode: 0\n'));
      expect(impact, contains('package:b/b.dart::useHelper'));
      expect(found, startsWith('exitCode: 0\n'));
      expect(single, startsWith('exitCode: 0\n'));
      expect(single, contains('workspace-members-not-indexed'));
      expect(plain, startsWith('exitCode: 2\n'));

      Object verifyDead(int id, String root, {bool? workspace}) =>
          request(id, 'tools/call', {
            'name': verifyToolName,
            'arguments': {
              'packageRoot': root,
              'command': 'dead',
              'format': 'json',
              'workspace': ?workspace,
            },
          });
      Stream<Object?> messages() async* {
        yield verifyDead(1, workspaceRoot, workspace: true);
        yield request(2, 'tools/call', {
          'name': impactToolName,
          'arguments': {
            'packageRoot': workspaceRoot,
            'changed': ['pkgs/a/lib/a.dart'],
            'workspace': true,
          },
        });
        yield request(3, 'tools/call', {
          'name': dependencyToolName,
          'arguments': {
            'packageRoot': workspaceRoot,
            'symbol': 'helper',
            'workspace': true,
          },
        });
        yield verifyDead(4, workspaceRoot);
        // 같은 루트라도 workspace 값마다 세션 캐시 하위 디렉터리가 따로다.
        for (final name in ['package-0', 'package-1']) {
          final facts = File(p.join(scratch.single.path, name, 'facts.json'));
          expect(facts.existsSync(), isTrue, reason: name);
        }
        yield verifyDead(5, plainRoot, workspace: true);
      }

      final responses = await exchangeDefault(
        messages(),
        createCacheDirectory: createCache,
      );
      expect(responses.map(textOf).toList(), [
        dead,
        impact,
        found,
        single,
        plain,
      ]);
      expect(diagnostics.toString(), isEmpty);
      expect(scratch.single.existsSync(), isFalse);

      // 캐시를 만들 수 없는 세션의 전체 해석 폴백도 workspace 값을 지킨다.
      final fallback = await exchangeDefault(
        Stream.fromIterable([verifyDead(1, workspaceRoot, workspace: true)]),
        createCacheDirectory: () async {
          throw const FileSystemException('cache unavailable');
        },
      );
      expect(textOf(fallback.single), dead);
      expect(diagnostics.toString(), contains('temporary cache unavailable'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
