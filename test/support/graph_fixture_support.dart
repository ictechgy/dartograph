import 'dart:math';

import 'package:dartograph/dartograph.dart';

/// 직렬화 바이트 동일성을 시험할 결정적 그래프다.
///
/// 라이브러리 [libraries]개마다 선언 하나와 간선 둘을 둔다. ID에는 JSON
/// 이스케이프 대상(따옴표·역슬래시·제어문자)과 비 ASCII(한글·이모지·U+2028·
/// 짝 없는 서러게이트)를 섞고, 선언의 선택 필드(위치·소스·종류 플래그)는
/// [seed]의 난수로 고른다. 조각으로 쓰는 출력이 조각 경계를 여러 번 넘기도록
/// 크기를 정한다.
GraphSnapshot escapeHeavyGraph(int libraries, {int seed = 20261019}) {
  const names = [
    'plain',
    'quote"d',
    r'back\slash',
    'new\nline',
    'tab\tbed',
    'ctl\u0001x',
    'é',
    '한글',
    '😀',
    'sep x',
    'lone\uD800',
    'lone\uDC00',
  ];
  final random = Random(seed);
  final nodes = <GraphNode>[];
  final edges = <GraphEdge>[];
  for (var i = 0; i < libraries; i++) {
    final library = 'project:lib/${names[i % names.length]}$i.dart';
    nodes.add(GraphNode(id: library, sourceUri: library, isLibrary: true));
    final isType = random.nextBool();
    final declaration = GraphNode(
      id: '$library::C$i.${names[(i * 7) % names.length]}',
      sourceUri: random.nextBool() ? library : null,
      line: random.nextBool() ? i + 1 : null,
      column: random.nextBool() ? i % 80 + 1 : null,
      synthesized: random.nextBool(),
      isTypeDeclaration: isType,
      isAbstract: isType && random.nextBool(),
      isSealed: isType && random.nextBool(),
      isEnumConstant: !isType && random.nextInt(4) == 0,
    );
    nodes.add(declaration);
    edges.add(
      GraphEdge(
        sourceId: declaration.id,
        targetId: library,
        kind: EdgeKind.member,
      ),
    );
    final target = nodes[random.nextInt(nodes.length)];
    final kind = EdgeKind.values[random.nextInt(EdgeKind.values.length)];
    edges.add(
      GraphEdge(sourceId: declaration.id, targetId: target.id, kind: kind),
    );
  }
  return GraphSnapshot(nodes: nodes, edges: edges);
}
