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

  test('skill prints Dart-specific safety rules', () async {
    final output = StringBuffer();
    expect(
      await runDartograph(const ['skill'], output: output),
      ExitStatus.success.code,
    );
    expect(output.toString(), contains('main functions may be multiple'));
    expect(output.toString(), contains('entry_points'));
    expect(output.toString(), contains('state is not a deletion verdict'));
    expect(output.toString(), contains('limitations'));
    expect(output.toString(), contains('overrideContract'));
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
    expect(await installed.readAsString(), contains('entry_points'));

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
    expect(await installed.readAsString(), contains('entry_points'));
  });

  test(
    'bridges emits GRAPH-EXCHANGE facts for all Flutter channel types',
    () async {
      final root = await Directory.systemTemp.createTemp('dartograph-bridges-');
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/lib').create();
      await File('${root.path}/lib/channels.dart').writeAsString(r'''
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
        hasLength(7),
      );
      expect(
        facts.where((fact) => (fact as Map)['kind'] == 'method-invoke'),
        hasLength(6),
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
      final unattributed = facts.cast<Map<String, Object?>>().singleWhere(
        (fact) => fact['method'] == 'crossFile',
      );
      expect(unattributed['channel'], isNull);
      expect(unattributed['dynamic'], isTrue);
      expect(
        document['limitations'],
        contains(
          'dynamic-channel-names: 2 channel constructors use a non-literal name',
        ),
      );
      expect(
        document['limitations'],
        contains(
          'unattributed-method-invocations: 1 invocation(s) could not be assigned to a channel',
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
    },
  );
}
