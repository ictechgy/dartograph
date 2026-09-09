import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/reachability_analyzer.dart';
import 'package:dartograph/src/export/dead_reporter.dart';
import 'package:dartograph/src/export/graph_exporter.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;

/// 인덱싱·도달성·질의 파이프라인의 A/B 측정 하네스.
///
/// 합성 패키지(dep-free, 결정적 생성)를 임시 디렉터리에 만들어 cold 인덱싱
/// (무캐시) K회의 시간과 인덱스 뒤 도달성·test-only·배치 질의 시간을 잰다.
/// 결과 동등성은 산출물 sha256으로 고정한다 — 최적화 전후 실행의 해시가
/// 같으면 출력이 byte-for-byte 보존된 것이다. 측정 조건(SDK·파일 수·runs)을
/// 함께 출력한다. 사용법:
///
///   dart run tool/benchmark_index.dart [파일수=600] [runs=3]
///
/// 벤치마크이지 SLA가 아니다. 절대 시간은 머신·SDK·JIT에 의존하며 상대
/// 비교만 의미 있다(첫 run은 워밍업 포함 — 중앙값/최소를 본다).
Future<void> main(List<String> arguments) async {
  final fileCount = arguments.isNotEmpty ? int.parse(arguments[0]) : 600;
  final runs = arguments.length > 1 ? int.parse(arguments[1]) : 3;
  if (fileCount < 1 || runs < 1) {
    stderr.writeln('usage: benchmark_index.dart [fileCount>=1] [runs>=1]');
    exit(64);
  }

  final libraryUri = await Isolate.resolvePackageUri(
    Uri.parse('package:dartograph/dartograph.dart'),
  );
  if (libraryUri == null) {
    throw StateError('Could not resolve the dartograph package root.');
  }
  final workspace = await Directory.systemTemp.createTemp(
    'dartograph-benchmark-index.',
  );
  try {
    final root = await _generatePackage(workspace, fileCount);
    final index = AnalyzerGraphIndex(cache: _ColdCache());

    final runMicros = <int>[];
    final runHashes = <String>{};
    late AnalyzerGraphResult result;
    for (var run = 0; run < runs; run++) {
      final watch = Stopwatch()..start();
      result = await index.index(root);
      runMicros.add(watch.elapsedMicroseconds);
      // run 간 비결정성이 있으면 마지막 run 우연 일치로 가려지므로 매 run의
      // 그래프 해시를 대조한다.
      runHashes.add(_sha(GraphExporter.json(result.graph.snapshot())));
    }
    if (runHashes.length != 1) {
      throw StateError('index output differs between runs: $runHashes');
    }
    final snapshot = result.graph.snapshot();

    // 후속 측정은 1회 노이즈가 크므로 5회 반복의 최소값을 보고한다.
    const reps = 5;
    int minOf(List<int> values) => values.reduce((a, b) => a < b ? a : b);

    final analyzeMicros = <int>[];
    late ReachabilityResult analysis;
    for (var rep = 0; rep < reps; rep++) {
      final watch = Stopwatch()..start();
      analysis = ReachabilityAnalyzer().analyze(
        snapshot,
        roots: result.retentionRoots,
        limitations: const [],
      );
      analyzeMicros.add(watch.elapsedMicroseconds);
    }

    final testOnlyMicros = <int>[];
    late List<DeadFinding> testOnly;
    for (var rep = 0; rep < reps; rep++) {
      final watch = Stopwatch()..start();
      testOnly = ReachabilityAnalyzer().testOnlyDeclarations(
        snapshot,
        roots: result.retentionRoots,
        limitations: const [],
      );
      testOnlyMicros.add(watch.elapsedMicroseconds);
    }

    final requests = _queryRequests(snapshot);
    final queryMicros = <int>[];
    late List<Map<String, Object?>> queries;
    for (var rep = 0; rep < reps; rep++) {
      final session = SymbolQuerySession(
        graph: snapshot,
        roots: result.retentionRoots,
        limitations: const [],
      );
      final watch = Stopwatch()..start();
      queries = [for (final request in requests) session.query(request)];
      queryMicros.add(watch.elapsedMicroseconds);
    }

    print(
      const JsonEncoder.withIndent('  ').convert({
        'analyzeMinMicros': minOf(analyzeMicros),
        'deadFindings':
            analysis.deadDeclarations.length + analysis.deadFiles.length,
        'deadJsonSha256': _sha(
          DeadReporter.render(ReportFormat.json, [
            ...analysis.deadDeclarations,
            ...analysis.deadFiles,
          ]),
        ),
        'edges': snapshot.edges.length,
        'fileCount': fileCount,
        'graphJsonSha256': _sha(GraphExporter.json(snapshot)),
        'indexRunMicros': runMicros,
        'limitationsSha256': _sha(jsonEncode(result.limitationDetails)),
        'nodes': snapshot.nodes.length,
        'queryBatchMinMicros': minOf(queryMicros),
        'queryBatchSha256': _sha(jsonEncode(queries)),
        'retentionRoots': result.retentionRoots.length,
        'retentionSha256': _sha(
          jsonEncode(
            (result.retentionRoots.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key)))
                .map((entry) => '${entry.key}=${entry.value.name}')
                .toList(),
          ),
        ),
        'runs': runs,
        'sdk': Platform.version,
        'testOnlyCount': testOnly.length,
        'testOnlyMinMicros': minOf(testOnlyMicros),
        'testOnlySha256': _sha(
          jsonEncode(testOnly.map((finding) => finding.toJson()).toList()),
        ),
      }),
    );
  } finally {
    await workspace.delete(recursive: true);
  }
}

/// dep-free 합성 패키지를 결정적으로 생성하고 루트 경로를 돌려준다.
///
/// 파일당 클래스 1 + 메서드 3 + 필드 + 최상위 함수로 식별자 참조 밀도를
/// 높이고(P1 `_elementId` 경로), 파일당 상대 import 2개, 배럴이 파일 1/3과
/// main을 export(P2 `_addPublicApiRoots` 경로), test/ 파일이 lib를 import해
/// visibleForTesting 루트를 만든다(test-only 측정용).
Future<String> _generatePackage(Directory workspace, int fileCount) async {
  final root = Directory(p.join(workspace.path, 'synth_bench'));
  await Directory(p.join(root.path, 'lib')).create(recursive: true);
  await Directory(p.join(root.path, 'test')).create(recursive: true);
  await File(p.join(root.path, 'pubspec.yaml')).writeAsString('''
name: synth_bench
environment:
  sdk: ^3.11.0
''');
  String name(int i) => 'f${i.toString().padLeft(4, '0')}';
  int first(int i) => (i * 7 + 1) % fileCount;
  int second(int i) => (i * 13 + 5) % fileCount;

  final barrel = StringBuffer("export 'main.dart';\n");
  for (var i = 0; i < fileCount; i++) {
    await File(p.join(root.path, 'lib', '${name(i)}.dart')).writeAsString('''
import '${name(first(i))}.dart';
import '${name(second(i))}.dart';

class C$i {
  C$i(this.value);

  final int value;

  static const tag = 'c$i';

  int compute() => value + 1;

  int combine(C${first(i)} other) =>
      value + other.value + compute() + other.compute();

  bool matches(C${second(i)} other) =>
      other.compute() == compute() && tag == C$i.tag;
}

int use$i(C${first(i)} a) => a.combine(C${first(i)}(1)) + a.compute() + C$i.tag.length;
''');
    if (i < fileCount ~/ 3) {
      barrel.write("export '${name(i)}.dart';\n");
    }
  }
  await File(
    p.join(root.path, 'lib', 'synth_bench.dart'),
  ).writeAsString(barrel.toString());
  await File(p.join(root.path, 'lib', 'main.dart')).writeAsString('''
import 'synth_bench.dart';

void main() {
  print(use0(C${first(0)}(2)) + C0.tag);
}
''');
  // 테스트는 main 도달 궤적(0에서 7i+1 반복) 밖인 끝쪽 파일을 import해
  // "테스트에서만 도달되는 프로덕션 선언"(test-only)을 실제로 만든다 —
  // testOnlyCount가 0이면 P3(explain-per-finding) 경로가 측정되지 않는다.
  final testCount = fileCount ~/ 10 < 1 ? 1 : fileCount ~/ 10;
  for (var i = 0; i < testCount; i++) {
    final target = fileCount - 1 - i;
    await File(p.join(root.path, 'test', 't$i.dart')).writeAsString('''
import '../lib/${name(target)}.dart';

void testT$i() {
  print(use$target(C${first(target)}(1)));
}
''');
  }
  return root.path;
}

List<String> _queryRequests(GraphSnapshot snapshot) {
  final ids = snapshot.nodes.map((node) => node.id).toList()..sort();
  if (ids.isEmpty) return const [];
  return [for (var i = 0; i < 100; i++) ids[(i * 7) % ids.length]];
}

String _sha(String value) => sha256.convert(utf8.encode(value)).toString();

/// 항상 miss인 캐시 — cold 경로를 측정한다.
final class _ColdCache implements FactCache {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String payload) async {}
}
