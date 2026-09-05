import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/graph_comparison.dart';
import 'package:test/test.dart';

void main() {
  GraphSnapshot graph() => GraphSnapshot(
    nodes: [
      GraphNode(id: 'app::Root'),
      GraphNode(id: 'app::C'),
      GraphNode(id: 'app::C.live'),
      GraphNode(id: 'app::C.dead'),
    ],
    edges: const [
      GraphEdge(
        sourceId: 'app::Root',
        targetId: 'app::C.live',
        kind: EdgeKind.call,
      ),
      GraphEdge(
        sourceId: 'app::C',
        targetId: 'app::C.live',
        kind: EdgeKind.member,
      ),
    ],
  );
  test(
    'member-retained query names its witness and preserves usage direction',
    () {
      final result =
          SymbolQuerySession(
                graph: graph(),
                roots: const {'app::Root': RetentionReason.mainEntryPoint},
                limitations: const [],
              ).query('C')['result']
              as Map;
      final reachability = result['reachability'] as Map;
      expect(reachability['state'], 'retainedByMember');
      expect(reachability['witness'], 'app::C.live');
      expect(reachability['path'], ['app::Root', 'app::C.live']);
    },
  );
  test(
    'lost root explains member-retained container with prior witness and gaps',
    () {
      final doc = compareGraphs(
        before: graph(),
        after: graph(),
        beforeRoots: const {'app::Root': RetentionReason.mainEntryPoint},
        afterRoots: const {},
        beforeLimitations: const ['dynamic dispatch is incomplete'],
      );
      final change = (doc['newlyUnreachable'] as List).singleWhere(
        (f) => f['id'] == 'app::C',
      );
      expect(change['beforePath'], ['app::Root', 'app::C.live']);
      expect(change['retainedByMember'], 'app::C.live');
      expect(change['removedRootsOnBeforePath'], ['app::Root']);
      expect(change['beforeLimitations'], ['dynamic dispatch is incomplete']);
    },
  );
}
