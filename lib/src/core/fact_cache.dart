import 'graph_snapshot.dart';

/// 해석된 사실을 영속 저장하는 교체 가능한 캐시 경계다.
///
/// 캐시 구현은 그래프 의미를 바꾸면 안 된다. 캐시가 없거나 꺼졌을 때 analyzer 작업만
/// 늘어날 뿐 사실은 달라지지 않아야 한다.
abstract interface class FactCache {
  /// analyzer 신원과 내용으로 만든 [key]의 불변 그래프를 읽는다.
  Future<GraphSnapshot?> read(String key);

  /// analyzer 신원과 내용으로 만든 [key]에 불변 [snapshot]을 저장한다.
  Future<void> write(String key, GraphSnapshot snapshot);
}
