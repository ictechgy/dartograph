import '../core/graph_edge.dart';
import '../core/graph_snapshot.dart';

/// 영향 전파로 도달한 라이브러리와 그 의존 사슬 근거다.
final class AffectedLibrary {
  /// 최단 의존 사슬을 가진 피영향 라이브러리를 만든다.
  const AffectedLibrary({
    required this.id,
    required this.depth,
    required this.path,
  });

  /// 영향받은 라이브러리 ID다.
  final String id;

  /// 가장 가까운 변경 라이브러리까지 import·export 건너뛰기 수다.
  final int depth;

  /// 피영향 라이브러리에서 시작해 변경 라이브러리에서 끝나는 최단 의존 사슬이다.
  final List<String> path;

  /// 알파벳 키 순서 JSON으로 직렬화한다.
  Map<String, Object> toJson() => {'depth': depth, 'id': id, 'path': path};
}

/// 변경 라이브러리와 전이적 종속자 계산 결과다.
final class AffectedResult {
  /// 영향 반경 결과를 만든다.
  const AffectedResult({
    required this.changed,
    required this.affected,
    required this.unattributedSources,
  });

  /// 변경 소스가 귀속된 라이브러리 ID(정렬)다. part 파일의 변경은
  /// 호스트 라이브러리로 귀속된다.
  final List<String> changed;

  /// 변경 라이브러리에 import·export로 전이적으로 의존하는 라이브러리다.
  final List<AffectedLibrary> affected;

  /// 매치됐지만 라이브러리 노드로 귀속되지 못한 변경 소스(정렬)다.
  /// 호출자가 조용한 누락 대신 한계로 보고할 수 있게 돌려준다.
  final List<String> unattributedSources;
}

/// Git 기준점 이후 변경된 라이브러리와 그 영향 반경을 계산한다.
abstract final class AffectedAnalysis {
  /// [changedSources](`project:` 소스 URI 집합)가 귀속되는 라이브러리를 씨앗으로
  /// import·export 간선을 역방향으로 건너 전이적 종속자를 모은다.
  ///
  /// 영향 반경은 라이브러리(파일) 수준 관측이다. 선언 단위 사용 간선은 따라가지
  /// 않으므로, 나열되지 않은 라이브러리의 개별 선언이 영향받지 않았다는 증명이
  /// 아니다. 여러 씨앗에서 닿는 종속자는 가장 가까운 씨앗 기준 최단 사슬 한 번만
  /// 보고하고, 동률은 정렬된 씨앗·간선 순서로 결정적으로 깨진다.
  static AffectedResult analyze(
    GraphSnapshot graph,
    Set<String> changedSources,
  ) {
    final nodeIds = <String>{for (final node in graph.nodes) node.id};
    final seeds = <String>{};
    final attributed = <String>{};
    for (final node in graph.nodes) {
      final source = node.sourceUri;
      if (source == null || !changedSources.contains(source)) continue;
      // 선언 노드의 라이브러리 접두는 part 파일 변경도 호스트 라이브러리로
      // 귀속시킨다(선언의 sourceUri는 실제 part 파일, ID는 호스트 라이브러리).
      final separator = node.id.indexOf('::');
      final library = separator < 0 ? node.id : node.id.substring(0, separator);
      if (nodeIds.contains(library)) {
        seeds.add(library);
        attributed.add(source);
      }
    }
    final unattributed =
        changedSources.where((source) => !attributed.contains(source)).toList()
          ..sort();
    final sortedSeeds = seeds.toList()..sort();

    final dependents = <String, List<String>>{};
    for (final edge in graph.edges) {
      if (edge.kind != EdgeKind.import && edge.kind != EdgeKind.export) {
        continue;
      }
      (dependents[edge.targetId] ??= <String>[]).add(edge.sourceId);
    }
    // GraphSnapshot이 간선을 정렬하지만 동률 경로의 결정성을 이 모듈 안에서
    // 보증한다(중개자 동률은 정렬된 인접 순서로 깨진다).
    for (final list in dependents.values) {
      list.sort();
    }

    final depths = <String, int>{for (final seed in sortedSeeds) seed: 0};
    final paths = <String, List<String>>{
      for (final seed in sortedSeeds) seed: [seed],
    };
    final queue = [...sortedSeeds];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final current = queue[cursor];
      for (final dependent in dependents[current] ?? const <String>[]) {
        if (depths.containsKey(dependent)) continue;
        depths[dependent] = depths[current]! + 1;
        paths[dependent] = [dependent, ...paths[current]!];
        queue.add(dependent);
      }
    }
    final affected =
        depths.keys
            .where((id) => depths[id]! > 0)
            .map(
              (id) =>
                  AffectedLibrary(id: id, depth: depths[id]!, path: paths[id]!),
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return AffectedResult(
      changed: sortedSeeds,
      affected: affected,
      unattributedSources: unattributed,
    );
  }
}
