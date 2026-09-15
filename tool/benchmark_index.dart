import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/layer_rules.dart';
import 'package:dartograph/src/analysis/reachability_analyzer.dart';
import 'package:dartograph/src/export/dead_reporter.dart';
import 'package:dartograph/src/export/graph_exporter.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/incremental_cache.dart';
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

    // rules 평가: 매치되지 않는 노드(f06~f09·test)가 전체 패턴을 first-match로
    // 훑으므로 glob 컴파일 비용이 노드 × 패턴만큼 반복되는 경로를 재는다.
    final ruleSet = LayerRuleSet.parse(_rulesYaml);
    final rulesMicros = <int>[];
    late List<LayerViolation> violations;
    for (var rep = 0; rep < reps; rep++) {
      final watch = Stopwatch()..start();
      violations = LayerRuleEvaluator(ruleSet).evaluate(snapshot);
      rulesMicros.add(watch.elapsedMicroseconds);
    }

    final incremental = await _incrementalComparison(root, workspace);

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
        'incremental': incremental,
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
        'rulesMinMicros': minOf(rulesMicros),
        'rulesSha256': _sha(
          jsonEncode(
            violations.map((violation) => violation.toJson()).toList(),
          ),
        ),
        'rulesViolations': violations.length,
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

/// rules 평가에 쓰는 고정 규칙이다(측정 조건이 실행마다 달라지지 않는다).
const _rulesYaml =
    'layers:\n'
    '  - name: a\n'
    '    match: ["project:lib/f00**", "project:lib/f01**", '
    '"project:lib/f02**"]\n'
    '  - name: b\n'
    '    match: ["project:lib/f03**", "project:lib/f04**", '
    '"project:lib/f05**"]\n'
    'rules:\n'
    '  - name: a-not-b\n'
    '    from: a\n'
    '    deny: [b]\n';

/// 증분 분석의 A/B 결과다.
///
/// 같은 입력에서 전체 해석과 증분 해석의 산출물 7종 sha256이 모두 같아야 한다 —
/// 캐시는 속도만 바꾸고 출력은 바꾸지 않는다(`doc/DECISION-incremental.md` 3절).
/// 조건은 셋이다: 변경 없음(전부 재사용), 널리 import되는 파일 하나 변경,
/// 아무도 import하지 않는 잎 파일 하나 변경. 합성 패키지의 import가 무작위라
/// 널리 import되는 파일의 역방향 폐쇄는 사실상 전체가 된다 — 그 값도 그대로
/// 보고한다(측정 없는 낙관 금지).
Future<Map<String, Object?>> _incrementalComparison(
  String root,
  Directory workspace,
) async {
  final cache = IncrementalCache(p.join(workspace.path, 'incremental-facts'));
  final full = await _measureFull(root);
  final cold = await _measureIncremental(root, cache);
  final warm = await _measureIncremental(root, cache);
  final measurements = <String, _Measurement>{'warm': warm};
  for (final (label, relative) in [
    ('imported', 'lib/f0000.dart'),
    ('leaf', 'lib/main.dart'),
  ]) {
    final target = File(p.join(root, relative));
    await target.writeAsString(
      '${await target.readAsString()}\n// benchmark change\n',
    );
    measurements[label] = await _measureIncremental(root, cache);
    measurements['$label-full'] = await _measureFull(root);
  }
  return {
    'artifactHashesMatch': {
      for (final entry in measurements.entries)
        if (!entry.key.endsWith('-full'))
          entry.key: _hashesMatch(
            measurements['${entry.key}-full']?.hashes ?? full.hashes,
            entry.value.hashes,
          ),
    },
    'artifacts': {
      'full': full.hashes,
      for (final entry in measurements.entries)
        if (!entry.key.endsWith('-full')) entry.key: entry.value.hashes,
    },
    'fullMicros': full.micros,
    'coldMicros': cold.micros,
    'speedup': {
      for (final entry in measurements.entries)
        if (!entry.key.endsWith('-full') && entry.value.micros > 0)
          entry.key: _speedup(
            measurements['${entry.key}-full']?.micros ?? full.micros,
            entry.value.micros,
          ),
    },
    'resolvedFiles': {
      'cold': cold.resolvedFiles,
      for (final entry in measurements.entries)
        if (!entry.key.endsWith('-full')) entry.key: entry.value.resolvedFiles,
    },
    'reusedFiles': {
      'cold': cold.reusedFiles,
      for (final entry in measurements.entries)
        if (!entry.key.endsWith('-full')) entry.key: entry.value.reusedFiles,
    },
  };
}

/// 전체 대비 배수다(0으로 나누지 않는다).
double _speedup(int fullMicros, int incrementalMicros) =>
    fullMicros / incrementalMicros;

/// 산출물 해시 7종이 모두 같은지 확인한다.
Map<String, bool> _hashesMatch(
  Map<String, String> full,
  Map<String, String> incremental,
) => {
  for (final entry in full.entries)
    entry.key: incremental[entry.key] == entry.value,
};

/// 한 번의 전체 해석: 산출물 해시와 시간.
Future<_Measurement> _measureFull(String root) async {
  final watch = Stopwatch()..start();
  final result = await AnalyzerGraphIndex(cache: _ColdCache()).index(root);
  final micros = watch.elapsedMicroseconds;
  return _Measurement(
    hashes: _artifactHashes(result),
    micros: micros,
    resolvedFiles: result.graph.nodes.length,
    reusedFiles: 0,
  );
}

/// 한 번의 증분 해석: 산출물 해시·시간·재사용 규모.
Future<_Measurement> _measureIncremental(
  String root,
  IncrementalCache cache,
) async {
  final watch = Stopwatch()..start();
  final result = await AnalyzerGraphIndex(
    cache: _ColdCache(),
    incremental: cache,
  ).index(root);
  final micros = watch.elapsedMicroseconds;
  return _Measurement(
    hashes: _artifactHashes(result),
    micros: micros,
    resolvedFiles: cache.stats.resolvedFiles,
    reusedFiles: cache.stats.reusedFiles,
  );
}

/// 전체 해석 결과에서 뽑는 산출물 7종의 sha256이다.
Map<String, String> _artifactHashes(AnalyzerGraphResult result) {
  final snapshot = result.graph.snapshot();
  final analysis = ReachabilityAnalyzer().analyze(
    snapshot,
    roots: result.retentionRoots,
    limitations: const [],
  );
  final testOnly = ReachabilityAnalyzer().testOnlyDeclarations(
    snapshot,
    roots: result.retentionRoots,
    limitations: const [],
  );
  final session = SymbolQuerySession(
    graph: snapshot,
    roots: result.retentionRoots,
    limitations: const [],
  );
  final violations = LayerRuleEvaluator(
    LayerRuleSet.parse(_rulesYaml),
  ).evaluate(snapshot);
  final rootIds = result.retentionRoots.keys.toList()..sort();
  return {
    'deadJsonSha256': _sha(
      DeadReporter.render(ReportFormat.json, [
        ...analysis.deadDeclarations,
        ...analysis.deadFiles,
      ]),
    ),
    'graphJsonSha256': _sha(GraphExporter.json(snapshot)),
    'limitationsSha256': _sha(jsonEncode(result.limitationDetails)),
    'queryBatchSha256': _sha(
      jsonEncode([
        for (final request in _queryRequests(snapshot)) session.query(request),
      ]),
    ),
    'retentionSha256': _sha(
      jsonEncode([
        for (final id in rootIds) '$id=${result.retentionRoots[id]!.name}',
      ]),
    ),
    'rulesSha256': _sha(
      jsonEncode(violations.map((violation) => violation.toJson()).toList()),
    ),
    'testOnlySha256': _sha(
      jsonEncode(testOnly.map((finding) => finding.toJson()).toList()),
    ),
  };
}

/// 산출물 해시·시간·재사용 규모를 함께 나르는 측정값이다.
final class _Measurement {
  const _Measurement({
    required this.hashes,
    required this.micros,
    required this.resolvedFiles,
    required this.reusedFiles,
  });

  final Map<String, String> hashes;
  final int micros;
  final int resolvedFiles;
  final int reusedFiles;
}
