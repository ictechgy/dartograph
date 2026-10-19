import 'dart:convert';
import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

import '../support/read_boundary_support.dart';

void main() {
  test('batch rejects option-shaped root before indexing', () async {
    final directory = await Directory.systemTemp.createTemp('query-batch.');
    addTearDown(() => directory.delete(recursive: true));
    final requests = File('${directory.path}/requests.json');
    await requests.writeAsString('["Live"]');
    var calls = 0;
    expect(
      await runDartograph(
        ['query', '--batch', requests.path, '--baseline'],
        error: StringBuffer(),
        indexPackage: (_) async {
          calls++;
          throw StateError('unexpected indexing');
        },
      ),
      64,
    );
    expect(calls, 0);
  });
  test(
    'batch handles ambiguity and baseline without losing individual status',
    () async {
      final directory = await Directory.systemTemp.createTemp('query-batch.');
      addTearDown(() => directory.delete(recursive: true));
      final graph = CodeGraph()
        ..addNode(GraphNode(id: 'app::A.run'))
        ..addNode(GraphNode(id: 'app::B.run'));
      final indexed = AnalyzerGraphResult(graph: graph, limitations: const []);
      final baseline = '${directory.path}/baseline.json';
      expect(
        await runDartograph(
          ['baseline', '--write', baseline, '.'],
          output: StringBuffer(),
          indexPackage: (_) async => indexed,
        ),
        0,
      );
      final requests = File('${directory.path}/requests.json');
      await requests.writeAsString('["run", "app::A.run"]');
      final output = StringBuffer();
      expect(
        await runDartograph(
          ['query', '--batch', requests.path, '--baseline', baseline, '.'],
          output: output,
          indexPackage: (_) async => indexed,
        ),
        0,
      );
      final results = (jsonDecode(output.toString()) as Map)['results'] as List;
      expect(results.first['status'], 'ambiguous');
      expect(
        results.last['result']['reachability']['suppressedByBaseline'],
        true,
      );
    },
  );
  test(
    'batch preserves request order and indexes once including misses',
    () async {
      final directory = await Directory.systemTemp.createTemp('query-batch.');
      addTearDown(() => directory.delete(recursive: true));
      final requests = File('${directory.path}/requests.json');
      await requests.writeAsString('["Live", "Missing", "Live"]');
      var calls = 0;
      final output = StringBuffer();
      final graph = CodeGraph()..addNode(GraphNode(id: 'app::Live'));
      final status = await runDartograph(
        ['query', '--batch', requests.path, '.'],
        output: output,
        indexPackage: (_) async {
          calls++;
          return AnalyzerGraphResult(graph: graph, limitations: const []);
        },
      );
      expect(status, 64);
      expect(calls, 1);
      final document = jsonDecode(output.toString()) as Map;
      expect(document['format'], 'symbol-query-batch');
      expect((document['results'] as List).map((e) => e['status']), [
        'found',
        'notFound',
        'found',
      ]);
    },
  );

  test('an unreadable batch file is reported apart from bad content', () async {
    final directory = await Directory.systemTemp.createTemp('query-batch.');
    addTearDown(() => directory.delete(recursive: true));
    var calls = 0;
    Future<AnalyzerGraphResult> mustNotIndex(String _) async {
      calls++;
      throw StateError('must not index');
    }

    final missing = '${directory.path}/absent.json';
    final missingError = StringBuffer();
    expect(
      await runDartograph(
        ['query', '--batch', missing, '.'],
        error: missingError,
        indexPackage: mustNotIndex,
      ),
      64,
    );
    final malformed = File('${directory.path}/requests.json')
      ..writeAsStringSync('{');
    final malformedError = StringBuffer();
    expect(
      await runDartograph(
        ['query', '--batch', malformed.path, '.'],
        error: malformedError,
        indexPackage: mustNotIndex,
      ),
      64,
    );
    expect(calls, 0);
    // 파일 부재는 내용 오류가 아니다. 어느 파일을 읽지 못했는지 가리킨다.
    expect(missingError.toString(), contains(missing));
    expect(missingError.toString(), isNot(contains('Invalid batch')));
    expect(malformedError.toString(), startsWith('Invalid batch:'));
  });

  test('a batch file that is a device or FIFO is rejected by its cause before '
      'indexing', () async {
    final directory = await Directory.systemTemp.createTemp('query-batch.');
    addTearDown(() => directory.delete(recursive: true));
    var calls = 0;
    Future<AnalyzerGraphResult> mustNotIndex(String _) async {
      calls++;
      throw StateError('must not index');
    }

    // 길이를 본 뒤 전체를 읽던 수정 전 코드는 /dev/zero 링크면 상한 없이 읽고
    // 쓰는 쪽이 없는 FIFO면 영구 대기했다. 여기서는 /dev/null과 쓰는 쪽이 붙은
    // FIFO라 수정 전 코드도 빈 내용을 읽고 'Invalid batch'로 끝난다.
    final device = '${directory.path}/device.json';
    await Link(device).create('/dev/null');
    final fifo = await fifoWithRepeatingWriter('${directory.path}/pipe.json');
    for (final path in [device, fifo]) {
      final error = StringBuffer();
      expect(
        await runDartograph(
          ['query', '--batch', path, '.'],
          error: error,
          indexPackage: mustNotIndex,
        ),
        64,
        reason: path,
      );
      expect(
        error.toString(),
        'Batch file must be a regular file (not a device, FIFO, or socket): '
        '$path\n',
      );
    }
    expect(calls, 0);
  }, skip: Platform.isWindows);

  test('malformed batch is rejected before indexing', () async {
    final directory = await Directory.systemTemp.createTemp('query-batch.');
    addTearDown(() => directory.delete(recursive: true));
    final requests = File('${directory.path}/requests.json');
    for (final source in ['{}', '[1]', '[]', '[""]', '{']) {
      await requests.writeAsString(source);
      var calls = 0;
      final status = await runDartograph(
        ['query', '--batch', requests.path, '.'],
        error: StringBuffer(),
        indexPackage: (_) async {
          calls++;
          throw StateError('must not index');
        },
      );
      expect(status, 64);
      expect(calls, 0);
    }
  });
}
