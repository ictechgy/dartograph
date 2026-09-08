import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/analysis/baseline.dart';
import 'package:dartograph/src/analysis/reachability_analyzer.dart';
import 'package:dartograph/src/core/code_graph.dart';
import 'package:dartograph/src/core/graph_edge.dart';
import 'package:dartograph/src/core/graph_node.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

void main() {
  AnalyzerGraphResult indexed() {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'package:app/api.dart'))
      ..addNode(
        GraphNode(
          id: 'package:app/api.dart::Api',
          sourceUri: 'project:lib/api.dart',
          line: 1,
          column: 1,
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/main.dart::main',
          sourceUri: 'project:lib/main.dart',
          line: 1,
          column: 1,
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/api.dart::Api.fetch',
          sourceUri: 'project:lib/api.dart',
          line: 2,
          column: 3,
        ),
      )
      ..addNode(
        GraphNode(
          id: 'package:app/api.dart::Dead',
          sourceUri: 'project:lib/api.dart',
          line: 5,
          column: 1,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/main.dart::main',
          targetId: 'package:app/api.dart::Api',
          kind: EdgeKind.reference,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'package:app/api.dart::Api',
          targetId: 'package:app/api.dart::Api.fetch',
          kind: EdgeKind.member,
        ),
      );
    return AnalyzerGraphResult(
      graph: graph,
      limitations: const [AnalyzerLimitation.conditionalConfiguration],
      limitationDetails: const [
        'conditional-imports: 2 directive(s) use only the analyzer-selected configuration',
        'string-routes: 3 named route use(s) have no matching route table entry',
        'generated-code-staleness: 1 generated file(s) are older than their source',
      ],
      retentionRoots: const {
        'package:app/main.dart::main': RetentionReason.mainEntryPoint,
      },
    );
  }

  test(
    'query emits SymbolQueryDocument-compatible fields and limitations',
    () async {
      final output = StringBuffer();
      final status = await runDartograph(
        const ['query', 'Api', '.'],
        output: output,
        indexPackage: (_) async => indexed(),
      );

      expect(status, ExitStatus.success.code);
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(
        document.keys,
        containsAll(<String>[
          'status',
          'requested',
          'level',
          'limitations',
          'result',
          'candidates',
        ]),
      );
      expect(document['status'], 'found');
      expect(document['limitations'], hasLength(3));
      final result = document['result'] as Map<String, Object?>;
      expect(
        result.keys,
        containsAll(<String>[
          'subject',
          'reachability',
          'usedBy',
          'dependsOn',
          'members',
          'declaredIn',
          'truncated',
        ]),
      );
      expect((result['usedBy'] as List<Object?>), hasLength(1));
      expect(
        (result['reachability'] as Map<String, Object?>)['state'],
        'reachable',
      );
      expect((result['reachability'] as Map<String, Object?>)['path'], [
        'package:app/main.dart::main',
        'package:app/api.dart::Api',
      ]);
      expect((result['members'] as List<Object?>), hasLength(1));
    },
  );

  test('query resolves a member by its simple name', () async {
    final output = StringBuffer();
    expect(
      await runDartograph(
        const ['query', 'fetch', '.'],
        output: output,
        indexPackage: (_) async => indexed(),
      ),
      ExitStatus.success.code,
    );
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    expect(document['status'], 'found');
    expect(
      ((document['result'] as Map<String, Object?>)['subject']
          as Map<String, Object?>)['name'],
      'fetch',
    );
  });

  test('query reports an unreachable finding suppressed by baseline', () async {
    final directory = await Directory.systemTemp.createTemp(
      'dartograph-query-baseline-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final baseline = File('${directory.path}/baseline.json');
    await BaselineStore.write(
      Baseline.capture(const [
        DeadFinding(
          id: 'package:app/api.dart::Dead',
          kind: 'declaration',
          source: 'project:lib/api.dart',
          reason: 'unreachable from all retention roots',
          retentionRootsChecked: [],
        ),
      ]),
      baseline,
    );
    final output = StringBuffer();

    expect(
      await runDartograph(
        ['query', 'Dead', '--baseline', baseline.path, '.'],
        output: output,
        indexPackage: (_) async => indexed(),
      ),
      ExitStatus.success.code,
    );
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    final result = document['result'] as Map<String, Object?>;
    expect(
      (result['reachability'] as Map<String, Object?>)['suppressedByBaseline'],
      isTrue,
    );
  });

  test('query returns notFound with limitations and usage status', () async {
    final output = StringBuffer();
    final status = await runDartograph(
      const ['query', 'Missing', '.'],
      output: output,
      indexPackage: (_) async => indexed(),
    );

    expect(status, ExitStatus.usage.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    expect(document['status'], 'notFound');
    expect(document['limitations'], hasLength(3));
    expect(document['result'], isNull);
  });

  // Root→A→B→C 사용 체인. --depth/--limit이 CLI를 거쳐 이웃 순회에 닿는지
  // 관측 가능하게 하려면 2-hop 사슬이 필요하다(indexed()는 1-hop뿐).
  AnalyzerGraphResult chain() {
    final graph = CodeGraph()
      ..addNode(GraphNode(id: 'lib::Root'))
      ..addNode(GraphNode(id: 'lib::A'))
      ..addNode(GraphNode(id: 'lib::B'))
      ..addNode(GraphNode(id: 'lib::C'))
      ..addEdge(
        const GraphEdge(
          sourceId: 'lib::Root',
          targetId: 'lib::A',
          kind: EdgeKind.reference,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'lib::A',
          targetId: 'lib::B',
          kind: EdgeKind.call,
        ),
      )
      ..addEdge(
        const GraphEdge(
          sourceId: 'lib::B',
          targetId: 'lib::C',
          kind: EdgeKind.call,
        ),
      );
    return AnalyzerGraphResult(
      graph: graph,
      limitations: const [],
      retentionRoots: const {'lib::Root': RetentionReason.mainEntryPoint},
    );
  }

  List<Object?> dependsOnNames(Map<String, Object?> document) {
    final result = document['result'] as Map<String, Object?>;
    return (result['dependsOn'] as List)
        .map((n) => (n as Map)['qualifiedName'])
        .toList();
  }

  test('query --depth follows the usage chain further', () async {
    final shallow = StringBuffer();
    expect(
      await runDartograph(
        const ['query', 'A', '.'],
        output: shallow,
        indexPackage: (_) async => chain(),
      ),
      ExitStatus.success.code,
    );
    expect(
      dependsOnNames(jsonDecode(shallow.toString()) as Map<String, Object?>),
      ['lib::B'],
    );

    final deep = StringBuffer();
    expect(
      await runDartograph(
        const ['query', 'A', '--depth', '2', '.'],
        output: deep,
        indexPackage: (_) async => chain(),
      ),
      ExitStatus.success.code,
    );
    expect(
      dependsOnNames(jsonDecode(deep.toString()) as Map<String, Object?>),
      ['lib::B', 'lib::C'],
    );
  });

  test('query --limit caps a direction and reports truncation', () async {
    final output = StringBuffer();
    expect(
      await runDartograph(
        const ['query', 'A', '--depth', '2', '--limit', '1', '.'],
        output: output,
        indexPackage: (_) async => chain(),
      ),
      ExitStatus.success.code,
    );
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    expect(dependsOnNames(document), ['lib::B']);
    final truncated =
        (document['result'] as Map<String, Object?>)['truncated'] as Map;
    expect(truncated['dependsOn'], isTrue);
  });

  test('query --depth/--limit reach a batch request', () async {
    final directory = await Directory.systemTemp.createTemp('query-depth.');
    addTearDown(() => directory.delete(recursive: true));
    final requests = File('${directory.path}/requests.json');
    await requests.writeAsString('["A"]');
    final output = StringBuffer();
    expect(
      await runDartograph(
        ['query', '--batch', requests.path, '--depth', '2', '.'],
        output: output,
        indexPackage: (_) async => chain(),
      ),
      ExitStatus.success.code,
    );
    final results = (jsonDecode(output.toString()) as Map)['results'] as List;
    expect(dependsOnNames((results.single as Map).cast<String, Object?>()), [
      'lib::B',
      'lib::C',
    ]);
  });

  test('query rejects a depth or limit below one as a usage error', () async {
    for (final args in [
      const ['query', 'A', '--depth', '0', '.'],
      const ['query', 'A', '--limit', '0', '.'],
      const ['query', 'A', '--depth', '-1', '.'],
    ]) {
      var calls = 0;
      expect(
        await runDartograph(
          args,
          error: StringBuffer(),
          indexPackage: (_) async {
            calls++;
            return chain();
          },
        ),
        ExitStatus.usage.code,
        reason: args.join(' '),
      );
      expect(calls, 0, reason: '${args.join(' ')} must not index');
    }
  });

  test('query rejects a non-integer or missing depth value', () async {
    for (final args in [
      const ['query', 'A', '--depth', 'x', '.'],
      const ['query', 'A', '--depth'],
      const ['query', 'A', '--limit', '--depth', '2', '.'],
    ]) {
      expect(
        await runDartograph(
          args,
          error: StringBuffer(),
          indexPackage: (_) async => chain(),
        ),
        ExitStatus.usage.code,
        reason: args.join(' '),
      );
    }
  });

  test('skill prints Dart-specific safety rules', () async {
    final output = StringBuffer();
    expect(
      await runDartograph(const ['skill'], output: output),
      ExitStatus.success.code,
    );
    expect(output.toString(), contains('main functions may be multiple'));
    expect(output.toString(), contains('Confirm the actual build target'));
    expect(output.toString(), contains('state is not a deletion verdict'));
    expect(output.toString(), contains('limitations'));
    expect(output.toString(), contains('overrideContract'));
    expect(output.toString(), contains('publicApi'));
  });

  test('skill installs SKILL.md into an explicit directory', () async {
    final directory = await Directory.systemTemp.createTemp(
      'dartograph-skill-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final output = StringBuffer();

    expect(
      await runDartograph([
        'skill',
        '--install',
        directory.path,
      ], output: output),
      ExitStatus.success.code,
    );
    final installed = File('${directory.path}/dartograph/SKILL.md');
    expect(
      await installed.readAsString(),
      contains('Confirm the actual build target'),
    );

    await installed.writeAsString('customized');
    final errors = StringBuffer();
    expect(
      await runDartograph([
        'skill',
        '--install',
        directory.path,
      ], error: errors),
      ExitStatus.usage.code,
    );
    expect(await installed.readAsString(), 'customized');
    expect(errors.toString(), contains('--force'));

    expect(
      await runDartograph([
        'skill',
        '--install',
        directory.path,
        '--force',
      ], output: StringBuffer()),
      ExitStatus.success.code,
    );
    expect(
      await installed.readAsString(),
      contains('Confirm the actual build target'),
    );
  });

  test(
    'bridges emits isthmus-compatible MethodChannel facts and limitations',
    () async {
      final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/lib').create();
      await File('${root.path}/lib/channels.dart').writeAsString(r'''
import 'package:flutter/services.dart';

const name = 'dev.example/method';
final method = MethodChannel(name);
final events = EventChannel('dev.example/events');
final messages = BasicMessageChannel<String>('dev.example/messages', codec);
final dynamicChannel = MethodChannel('dev.example/$flavor');
final namedDynamically = MethodChannel(channelName);
final constantDeclaredLater = MethodChannel(laterName);
const laterName = 'dev.example/constant-later';
void callDeclaredLater() {
  declaredLater.invokeMethod('later');
}
final declaredLater = MethodChannel('dev.example/later');
void call(String operation) {
  method.invokeMethod('ping');
  method.invokeMethod(operation);
  namedDynamically.invokeMethod('dynamicChannelCall');
  constantDeclaredLater.invokeMethod('constantLater');
}
''');
      await File('${root.path}/lib/cross_file.dart').writeAsString('''
import 'package:flutter/services.dart';

void callExternal() {
  externalChannel.invokeMethod('crossFile');
}
''');
      await File(
        '${root.path}/lib/broken.dart',
      ).writeAsString('class Broken {');
      await Directory('${root.path}/build').create();
      await File(
        '${root.path}/build/generated.dart',
      ).writeAsString("final ignored = MethodChannel('dev.example/ignored');");
      final output = StringBuffer();

      final status = await runDartograph(
        ['bridges', '--format', 'json', root.path],
        output: output,
        now: () => DateTime.utc(2026, 9, 4, 12),
      );

      expect(status, ExitStatus.success.code);
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(document['format'], 'bridge-facts');
      expect(document['version'], 1);
      expect(document['platform'], 'dart');
      expect(document['target'], 'flutter');
      final facts = document['facts'] as List<Object?>;
      final sourceLines = facts
          .cast<Map<String, Object?>>()
          .where(
            (fact) =>
                (fact['location'] as Map<String, Object?>)['path'] ==
                'lib/channels.dart',
          )
          .map(
            (fact) =>
                (fact['location'] as Map<String, Object?>)['line']! as int,
          )
          .toList();
      expect(sourceLines, [...sourceLines]..sort());
      expect(
        facts.where((fact) => (fact as Map)['kind'] == 'channel-create'),
        hasLength(5),
      );
      expect(
        facts.where((fact) => (fact as Map)['kind'] == 'method-invoke'),
        hasLength(5),
      );
      final dynamicInvocation = facts.cast<Map<String, Object?>>().singleWhere(
        (fact) => fact['method'] == 'dynamicChannelCall',
      );
      expect(dynamicInvocation['channel'], 'channelName');
      expect(dynamicInvocation['dynamic'], isTrue);
      final forwardInvocation = facts.cast<Map<String, Object?>>().singleWhere(
        (fact) => fact['method'] == 'later',
      );
      expect(forwardInvocation['channel'], 'dev.example/later');
      expect(forwardInvocation['dynamic'], isFalse);
      final forwardConstant = facts.cast<Map<String, Object?>>().singleWhere(
        (fact) =>
            fact['kind'] == 'channel-create' &&
            fact['channel'] == 'dev.example/constant-later',
      );
      expect(forwardConstant['dynamic'], isFalse);
      final forwardConstantInvocation = facts
          .cast<Map<String, Object?>>()
          .singleWhere((fact) => fact['method'] == 'constantLater');
      expect(forwardConstantInvocation['dynamic'], isFalse);
      expect(
        facts.cast<Map<String, Object?>>().where(
          (fact) => fact['method'] == 'crossFile',
        ),
        isEmpty,
      );
      expect(
        document['limitations'],
        contains(
          'dynamic-channel-names: 2 channel constructors use a non-literal name',
        ),
      );
      expect(
        document['limitations'],
        contains(
          'parse-errors: 1 Dart source file(s) could not be parsed completely',
        ),
      );
      expect(
        document['limitations'],
        contains(
          'dynamic-method-names: 1 method invocations use a non-literal name',
        ),
      );
      expect(
        document['limitations'],
        contains(
          'unresolved-receiver-invocations: 1 invokeMethod call has an unresolved receiver',
        ),
      );
      expect(
        document['limitations'],
        contains('unscanned-event-channels: 1 EventChannel constructor'),
      );
      expect(
        document['limitations'],
        contains(
          'unscanned-basic-message-channels: 1 BasicMessageChannel constructor',
        ),
      );
    },
  );

  test(
    'bridges ignores MethodChannel-looking code without Flutter provenance',
    () async {
      final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/lib').create();
      await File('${root.path}/lib/fake.dart').writeAsString(r'''
class MethodChannel {
  MethodChannel(String name);
  void invokeMethod(String method) {}
}

final fake = MethodChannel('not/flutter');
void call() => fake.invokeMethod('notFlutter');
''');
      final output = StringBuffer();

      final status = await runDartograph(
        ['bridges', '--format', 'json', root.path],
        output: output,
        now: () => DateTime.utc(2026, 9, 4, 12),
      );

      expect(status, ExitStatus.success.code);
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(document['facts'], isEmpty);
      expect(document['target'], isNull);
    },
  );

  test('bridges reports conditional imports and Flutter re-exports', () async {
    final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/conditional.dart').writeAsString(r'''
import 'stub.dart'
  if (dart.library.io) 'package:flutter/services.dart';
final channel = MethodChannel('dev.example/conditional');
''');
    await File(
      '${root.path}/lib/barrel.dart',
    ).writeAsString("export 'package:flutter/services.dart';\n");
    final output = StringBuffer();

    final status = await runDartograph(
      ['bridges', '--format', 'json', root.path],
      output: output,
      now: () => DateTime.utc(2026, 9, 4, 12),
    );

    expect(status, ExitStatus.success.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    expect(document['facts'], isEmpty);
    expect(
      document['limitations'],
      contains(
        'conditional-flutter-services-imports: 1 Dart source file has configuration-dependent provenance',
      ),
    );
    expect(
      document['limitations'],
      contains(
        'flutter-services-reexports: 1 Dart source file re-exports Flutter services',
      ),
    );
  });

  test('bridges keeps local constants out of top-level bindings', () async {
    final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/scopes.dart').writeAsString(r'''
import 'package:flutter/services.dart';

final outer = MethodChannel(name);
const name = 'dev.example/outer';
void first() {
  const name = 'dev.example/inner';
  final inner = MethodChannel(name);
  inner.invokeMethod('inside');
}
void second() {
  outer.invokeMethod('outside');
}
''');
    final output = StringBuffer();

    final status = await runDartograph(
      ['bridges', '--format', 'json', root.path],
      output: output,
      now: () => DateTime.utc(2026, 9, 4, 12),
    );

    expect(status, ExitStatus.success.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    final facts = (document['facts'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(
      facts.singleWhere((fact) => fact['method'] == 'inside')['channel'],
      'dev.example/inner',
    );
    expect(
      facts.singleWhere((fact) => fact['method'] == 'outside')['channel'],
      'dev.example/outer',
    );
  });

  test('bridges accounts for cascade, sibling, and incomplete invokes', () async {
    final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/invokes.dart').writeAsString(r'''
import 'package:flutter/services.dart';

final channel = MethodChannel('dev.example/invokes');
void cascades() {
  channel
    ..invokeListMethod<int>('list')
    ..invokeMapMethod<String, int>('map');
}
void incomplete() {
  invokeMethod('implicit');
  channel.invokeMethod();
}
''');
    final output = StringBuffer();

    final status = await runDartograph(
      ['bridges', '--format', 'json', root.path],
      output: output,
      now: () => DateTime.utc(2026, 9, 4, 12),
    );

    expect(status, ExitStatus.success.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    final facts = (document['facts'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(
      facts
          .where((fact) => fact['kind'] == 'method-invoke')
          .map((fact) => fact['method']),
      ['list', 'map'],
    );
    expect(
      document['limitations'],
      contains(
        'unresolved-receiver-invocations: 1 invokeMethod call has an unresolved receiver',
      ),
    );
    expect(
      document['limitations'],
      contains('invalid-method-invocations: 1 invocation has no method name'),
    );
  });

  test(
    'bridges respects prefixed imports, combinators, and prefix shadowing',
    () async {
      final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/lib').create();
      await File('${root.path}/lib/prefixed.dart').writeAsString(r'''
import 'package:flutter/services.dart' as services show MethodChannel;

final prefixed = const services.MethodChannel('dev.example/prefixed');
void call() => prefixed.invokeMethod('real');
void shadow(Object services) {
  services.MethodChannel('not/flutter');
}
''');
      await File('${root.path}/lib/hidden.dart').writeAsString(r'''
import 'package:flutter/services.dart' hide MethodChannel;

class MethodChannel {
  MethodChannel(String name);
}
final hidden = MethodChannel('not/flutter');
''');
      await File('${root.path}/lib/alias.dart').writeAsString(r'''
import 'package:flutter/services.dart' show MethodChannel;

typedef MethodChannel = String;
final alias = MethodChannel('not/flutter');
''');
      final output = StringBuffer();

      final status = await runDartograph(
        ['bridges', '--format', 'json', root.path],
        output: output,
        now: () => DateTime.utc(2026, 9, 4, 12),
      );

      expect(status, ExitStatus.success.code);
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      final facts = (document['facts'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(facts, hasLength(2));
      expect(facts.map((fact) => fact['channel']).toSet(), {
        'dev.example/prefixed',
      });
      expect(facts.singleWhere((fact) => fact['method'] == 'real'), isNotNull);
    },
  );

  test('bridges does not resolve pattern variables as outer constants', () async {
    final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/pattern.dart').writeAsString(r'''
import 'package:flutter/services.dart';

const method = 'outer';
final channel = MethodChannel('dev.example/pattern');
void call(Object value) {
  if (value case final String method) {
    channel.invokeMethod(method);
  }
}
''');
    final output = StringBuffer();

    final status = await runDartograph(
      ['bridges', '--format', 'json', root.path],
      output: output,
      now: () => DateTime.utc(2026, 9, 4, 12),
    );

    expect(status, ExitStatus.success.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    final invocation = (document['facts'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((fact) => fact['kind'] == 'method-invoke');
    expect(invocation['method'], 'method');
    expect(invocation['dynamic'], isTrue);
    expect(
      document['limitations'],
      contains(
        'pattern-variable-scopes: 1 pattern binding was resolved conservatively',
      ),
    );
  });

  test('bridges uses one-based UTF-8 byte columns', () async {
    final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/utf8.dart').writeAsString(r'''
import 'package:flutter/services.dart';
final channel = MethodChannel('dev.example/utf8');
void call() { /* 한글 */ channel.invokeMethod('ping'); }
''');
    final output = StringBuffer();

    final status = await runDartograph(
      ['bridges', '--format', 'json', root.path],
      output: output,
      now: () => DateTime.utc(2026, 9, 4, 12),
    );

    expect(status, ExitStatus.success.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    final invocation = (document['facts'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((fact) => fact['kind'] == 'method-invoke');
    final location = invocation['location'] as Map<String, Object?>;
    expect(location['column'], 36);
  });

  test('bridges rejects Unicode line controls in fact values', () async {
    final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/control.dart').writeAsString(
      "import 'package:flutter/services.dart';\n"
      "final channel = MethodChannel('dev.example/unsafe\\u2028name');\n",
    );
    final output = StringBuffer();
    final errors = StringBuffer();

    final status = await runDartograph(
      ['bridges', '--format', 'json', root.path],
      output: output,
      error: errors,
    );

    expect(status, ExitStatus.failure.code);
    expect(output, isEmpty);
    expect(errors.toString(), contains('Analysis failed:'));
  });

  test('bridges accepts -- before a positional root', () async {
    final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/empty.dart').writeAsString('void main() {}');
    final output = StringBuffer();

    final status = await runDartograph([
      'bridges',
      '--format',
      'json',
      '--',
      root.path,
    ], output: output);

    expect(status, ExitStatus.success.code);
  });
}
