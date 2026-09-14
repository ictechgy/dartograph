import '../core/graph_edge.dart';
import '../core/graph_node.dart';
import '../core/graph_snapshot.dart';

/// 변경 씨앗에서 전이적으로 영향을 받는 심볼 하나다.
///
/// 영향은 사용 간선(`impliesUsage`: call·reference·inheritance·implements·
/// mixin·override·import·export)을 역방향으로 따라간 관측이다. 보존·죽은 코드
/// 판정이 아니며, 나열되지 않은 선언이 영향을 받지 않았다는 증명도 아니다.
final class ImpactedSymbol {
  /// 영향 항목을 만든다.
  const ImpactedSymbol({
    required this.id,
    required this.kind,
    required this.depth,
    required this.path,
    required this.riskScore,
    required this.riskLevel,
    this.source,
    this.line,
    this.column,
  });

  /// 그래프 정점 ID다.
  final String id;

  /// `declaration` 또는 `file`이다.
  final String kind;

  /// 가장 가까운 변경 씨앗까지의 사용 간선 건너기 수다.
  final int depth;

  /// 이 항목에서 시작해 변경 씨앗에서 끝나는 최단 사용 경로다.
  final List<String> path;

  /// 개별 항목 위험 점수(0–100)다.
  final int riskScore;

  /// `low`·`medium`·`high`다.
  final String riskLevel;

  /// 프로젝트 상대 소스 경로다(알 수 있을 때).
  final String? source;

  /// 알 수 있을 때의 1부터 시작하는 줄이다.
  final int? line;

  /// 알 수 있을 때의 1부터 시작하는 열이다.
  final int? column;

  /// 키가 알파벳 순서인 결정적 JSON 값이다.
  Map<String, Object> toJson() => {
    'column': ?column,
    'depth': depth,
    'id': id,
    'kind': kind,
    'line': ?line,
    'path': path,
    'risk': riskLevel,
    'riskScore': riskScore,
    'source': ?source,
  };
}

/// 변경된 심볼을 사용하는 호출 지점 하나다.
final class ImpactCallSite {
  /// 호출 지점을 만든다.
  const ImpactCallSite({
    required this.fromId,
    required this.toId,
    required this.kind,
    this.fromSource,
    this.fromLine,
    this.fromColumn,
    this.fromIsLibrary = false,
  });

  /// 참조하는(의존하는) 심볼 ID다.
  final String fromId;

  /// 변경된 피참조 심볼 ID다.
  final String toId;

  /// 사용 관계 이름이다(`call`·`reference`·`import` …).
  final String kind;

  /// 호출이 일어나는 파일의 프로젝트 상대 경로다.
  final String? fromSource;

  /// 호출 지점의 1부터 시작하는 줄이다.
  final int? fromLine;

  /// 호출 지점의 1부터 시작하는 열이다.
  final int? fromColumn;

  /// 호출 주체가 라이브러리(파일) 정점인지 나타낸다.
  final bool fromIsLibrary;

  /// 키가 알파벳 순서인 결정적 JSON 값이다.
  Map<String, Object> toJson() => {
    'column': ?fromColumn,
    'from': fromId,
    'fromKind': fromIsLibrary ? 'file' : 'declaration',
    'kind': kind,
    'line': ?fromLine,
    'source': ?fromSource,
    'to': toId,
  };
}

/// 변경 라이브러리에 (전이적으로) 의존하는 테스트 라이브러리 하나다.
final class ImpactedTest {
  /// 관련 테스트 라이브러리를 만든다.
  const ImpactedTest({
    required this.id,
    required this.depth,
    required this.path,
    this.source,
  });

  /// 테스트 라이브러리 정점 ID다.
  final String id;

  /// 변경 씨앗까지의 최단 거리다.
  final int depth;

  /// 이 테스트에서 변경 씨앗에서 끝나는 최단 경로다.
  final List<String> path;

  /// 테스트 파일의 프로젝트 상대 경로다.
  final String? source;

  /// 키가 알파벳 순서인 결정적 JSON 값이다.
  Map<String, Object> toJson() => {
    'depth': depth,
    'id': id,
    'path': path,
    'source': ?source,
  };
}

/// 위험 점수 하나를 만든 관측이다.
final class ImpactRiskFactor {
  /// 위험 팩터를 만든다.
  const ImpactRiskFactor({
    required this.name,
    required this.weight,
    required this.detail,
  });

  /// 팩터 이름이다(기계 판독 가능한 kebab-case).
  final String name;

  /// 점수에 더한 가중치다.
  final int weight;

  /// 사람이 읽는 근거다.
  final String detail;

  /// 키가 알파벳 순서인 결정적 JSON 값이다.
  Map<String, Object> toJson() => {
    'detail': detail,
    'name': name,
    'weight': weight,
  };
}

/// 변경 씨앗의 전체 위험도다.
final class ImpactRisk {
  /// 위험도를 만든다.
  const ImpactRisk({
    required this.score,
    required this.level,
    required this.factors,
  });

  /// 0–100 점수다(팩터 가중치의 합을 100으로 자른다).
  final int score;

  /// `low`·`medium`·`high`다.
  final String level;

  /// 점수를 만든 팩터 목록이다(가중치 큰 순, 동률은 이름 순).
  final List<ImpactRiskFactor> factors;

  /// 키가 알파벳 순서인 결정적 JSON 값이다.
  Map<String, Object> toJson() => {
    'factors': factors.map((factor) => factor.toJson()).toList(),
    'level': level,
    'score': score,
  };
}

/// 사전 점검이 직접 변경만 볼 때와 비교해 추가로 드러낸 범위다.
///
/// 이 블록은 "점검 없이 진행할 때와 비교해 누락이 줄었음"의 근거다.
final class ImpactCoverage {
  /// 커버리지를 만든다.
  const ImpactCoverage({
    required this.directlyChangedSymbols,
    required this.transitivelyImpacted,
    required this.relatedTests,
    required this.missedWithoutPrecheck,
  });

  /// 직접 변경된 선언 심볼 수다.
  final int directlyChangedSymbols;

  /// 전이적으로 영향을 받는 심볼 수다.
  final int transitivelyImpacted;

  /// 관련 테스트 라이브러리 수다.
  final int relatedTests;

  /// 변경 파일만 확인했을 때 누락됐을 심볼 ID 목록(정렬)이다.
  final List<String> missedWithoutPrecheck;

  /// 키가 알파벳 순서인 결정적 JSON 값이다.
  Map<String, Object> toJson() => {
    'directlyChangedSymbols': directlyChangedSymbols,
    'missedWithoutPrecheck': missedWithoutPrecheck,
    'relatedTests': relatedTests,
    'transitivelyImpacted': transitivelyImpacted,
  };
}

/// 영향 사전 점검의 전체 결과다.
final class ImpactReport {
  /// 영향 결과를 만든다.
  const ImpactReport({
    required this.changedLibraries,
    required this.changedSymbols,
    required this.changedSources,
    required this.unattributedSources,
    required this.missingSymbols,
    required this.impacted,
    required this.callSites,
    required this.tests,
    required this.risk,
    required this.coverage,
    required this.truncatedImpacted,
  });

  /// 변경 파일이 귀속된 라이브러리 정점 ID(정렬)다.
  final List<String> changedLibraries;

  /// 변경 파일이 귀속된 선언 정점 ID(정렬)다.
  final List<String> changedSymbols;

  /// 변경으로 매치된 소스 URI(`project:` 포함) 목록(정렬)이다.
  final List<String> changedSources;

  /// 매치됐지만 어떤 정점에도 귀속되지 못한 변경 소스(정렬)다.
  final List<String> unattributedSources;

  /// `--symbol`로 요청했으나 그래프에 없는 ID(정렬)다.
  final List<String> missingSymbols;

  /// 전이적으로 영향받는 심볼(정렬)이다.
  final List<ImpactedSymbol> impacted;

  /// 변경 선언으로 들어오는 외부 사용 간선이다.
  final List<ImpactCallSite> callSites;

  /// 변경 라이브러리에 의존하는 테스트 라이브러리다.
  final List<ImpactedTest> tests;

  /// 전체 위험도다.
  final ImpactRisk risk;

  /// 사전 점검 가치 근거다.
  final ImpactCoverage coverage;

  /// `--limit`로 잘려 나간 영향 항목 수다(0이면 전부 표시).
  final int truncatedImpacted;

  /// 잘림이 있었는지 나타낸다.
  bool get truncated => truncatedImpacted > 0;
}

/// 변경 씨앗에서 출발하는 영향 사전 점검을 계산한다.
abstract final class ImpactAnalysis {
  /// [changedSources](`project:` 소스 URI 집합)와 [changedSymbols]를 씨앗으로
  /// 사용 간선을 역방향으로 건너 영향을 받는 심볼·호출 지점·관련 테스트를 모은다.
  ///
  /// [maxDepth]가 주어지면 그 깊이까지만 건넌다. [limit]은 **보고** 항목 수를
  /// 제한하며(정렬 후 앞에서부터), 초과분은 [ImpactReport.truncatedImpacted]로
  /// 센다 — 탐색 자체는 제한하지 않아 개수·위험도가 잘림에 좌우되지 않는다.
  static ImpactReport analyze(
    GraphSnapshot graph, {
    Set<String> changedSources = const {},
    Iterable<String> changedSymbols = const [],
    int? maxDepth,
    int? limit,
  }) {
    final nodeById = <String, GraphNode>{
      for (final node in graph.nodes) node.id: node,
    };
    final seeds = <String>{};
    final attributed = <String>{};
    final missing = <String>{};

    for (final node in graph.nodes) {
      final source = node.sourceUri;
      if (source == null || !changedSources.contains(source)) continue;
      seeds.add(node.id);
      attributed.add(source);
    }
    for (final symbol in changedSymbols) {
      if (nodeById.containsKey(symbol)) {
        seeds.add(symbol);
      } else {
        missing.add(symbol);
      }
    }

    // 라이브러리 정점은 자기 소스 URI를 sourceUri로 들고 있지 않다(ID가
    // 스킴 URI다 — `package:`/`project:`). 선언 씨앗의 `::` 앞 접두로 라이브러리
    // 씨앗을 함께 세워야 import/export 역방향 전파가 씨앗에서 시작한다.
    for (final seed in seeds.toList()) {
      final separator = seed.indexOf('::');
      if (separator < 0) continue;
      final library = seed.substring(0, separator);
      if (nodeById[library]?.isLibrary ?? false) seeds.add(library);
    }

    final unattributed =
        changedSources.where((source) => !attributed.contains(source)).toList()
          ..sort();
    final sortedSeeds = seeds.toList()..sort();

    final reverse = <String, List<GraphEdge>>{};
    for (final edge in graph.edges) {
      if (!edge.kind.impliesUsage) continue;
      (reverse[edge.targetId] ??= <GraphEdge>[]).add(edge);
    }
    for (final list in reverse.values) {
      // GraphSnapshot이 간선을 정렬하지만 결정성을 이 모듈 안에서 보증한다.
      list.sort((a, b) {
        final bySource = a.sourceId.compareTo(b.sourceId);
        if (bySource != 0) return bySource;
        return a.kind.name.compareTo(b.kind.name);
      });
    }

    final depths = <String, int>{for (final seed in sortedSeeds) seed: 0};
    final paths = <String, List<String>>{
      for (final seed in sortedSeeds) seed: [seed],
    };
    final queue = <String>[...sortedSeeds];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final current = queue[cursor];
      final currentDepth = depths[current]!;
      if (maxDepth != null && currentDepth >= maxDepth) continue;
      for (final edge in reverse[current] ?? const <GraphEdge>[]) {
        final dependent = edge.sourceId;
        if (depths.containsKey(dependent)) continue;
        depths[dependent] = currentDepth + 1;
        paths[dependent] = [dependent, ...paths[current]!];
        queue.add(dependent);
      }
    }

    final impacted = <ImpactedSymbol>[];
    // 테스트는 파일 단위로 중복 없이 보고한다(같은 파일의 여러 선언이 영향을
    // 받아도 재실행 대상 테스트는 하나다). 가장 얕은 깊이를 대표로 남긴다.
    final testsBySource = <String, ImpactedTest>{};
    for (final id in depths.keys.where((id) => depths[id]! > 0)) {
      final node = nodeById[id];
      if (node == null) continue;
      final source = node.sourceUri;
      final depth = depths[id]!;
      final path = paths[id]!;
      final path0 = source == null ? null : _toPath(source);
      final level = _symbolRisk(depth, node);
      impacted.add(
        ImpactedSymbol(
          id: id,
          kind: node.isLibrary ? 'file' : 'declaration',
          depth: depth,
          path: path,
          riskScore: level.$2,
          riskLevel: level.$1,
          source: path0,
          line: node.line,
          column: node.column,
        ),
      );
      if (source != null && _isTestSource(_toPath(source))) {
        final key = path0!;
        final existing = testsBySource[key];
        if (existing == null || depth < existing.depth) {
          testsBySource[key] = ImpactedTest(
            id: id,
            depth: depth,
            path: path,
            source: path0,
          );
        }
      }
    }
    impacted.sort((a, b) {
      final byDepth = a.depth.compareTo(b.depth);
      if (byDepth != 0) return byDepth;
      return a.id.compareTo(b.id);
    });
    final tests = testsBySource.values.toList()
      ..sort((a, b) {
        final byDepth = a.depth.compareTo(b.depth);
        if (byDepth != 0) return byDepth;
        return a.id.compareTo(b.id);
      });

    final changedDeclarations = <String>{
      for (final seed in sortedSeeds)
        if (!(nodeById[seed]?.isLibrary ?? false)) seed,
    };
    final callSites = <ImpactCallSite>[];
    for (final edge in graph.edges) {
      if (!edge.kind.impliesUsage) continue;
      if (!changedDeclarations.contains(edge.targetId)) continue;
      if (!depths.containsKey(edge.sourceId) || depths[edge.sourceId] == 0) {
        continue;
      }
      final from = nodeById[edge.sourceId];
      callSites.add(
        ImpactCallSite(
          fromId: edge.sourceId,
          toId: edge.targetId,
          kind: edge.kind.name,
          fromSource: from?.sourceUri == null
              ? null
              : _toPath(from!.sourceUri!),
          fromLine: from?.line,
          fromColumn: from?.column,
          fromIsLibrary: from?.isLibrary ?? false,
        ),
      );
    }
    callSites.sort((a, b) {
      final byTarget = a.toId.compareTo(b.toId);
      if (byTarget != 0) return byTarget;
      final byFrom = a.fromId.compareTo(b.fromId);
      if (byFrom != 0) return byFrom;
      return a.kind.compareTo(b.kind);
    });

    final risk = _risk(
      graph: graph,
      seeds: sortedSeeds,
      changedDeclarations: changedDeclarations,
      impacted: impacted,
      tests: tests,
      nodeById: nodeById,
      reverse: reverse,
    );

    final shown = limit == null ? impacted : impacted.take(limit).toList();
    final truncatedCount = impacted.length - shown.length;

    return ImpactReport(
      changedLibraries: sortedSeeds
          .where((id) => nodeById[id]?.isLibrary ?? false)
          .toList(),
      changedSymbols: sortedSeeds
          .where((id) => !(nodeById[id]?.isLibrary ?? false))
          .toList(),
      changedSources: changedSources.toList()..sort(),
      unattributedSources: unattributed,
      missingSymbols: missing.toList()..sort(),
      impacted: shown,
      callSites: callSites,
      tests: tests,
      risk: risk,
      coverage: ImpactCoverage(
        directlyChangedSymbols: changedDeclarations.length,
        transitivelyImpacted: impacted.length,
        relatedTests: tests.length,
        missedWithoutPrecheck: [for (final item in impacted) item.id],
      ),
      truncatedImpacted: truncatedCount,
    );
  }

  /// 개별 심볼의 위험도: 깊을수록 위험이 낮다(간접적 영향).
  static (String, int) _symbolRisk(int depth, GraphNode node) {
    var score = 100 - (depth - 1) * 15;
    if (node.isLibrary) score -= 10;
    if (node.synthesized) score -= 5;
    if (score < 1) score = 1;
    if (score > 100) score = 100;
    final level = score >= 67
        ? 'high'
        : score >= 34
        ? 'medium'
        : 'low';
    return (level, score);
  }

  static ImpactRisk _risk({
    required GraphSnapshot graph,
    required List<String> seeds,
    required Set<String> changedDeclarations,
    required List<ImpactedSymbol> impacted,
    required List<ImpactedTest> tests,
    required Map<String, GraphNode> nodeById,
    required Map<String, List<GraphEdge>> reverse,
  }) {
    final factors = <ImpactRiskFactor>[];

    var inbound = 0;
    for (final edge in graph.edges) {
      if (!edge.kind.impliesUsage) continue;
      if (changedDeclarations.contains(edge.targetId)) inbound++;
    }
    factors.add(
      ImpactRiskFactor(
        name: 'inbound-references',
        weight: inbound > 30 ? 30 : inbound,
        detail: '$inbound usage edge(s) point at changed declarations',
      ),
    );

    final maxDepth = impacted.isEmpty
        ? 0
        : impacted.map((item) => item.depth).reduce((a, b) => a > b ? a : b);
    final depthWeight = maxDepth * 4 > 20 ? 20 : maxDepth * 4;
    factors.add(
      ImpactRiskFactor(
        name: 'impact-depth',
        weight: depthWeight,
        detail: 'deepest affected symbol is $maxDepth usage edge(s) away',
      ),
    );

    final breadth = impacted.length;
    final breadthWeight = breadth ~/ 2 > 15 ? 15 : breadth ~/ 2;
    factors.add(
      ImpactRiskFactor(
        name: 'impact-breadth',
        weight: breadthWeight,
        detail: '$breadth symbol(s) depend on the changed set',
      ),
    );

    final publicChanged = changedDeclarations.where((id) {
      final name = _declarationName(id);
      return name != null && !name.startsWith('_');
    }).length;
    final publicWeight = publicChanged > 5 ? 5 : publicChanged;
    factors.add(
      ImpactRiskFactor(
        name: 'public-api-surface',
        weight: publicWeight,
        detail: '$publicChanged changed declaration(s) have public names',
      ),
    );

    final noTestWeight = (changedDeclarations.isNotEmpty && tests.isEmpty)
        ? 25
        : 0;
    factors.add(
      ImpactRiskFactor(
        name: 'test-coverage',
        weight: noTestWeight,
        detail: tests.isEmpty
            ? 'no test library depends on the changed set'
            : '${tests.length} test library(ies) depend on the changed set',
      ),
    );

    final cyclicWeight = _hasCyclicSeed(seeds, graph) ? 15 : 0;
    factors.add(
      ImpactRiskFactor(
        name: 'cycle-participation',
        weight: cyclicWeight,
        detail: cyclicWeight == 0
            ? 'no changed seed participates in a usage cycle'
            : 'at least one changed seed participates in a usage cycle',
      ),
    );

    factors.sort((a, b) {
      final byWeight = b.weight.compareTo(a.weight);
      if (byWeight != 0) return byWeight;
      return a.name.compareTo(b.name);
    });
    var score = 0;
    for (final factor in factors) {
      score += factor.weight;
    }
    if (score > 100) score = 100;
    final level = score >= 67
        ? 'high'
        : score >= 34
        ? 'medium'
        : 'low';
    return ImpactRisk(score: score, level: level, factors: factors);
  }

  /// 씨앗이 사용 간선을 따라 자기 자신으로 돌아오면 순환에 참여한다.
  static bool _hasCyclicSeed(List<String> seeds, GraphSnapshot graph) {
    if (seeds.isEmpty) return false;
    final forward = <String, List<String>>{};
    for (final edge in graph.edges) {
      if (!edge.kind.impliesUsage) continue;
      (forward[edge.sourceId] ??= <String>[]).add(edge.targetId);
    }
    // 씨앗 수를 상한해 대형 변경 집합에서 O(seeds×(V+E))가 폭주하지 않게 한다.
    for (final seed in seeds.take(50)) {
      final seen = <String>{};
      final queue = <String>[seed];
      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        for (final next in forward[current] ?? const <String>[]) {
          if (next == seed) return true;
          if (seen.add(next)) queue.add(next);
        }
      }
    }
    return false;
  }

  static String? _declarationName(String id) {
    final separator = id.lastIndexOf('::');
    if (separator < 0) return null;
    return id.substring(separator + 2);
  }

  /// `project:` 센티널을 벗겨 프로젝트 상대 경로를 남긴다.
  static String _toPath(String sourceUri) => sourceUri.startsWith('project:')
      ? sourceUri.substring('project:'.length)
      : sourceUri;

  /// 테스트 디렉터리 소스인지 판정한다.
  static bool _isTestSource(String path) =>
      path.startsWith('test/') ||
      path.startsWith('integration_test/') ||
      path.startsWith('test_driver/');
}
