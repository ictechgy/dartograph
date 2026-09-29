/// isthmus `language-traversal` v1용 다중 root 순회다(isthmus
/// `docs/LANGUAGE-TRAVERSAL.md`).
///
/// root마다 따로 순회하지 않고 한 번에 계산한다.
/// - depth·via: 정점마다 가장 가까운 서로 다른 root 두 개를 기록하는 다중 출발
///   BFS다. 두 번째 root는 "다른 root에서 닿은 root" 항목의 depth(자기 제외
///   기준)를 구하는 데 쓴다.
/// - roots·evidence: 등급별 간선 부분 그래프를 강연결요소로 접고 위상 순서로
///   root 비트 집합을 전파한다. 정점의 evidence는 그 정점에 닿는 모든 root가
///   direct 부분 그래프에서도 닿는지로 정한다(root마다 가장 강한 등급의 최솟값).
///
/// 간선 등급: 그래프의 사용 간선(call·reference·inheritance·implements·mixin·
/// override·import·export)은 analyzer가 해석한 관계라 `direct`다. 재정의
/// 멤버와 기반 멤버 사이의 동적 디스패치(기반 멤버를 부르는 호출이 재정의
/// 멤버로 갈 수 있음)는 가능성만 있어 `candidate`다. 주입된 구현의 전체 흐름을
/// 증명하지 않으므로 `bound`는 내지 않는다.
library;

import 'dart:collection';
import 'dart:typed_data';

import '../core/graph_edge.dart';
import '../core/graph_node.dart';
import '../core/graph_snapshot.dart';

/// 순회 방향이다. [dependencies]는 root가 기대는 쪽(호출·참조 대상),
/// [dependents]는 root에 기대는 쪽(호출자·참조자)이다.
enum TraversalDirection {
  /// root가 기대는 쪽이다.
  dependencies,

  /// root에 기대는 쪽이다.
  dependents,
}

/// 도달 정점의 근거 등급이다. `direct ⊂ candidate`로 간선 집합이 포개진다.
enum TraversalEvidence {
  /// analyzer가 해석한 간선만으로 닿는다.
  direct,

  /// 동적 디스패치 후보 간선을 하나 이상 거쳐야 닿는 root가 있다.
  candidate,
}

/// 순회의 시작점이다. [node]가 null이면 `root-not-found`다.
final class TraversalRoot {
  /// 요청 [id]와 해석한 [node]로 만든다.
  const TraversalRoot(this.id, this.node);

  /// 생산자 id다. 해석한 root면 정점 id, 못 한 요청이면 원문이다.
  final String id;

  /// 해석한 정점이다.
  final GraphNode? node;
}

/// 순회가 도달한 정점 하나다.
final class TraversalReached {
  /// 필드를 받는다.
  const TraversalReached({
    required this.node,
    required this.via,
    required this.depth,
    required this.roots,
    required this.relationships,
    required this.evidence,
  });

  /// 도달한 정점이다.
  final GraphNode node;

  /// 가장 짧은 경로 하나의 직전 정점(root id 또는 다른 도달 정점의 id)이다.
  final String via;

  /// 이 정점에 닿는 가장 가까운(자기 제외) root까지의 간선 수다.
  final int depth;

  /// 이 정점에 닿는 모든(자기 제외) root 인덱스의 오름차순 전체 목록이다.
  final List<int> roots;

  /// via → 이 정점 사이의 간선 관계 이름이다(정렬).
  final List<String> relationships;

  /// root마다 가장 강한 등급을 구한 뒤 그중 가장 약한 것이다.
  final TraversalEvidence evidence;
}

/// 한 번의 다중 root 순회 결과다. [reached]는 (depth, id) 오름차순이다.
final class LanguageTraversalResult {
  /// 필드를 받는다.
  const LanguageTraversalResult({
    required this.direction,
    required this.roots,
    required this.reached,
    required this.depthTruncated,
    required this.reachedTruncated,
  });

  /// 순회 방향이다.
  final TraversalDirection direction;

  /// 입력 순서의 root다(중복 제거).
  final List<TraversalRoot> roots;

  /// 목록에 실린 도달 정점이다.
  final List<TraversalReached> reached;

  /// depth 상한 밖의 도달 정점이 있어 목록에서 빠졌는지다.
  final bool depthTruncated;

  /// 도달 정점 상한으로 목록이 잘렸는지다.
  final bool reachedTruncated;

  /// 해석하지 못한 root 요청이 있는지다.
  bool get rootNotFound => roots.any((root) => root.node == null);
}

/// 교환 형식의 상한과 순회 진입점이다.
abstract final class LanguageTraversal {
  /// 교환 형식의 depth 상한이다.
  static const maxDepth = 128;

  /// 교환 형식의 도달 정점 상한이다.
  static const maxReached = 100000;

  /// 교환 형식의 root 상한이다.
  static const maxRoots = 10000;

  /// 디스패치 후보 간선의 관계 이름이다.
  static const dispatchRelationship = 'dispatch';

  /// [requested] root에서 [direction]으로 한 번 순회한다.
  ///
  /// root는 그래프 정점 id와 정확히 같아야 한다(이름으로 추측하지 않는다).
  /// 같은 정점을 가리키는 뒤 요청은 버린다.
  static LanguageTraversalResult traverse(
    GraphSnapshot graph,
    List<String> requested,
    TraversalDirection direction, {
    int depthLimit = maxDepth,
    int reachedLimit = maxReached,
  }) {
    final space = _TraversalSpace(graph, direction);
    final roots = _resolveRoots(space, requested);
    final vertices = [for (final root in roots) space.indexOf(root.node)];
    final computation = _Computation(space, vertices, depthLimit)..run();
    final rows = [
      for (final row in computation.rows) row.toReached(space, roots),
    ];
    final capped = _cap(rows, roots, reachedLimit);
    return LanguageTraversalResult(
      direction: direction,
      roots: roots,
      reached: capped,
      depthTruncated: computation.depthTruncated,
      reachedTruncated: capped.length < rows.length,
    );
  }

  static List<TraversalRoot> _resolveRoots(
    _TraversalSpace space,
    List<String> requested,
  ) {
    final seen = <String>{};
    return [
      for (final text in requested)
        if (seen.add(text)) TraversalRoot(text, space.nodeById[text]),
    ];
  }

  /// 도달 정점 상한을 (depth, id) 순서로 적용한다. via가 잘린 정점을 가리키는
  /// 항목(순환 root 항목뿐)은 함께 뺀다.
  static List<TraversalReached> _cap(
    List<TraversalReached> rows,
    List<TraversalRoot> roots,
    int limit,
  ) {
    if (rows.length <= limit) return rows;
    final rootIds = {for (final root in roots) root.id};
    var kept = rows.take(limit).toList();
    while (true) {
      final ids = {for (final row in kept) row.node.id};
      final valid = [
        for (final row in kept)
          if (rootIds.contains(row.via) || ids.contains(row.via)) row,
      ];
      if (valid.length == kept.length) return kept;
      kept = valid;
    }
  }
}

/// 인덱스 기반 인접 목록이다. 레벨 0은 direct, 레벨 1은 디스패치 후보다.
final class _TraversalSpace {
  _TraversalSpace(GraphSnapshot graph, TraversalDirection direction)
    : nodes = graph.nodes,
      nodeById = {for (final node in graph.nodes) node.id: node} {
    for (var index = 0; index < nodes.length; index++) {
      _index[nodes[index].id] = index;
    }
    for (final edge in graph.edges) {
      _addEdge(edge, direction);
    }
    direct = _adjacency(_directEdges);
    full = _adjacency([..._directEdges, ..._candidateEdges]);
    predecessors = _adjacency([
      for (final (from, to) in [..._directEdges, ..._candidateEdges])
        (to, from),
    ]);
  }

  final List<GraphNode> nodes;
  final Map<String, GraphNode> nodeById;
  final _index = <String, int>{};
  final _directEdges = <(int, int)>[];
  final _candidateEdges = <(int, int)>[];
  final _relationships = <int, SplayTreeSet<String>>{};

  /// direct 간선만 쓴 후속 정점이다.
  late final List<Int32List> direct;

  /// 모든 간선을 쓴 후속 정점이다.
  late final List<Int32List> full;

  /// 모든 간선을 쓴 선행 정점이다.
  late final List<Int32List> predecessors;

  int indexOf(GraphNode? node) => node == null ? -1 : _index[node.id]!;

  void _addEdge(GraphEdge edge, TraversalDirection direction) {
    if (!edge.kind.impliesUsage || edge.sourceId == edge.targetId) return;
    final source = _index[edge.sourceId]!;
    final target = _index[edge.targetId]!;
    final forward = direction == TraversalDirection.dependencies;
    _link(
      _directEdges,
      forward ? source : target,
      forward ? target : source,
      edge.kind.name,
    );
    if (edge.kind == EdgeKind.override) {
      // 기반 멤버를 부르는 호출은 재정의 멤버로 디스패치될 수 있다.
      _link(
        _candidateEdges,
        forward ? target : source,
        forward ? source : target,
        LanguageTraversal.dispatchRelationship,
      );
    }
  }

  void _link(List<(int, int)> edges, int from, int to, String relationship) {
    edges.add((from, to));
    (_relationships[from * nodes.length + to] ??= SplayTreeSet()).add(
      relationship,
    );
  }

  List<String> relationshipsOf(int from, int to) =>
      _relationships[from * nodes.length + to]?.toList() ?? const [];

  List<Int32List> _adjacency(List<(int, int)> edges) {
    final lists = List.generate(nodes.length, (_) => SplayTreeSet<int>());
    for (final (from, to) in edges) {
      lists[from].add(to);
    }
    return [for (final list in lists) Int32List.fromList(list.toList())];
  }
}

/// 목록에 실을 도달 정점 한 줄의 인덱스 표현이다.
final class _Row {
  const _Row(
    this.vertex,
    this.viaRoot,
    this.viaVertex,
    this.depth,
    this.roots,
    this.evidence,
  );

  final int vertex;

  /// via가 root면 그 root 인덱스, 아니면 -1이다.
  final int viaRoot;

  /// via 정점 인덱스다.
  final int viaVertex;
  final int depth;
  final List<int> roots;
  final TraversalEvidence evidence;

  TraversalReached toReached(
    _TraversalSpace space,
    List<TraversalRoot> roots,
  ) => TraversalReached(
    node: space.nodes[vertex],
    via: viaRoot >= 0 ? roots[viaRoot].id : space.nodes[viaVertex].id,
    depth: depth,
    roots: this.roots,
    relationships: space.relationshipsOf(viaVertex, vertex),
    evidence: evidence,
  );
}

/// 다중 출발 BFS와 등급별 도달 비트 집합으로 도달 정점을 한 번에 계산한다.
final class _Computation {
  _Computation(this.space, this.rootVertices, this.depthLimit)
    : _size = space.nodes.length {
    _rootOf = Int32List(_size)..fillRange(0, _size, -1);
    for (var root = 0; root < rootVertices.length; root++) {
      final vertex = rootVertices[root];
      if (vertex >= 0) _rootOf[vertex] = root;
    }
    _firstRoot = Int32List(_size)..fillRange(0, _size, -1);
    _firstDistance = Int32List(_size)..fillRange(0, _size, -1);
    _secondRoot = Int32List(_size)..fillRange(0, _size, -1);
    _secondDistance = Int32List(_size)..fillRange(0, _size, -1);
  }

  final _TraversalSpace space;
  final List<int> rootVertices;
  final int depthLimit;
  final int _size;
  late final Int32List _rootOf;
  late final Int32List _firstRoot;
  late final Int32List _firstDistance;
  late final Int32List _secondRoot;
  late final Int32List _secondDistance;

  final rows = <_Row>[];
  var depthTruncated = false;

  void run() {
    _nearestRoots();
    final direct = _ReachSets.compute(space.direct, rootVertices, _size);
    final full = _ReachSets.compute(space.full, rootVertices, _size);
    for (var vertex = 0; vertex < _size; vertex++) {
      final roots = full.rootsOf(vertex);
      if (_rootOf[vertex] >= 0) roots.remove(_rootOf[vertex]);
      if (roots.isEmpty) continue;
      final row = _row(vertex, roots, direct.rootsOf(vertex));
      if (row == null) {
        depthTruncated = true;
      } else {
        rows.add(row);
      }
    }
    rows.sort((a, b) {
      final byDepth = a.depth.compareTo(b.depth);
      if (byDepth != 0) return byDepth;
      return space.nodes[a.vertex].id.compareTo(space.nodes[b.vertex].id);
    });
  }

  /// 가장 가까운 서로 다른 root 두 개를 BFS 순서로 기록한다.
  void _nearestRoots() {
    final queue = Queue<(int, int, int)>();
    for (var root = 0; root < rootVertices.length; root++) {
      final vertex = rootVertices[root];
      if (vertex >= 0 && _accept(vertex, root, 0)) queue.add((vertex, root, 0));
    }
    while (queue.isNotEmpty) {
      final (vertex, root, distance) = queue.removeFirst();
      if (distance >= depthLimit) continue;
      for (final next in space.full[vertex]) {
        if (_accept(next, root, distance + 1)) {
          queue.add((next, root, distance + 1));
        }
      }
    }
  }

  bool _accept(int vertex, int root, int distance) {
    if (_firstRoot[vertex] == -1) {
      _firstRoot[vertex] = root;
      _firstDistance[vertex] = distance;
      return true;
    }
    if (_firstRoot[vertex] == root || _secondRoot[vertex] != -1) return false;
    _secondRoot[vertex] = root;
    _secondDistance[vertex] = distance;
    return true;
  }

  /// [excluded] root를 뺀 가장 가까운 root까지의 거리다. 없으면 -1이다.
  int _distanceExcluding(int vertex, int excluded) =>
      _firstRoot[vertex] != excluded
      ? _firstDistance[vertex]
      : _secondDistance[vertex];

  /// root가 아닌 정점은 BFS 거리 그대로, root 정점은 자기 거리가 0이므로
  /// 선행 정점의 (자기 제외) 거리로 구한다.
  int _distance(int vertex, int own) {
    if (own < 0) return _firstDistance[vertex];
    var best = -1;
    for (final predecessor in space.predecessors[vertex]) {
      final distance = _distanceExcluding(predecessor, own);
      if (distance >= 0 && (best < 0 || distance + 1 < best)) {
        best = distance + 1;
      }
    }
    return best;
  }

  _Row? _row(int vertex, SplayTreeSet<int> roots, SplayTreeSet<int> direct) {
    final own = _rootOf[vertex];
    final depth = _distance(vertex, own);
    if (depth < 1 || depth > depthLimit) return null;
    int? via;
    for (final predecessor in space.predecessors[vertex]) {
      final distance = own < 0
          ? _firstDistance[predecessor]
          : _distanceExcluding(predecessor, own);
      if (distance != depth - 1) continue;
      if (via == null ||
          space.nodes[predecessor].id.compareTo(space.nodes[via].id) < 0) {
        via = predecessor;
      }
    }
    final evidence = direct.containsAll(roots)
        ? TraversalEvidence.direct
        : TraversalEvidence.candidate;
    return _Row(
      vertex,
      depth == 1 ? _rootOf[via!] : -1,
      via!,
      depth,
      roots.toList(),
      evidence,
    );
  }
}

/// 한 간선 부분 그래프에서 정점마다 닿는 root 비트 집합이다. root에서 닿는
/// 정점만 강연결요소로 접고, 위상 순서대로 선행 요소의 비트를 합친다.
final class _ReachSets {
  _ReachSets._(this._component, this._bits);

  final Int32List _component;
  final List<_Bits> _bits;

  /// 정점에 닿는 root 인덱스의 사본이다. 닿지 않으면 빈 집합이다.
  SplayTreeSet<int> rootsOf(int vertex) {
    final component = _component[vertex];
    return component < 0 ? SplayTreeSet() : _bits[component].toSet();
  }

  static _ReachSets compute(
    List<Int32List> successors,
    List<int> rootVertices,
    int size,
  ) {
    final starts = [
      for (final vertex in rootVertices)
        if (vertex >= 0) vertex,
    ];
    final scc = _StronglyConnected(successors, size)..visitAll(starts);
    final bits = List.generate(
      scc.members.length,
      (_) => _Bits(rootVertices.length),
    );
    for (var root = 0; root < rootVertices.length; root++) {
      final vertex = rootVertices[root];
      if (vertex >= 0) bits[scc.componentOf[vertex]].add(root);
    }
    // Tarjan은 역위상 순서로 요소를 낸다. 큰 번호부터 처리하면 선행 요소가 먼저 끝난다.
    for (var component = scc.members.length - 1; component >= 0; component--) {
      for (final vertex in scc.members[component]) {
        for (final next in successors[vertex]) {
          final target = scc.componentOf[next];
          if (target != component) bits[target].or(bits[component]);
        }
      }
    }
    return _ReachSets._(scc.componentOf, bits);
  }
}

/// 고정 길이 비트 집합이다.
final class _Bits {
  _Bits(int length) : _words = Uint32List((length + 31) >> 5);

  final Uint32List _words;

  void add(int index) => _words[index >> 5] |= 1 << (index & 31);

  void or(_Bits other) {
    for (var index = 0; index < _words.length; index++) {
      _words[index] |= other._words[index];
    }
  }

  SplayTreeSet<int> toSet() {
    final result = SplayTreeSet<int>();
    for (var word = 0; word < _words.length; word++) {
      var value = _words[word];
      while (value != 0) {
        final bit = value & -value;
        result.add((word << 5) + bit.bitLength - 1);
        value ^= bit;
      }
    }
    return result;
  }
}

/// 출발 정점에서 닿는 부분 그래프의 반복형 Tarjan 강연결요소다.
final class _StronglyConnected {
  _StronglyConnected(this.successors, int size)
    : componentOf = Int32List(size)..fillRange(0, size, -1),
      _order = Int32List(size)..fillRange(0, size, -1),
      _low = Int32List(size),
      _onStack = List.filled(size, false);

  final List<Int32List> successors;

  /// 정점의 요소 번호다. 닿지 않으면 -1이다.
  final Int32List componentOf;

  /// 요소별 정점이다(역위상 순서).
  final members = <List<int>>[];
  final Int32List _order;
  final Int32List _low;
  final List<bool> _onStack;
  final _stack = <int>[];
  var _counter = 0;

  void visitAll(List<int> starts) {
    for (final start in starts) {
      if (_order[start] == -1) _visit(start);
    }
  }

  void _visit(int start) {
    final frames = <List<int>>[_open(start)];
    while (frames.isNotEmpty) {
      final frame = frames.last;
      final vertex = frame[0];
      if (frame[1] < successors[vertex].length) {
        final next = successors[vertex][frame[1]++];
        if (_order[next] == -1) {
          frames.add(_open(next));
        } else if (_onStack[next] && _order[next] < _low[vertex]) {
          _low[vertex] = _order[next];
        }
        continue;
      }
      frames.removeLast();
      if (frames.isNotEmpty) {
        final parent = frames.last[0];
        if (_low[vertex] < _low[parent]) _low[parent] = _low[vertex];
      }
      if (_low[vertex] == _order[vertex]) _close(vertex);
    }
  }

  List<int> _open(int vertex) {
    _order[vertex] = _counter;
    _low[vertex] = _counter++;
    _stack.add(vertex);
    _onStack[vertex] = true;
    return [vertex, 0];
  }

  void _close(int root) {
    final component = <int>[];
    int vertex;
    do {
      vertex = _stack.removeLast();
      _onStack[vertex] = false;
      componentOf[vertex] = members.length;
      component.add(vertex);
    } while (vertex != root);
    members.add(component);
  }
}
