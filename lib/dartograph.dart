/// 모든 분석이 공유하는 그래프 원천 타입과 심볼 질의 세션을 공개한다.
///
/// 도달성 결과 모델(ReachabilityResult·ReachabilityExplanation)은 내부 타입으로
/// 남기고, 공개 표면은 SymbolQuerySession.deadDeclarations가 돌려주는 DeadFinding
/// 까지만 노출한다 — 미export 타입이 공개 멤버로 새지 않게 좁힌 경계다.
library;

export 'src/analysis/reachability_analyzer.dart' show DeadFinding;
export 'src/analysis/symbol_query.dart' show SymbolQuerySession;

export 'src/core/code_graph.dart';
export 'src/core/fact_cache.dart';
export 'src/core/graph_edge.dart';
export 'src/core/graph_node.dart';
export 'src/core/graph_snapshot.dart';
export 'src/core/retention_reason.dart';
