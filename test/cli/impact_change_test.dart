import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/changed_files.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/cli/mcp_server.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late Directory before;
  late Directory current;

  void write(Directory root, String path, String content) {
    File(p.join(root.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('impact-change.');
    before = Directory(p.join(workspace.path, 'before'))..createSync();
    current = Directory(p.join(workspace.path, 'current'))..createSync();
    for (final root in [before, current]) {
      write(
        root,
        'pubspec.yaml',
        'name: change_example\nenvironment:\n  sdk: ^3.11.0\n',
      );
      write(
        root,
        'lib/caller.dart',
        "import 'api.dart';\nint caller() => api();\n",
      );
      write(
        root,
        'test/api_test.dart',
        "import '../lib/caller.dart';\nvoid main() { caller(); }\n",
      );
    }
    write(before, 'lib/api.dart', 'int api() => 1;\n');
  });
  tearDown(() => workspace.delete(recursive: true));

  Future<Map<String, Object?>> impact({IndexPackage? index}) async {
    final output = StringBuffer();
    final error = StringBuffer();
    final status = await runDartograph(
      ['impact', '--before', before.path, '--format', 'json', current.path],
      output: output,
      error: error,
      indexPackage: index,
    );
    expect(status, 0, reason: error.toString());
    return jsonDecode(output.toString()) as Map<String, Object?>;
  }

  test(
    'deleted API keeps historical caller and connected test with separate current graph',
    () async {
      final result = await impact();
      expect(result['mode'], 'before-current');
      expect(result['status'], 'incomplete');
      final historical = result['historical'] as Map<String, Object?>;
      final currentResult = result['current'] as Map<String, Object?>;
      final impacts = (historical['impacted'] as List)
          .cast<Map<String, Object?>>();
      expect(
        impacts.any((item) => (item['id'] as String).endsWith('::caller')),
        isTrue,
      );
      expect(
        (historical['tests'] as List).single['source'],
        'test/api_test.dart',
      );
      expect(currentResult['impacted'], isEmpty);
      expect((result['changes'] as List).single['kind'], 'deleted');
      expect((currentResult['limitations'] as List).isNotEmpty, isTrue);
    },
  );

  test(
    'rename keeps old and new file identities; body-only edits change content identity',
    () async {
      write(current, 'lib/renamed.dart', 'int api() => 2;\n');
      final result = await impact();
      expect(
        (result['changes'] as List).map(
          (entry) => '${entry['kind']}:${entry['path']}',
        ),
        ['deleted:lib/api.dart', 'added:lib/renamed.dart'],
      );
      final history = result['historical'] as Map;
      final now = result['current'] as Map;
      expect(
        history['analysis']['input']['contentHash'],
        isNot(now['analysis']['input']['contentHash']),
      );
      expect(
        history['changed']['symbols'],
        contains('project:lib/api.dart::api'),
      );
      expect(
        now['changed']['symbols'],
        contains('project:lib/renamed.dart::api'),
      );
    },
  );

  test('source mutation while indexing remains stale', () async {
    final result = await impact(
      index: (root) async {
        final indexed = await AnalyzerGraphIndex().index(root);
        if (p.equals(root, current.path)) {
          write(current, 'lib/late.dart', 'void lateEdit() {}\n');
        }
        return indexed;
      },
    );
    expect(result['status'], 'stale');
    expect(
      (result['current'] as Map)['analysis']['input']['freshness'],
      'stale',
    );
  });

  test(
    'prepared package barrel edits seed the observed library and importers',
    () async {
      for (final root in [before, current]) {
        write(root, 'lib/a.dart', 'int api() => 1;\n');
        write(root, 'lib/b.dart', 'int api() => 2;\n');
        // 정렬상 먼저 오는 빈 part도 라이브러리의 소스를 바꾸면 안 된다.
        write(root, 'lib/aaa_part.dart', "part of 'api.dart';\n");
        final prepared = await Process.run(Platform.resolvedExecutable, [
          'pub',
          'get',
          '--offline',
        ], workingDirectory: root.path);
        expect(prepared.exitCode, 0, reason: prepared.stderr.toString());
      }
      write(before, 'lib/api.dart', "export 'a.dart';\npart 'aaa_part.dart';\n");
      write(current, 'lib/api.dart', "export 'b.dart';\npart 'aaa_part.dart';\n");
      final result = await impact();
      for (final side in ['historical', 'current']) {
        final report = result[side] as Map;
        expect(
          report['changed']['libraries'],
          contains('package:change_example/api.dart'),
        );
        expect(report['changed']['unattributedSources'], isEmpty);
        expect(
          (report['impacted'] as List).map((item) => item['id']),
          contains('package:change_example/caller.dart'),
        );
        expect(
          (report['tests'] as List).map((item) => item['source']),
          contains('test/api_test.dart'),
        );
      }
      expect(result['status'], 'incomplete');
      final changedList = File(p.join(workspace.path, 'changes.json'))
        ..writeAsStringSync(jsonEncode(['lib/api.dart']));
      final output = StringBuffer();
      expect(
        await runDartograph([
          'impact',
          '--changed',
          changedList.path,
          '--format',
          'json',
          current.path,
        ], output: output),
        0,
      );
      final legacy = jsonDecode(output.toString()) as Map;
      expect(
        legacy['changed']['libraries'],
        contains('package:change_example/api.dart'),
      );
      expect(legacy['changed']['unattributedSources'], isEmpty);
    },
  );

  test(
    'MCP exposes separate captures and enforces the beforeRoot boundary',
    () async {
      final output = StringBuffer();
      await runMcpServer(
        input: Stream.fromIterable([
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': impactToolName,
              'arguments': {
                'packageRoot': current.path,
                'beforeRoot': before.path,
              },
            },
          }),
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {
              'name': impactToolName,
              'arguments': {
                'packageRoot': current.path,
                'beforeRoot': workspace.parent.path,
              },
            },
          }),
        ]),
        output: output,
        error: StringBuffer(),
        allowedRootBase: workspace.path,
        indexPackage: (root) => AnalyzerGraphIndex().index(root),
        environment: const {},
      );
      final replies = output
          .toString()
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map)
          .toList();
      final text = replies.first['result']['content'][0]['text'] as String;
      final result = jsonDecode(text.substring(text.indexOf('\n'))) as Map;
      expect(result['mode'], 'before-current');
      expect(
        result['historical']['analysis']['input']['freshness'],
        'content-checked',
      );
      expect(result['current']['analysis']['status'], 'incomplete');
      expect(replies.last['result']['isError'], isTrue);
      expect(
        replies.last['result']['content'][0]['text'],
        contains('beforeRoot must be an existing directory within'),
      );
    },
  );

  test(
    'Git change collection preserves deleted and renamed old paths',
    () async {
      Future<void> git(List<String> args) async {
        final result = await Process.run(
          'git',
          args,
          workingDirectory: before.path,
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
      }

      await git(['init', '-q']);
      await git([
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        'add',
        '.',
      ]);
      await git([
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        'commit',
        '-qm',
        'before',
      ]);
      File(
        p.join(before.path, 'lib/api.dart'),
      ).renameSync(p.join(before.path, 'lib/renamed.dart'));
      final changed = await ChangedFiles.since('HEAD', before.path);
      expect(
        changed,
        contains(p.join(before.resolveSymbolicLinksSync(), 'lib', 'api.dart')),
      );
      expect(
        changed,
        contains(
          p.join(before.resolveSymbolicLinksSync(), 'lib', 'renamed.dart'),
        ),
      );
    },
  );
}
