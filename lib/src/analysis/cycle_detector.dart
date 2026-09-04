import '../core/graph_edge.dart';
import '../core/graph_snapshot.dart';

/// 보고된 순환과 이를 재현하는 간선 근거다.
final class DependencyCycle {
  /// 강결합 요소에서 복원한 대표 순환을 만든다.
  const DependencyCycle({
    required this.component,
    required this.path,
    required this.evidence,
    required this.breakCandidate,
  });

  /// 서로 도달 가능한 정점의 결정적 목록이다.
  final List<String> component;

  /// 시작 정점을 마지막에 반복하는 대표 순환 경로다.
  final List<String> path;

  /// [path]의 각 단계를 입증하는 실제 그래프 간선이다.
  final List<CycleEdgeEvidence> evidence;

  /// 순환을 끊기 위해 검토할 결정적으로 선택된 간선이다.
  final CycleEdgeEvidence breakCandidate;

  /// 리포터가 키 순서를 통제할 수 있는 값으로 바꾼다.
  Map<String, Object> toJson() => {
    'breakCandidate': breakCandidate.toJson(),
    'component': component,
    'evidence': evidence.map((edge) => edge.toJson()).toList(),
    'path': path,
  };
}

/// 순환 판정에 사용된 간선의 직렬화 가능한 근거다.
final class CycleEdgeEvidence {
  /// 그래프 간선에서 안정적인 근거 값을 만든다.
  const CycleEdgeEvidence(this.from, this.to, this.kind);

  /// 간선 출발 정점이다.
  final String from;

  /// 간선 도착 정점이다.
  final String to;

  /// 간선 관계다.
  final EdgeKind kind;

  /// 결정적인 JSON 필드 값을 만든다.
  Map<String, String> toJson() => {'from': from, 'kind': kind.name, 'to': to};
}

final class _Frame {
  _Frame(this.node, this.successors);

  final String node;
  final List<String> successors;
  int next = 0;
}

/// 재귀 호출 없이 Tarjan SCC를 계산하고 대표 순환을 복원한다.
final class CycleDetector {
  /// 사용 의미가 있는 간선에서 모든 순환을 결정적으로 찾는다.
  List<DependencyCycle> detect(GraphSnapshot graph) {
    final edges = graph.edges.where((edge) => edge.kind.impliesUsage).toList();
    final outgoing = <String, List<GraphEdge>>{};
    for (final edge in edges) {
      outgoing.putIfAbsent(edge.sourceId, () => []).add(edge);
    }
    final successors = <String, List<String>>{};
    for (final node in graph.nodes) {
      successors[node.id] =
          (outgoing[node.id] ?? const [])
              .map((edge) => edge.targetId)
              .toSet()
              .toList()
            ..sort();
    }

    var nextIndex = 0;
    final indices = <String, int>{};
    final lowLinks = <String, int>{};
    final componentStack = <String>[];
    final onStack = <String>{};
    final components = <List<String>>[];

    for (final root in graph.nodes.map((node) => node.id)) {
      if (indices.containsKey(root)) continue;
      final frames = <_Frame>[];
      void enter(String node) {
        indices[node] = nextIndex;
        lowLinks[node] = nextIndex++;
        componentStack.add(node);
        onStack.add(node);
        frames.add(_Frame(node, successors[node]!));
      }

      enter(root);
      while (frames.isNotEmpty) {
        final frame = frames.last;
        if (frame.next < frame.successors.length) {
          final target = frame.successors[frame.next++];
          if (!indices.containsKey(target)) {
            enter(target);
          } else if (onStack.contains(target)) {
            lowLinks[frame.node] = _min(
              lowLinks[frame.node]!,
              indices[target]!,
            );
          }
          continue;
        }

        frames.removeLast();
        if (lowLinks[frame.node] == indices[frame.node]) {
          final component = <String>[];
          while (componentStack.isNotEmpty) {
            final popped = componentStack.removeLast();
            onStack.remove(popped);
            component.add(popped);
            if (popped == frame.node) break;
          }
          component.sort();
          final selfLoop =
              component.length == 1 &&
              (outgoing[component.single] ?? const []).any(
                (edge) => edge.targetId == component.single,
              );
          if (component.length > 1 || selfLoop) components.add(component);
        }
        if (frames.isNotEmpty) {
          final parent = frames.last.node;
          lowLinks[parent] = _min(lowLinks[parent]!, lowLinks[frame.node]!);
        }
      }
    }

    components.sort(_compareLists);
    return components
        .map((component) {
          final path = _cyclePath(component, successors);
          final evidence = <CycleEdgeEvidence>[];
          for (var index = 0; index < path.length - 1; index++) {
            final candidates =
                outgoing[path[index]]!
                    .where((edge) => edge.targetId == path[index + 1])
                    .toList()
                  ..sort((a, b) => a.kind.name.compareTo(b.kind.name));
            final edge = candidates.first;
            evidence.add(
              CycleEdgeEvidence(edge.sourceId, edge.targetId, edge.kind),
            );
          }
          return DependencyCycle(
            component: List.unmodifiable(component),
            path: List.unmodifiable(path),
            evidence: List.unmodifiable(evidence),
            breakCandidate: evidence.first,
          );
        })
        .toList(growable: false);
  }
}

List<String> _cyclePath(
  List<String> component,
  Map<String, List<String>> successors,
) {
  final start = component.first;
  final members = component.toSet();
  if (component.length == 1) return [start, start];
  final queue = <String>[start];
  final previous = <String, String?>{start: null};
  var head = 0;
  while (head < queue.length) {
    final current = queue[head++];
    for (final target in successors[current]!.where(members.contains)) {
      if (target == start && current != start) {
        final reversed = <String>[current];
        var cursor = previous[current];
        while (cursor != null) {
          reversed.add(cursor);
          cursor = previous[cursor];
        }
        return [...reversed.reversed, start];
      }
      if (!previous.containsKey(target)) {
        previous[target] = current;
        queue.add(target);
      }
    }
  }
  throw StateError('SCC did not contain a recoverable cycle.');
}

int _min(int a, int b) => a < b ? a : b;

int _compareLists(List<String> a, List<String> b) {
  for (var index = 0; index < a.length && index < b.length; index++) {
    final order = a[index].compareTo(b[index]);
    if (order != 0) return order;
  }
  return a.length.compareTo(b.length);
}
