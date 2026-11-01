/// 선언 ID에서 멤버를 담는 컨테이너 선언 ID를 찾는 공통 규칙이다.
///
/// 선언 ID는 `<library>::<name>`이고 멤버 이름은 컨테이너 이름에 점으로 이어진다
/// (`lib::A.b`). 첫 `::` 뒤 이름의 점 접두 가운데 실제 정점인 것이 컨테이너다.
/// 라이브러리 경로의 점(`a.dart`)은 첫 `::` 앞이라 후보가 아니다. 도달성의 컨테이너
/// 보존, 조건부 재정의 루트, type 해상도 사영이 같은 규칙을 쓴다.
library;

/// [id]의 컨테이너 후보를 가까운 것부터 [visit]에 넘긴다. [visit]이 false를
/// 돌려주면 멈춘다. [nodeIds]에 없는 접두는 건너뛴다(중간 이름이 정점이 아닐 수
/// 있다). 라이브러리 ID와 최상위 선언은 후보가 없다.
void visitMemberContainers(
  String id,
  Set<String> nodeIds,
  bool Function(String container) visit,
) {
  final symbolSeparator = id.indexOf('::');
  if (symbolSeparator < 0) return;
  var memberSeparator = id.lastIndexOf('.');
  while (memberSeparator > symbolSeparator + 1) {
    final candidate = id.substring(0, memberSeparator);
    if (nodeIds.contains(candidate) && !visit(candidate)) return;
    memberSeparator = id.lastIndexOf('.', memberSeparator - 1);
  }
}

/// [id]를 담는 가장 가까운 컨테이너 선언 ID다. 없으면 null이다.
String? nearestMemberContainer(String id, Set<String> nodeIds) {
  String? nearest;
  visitMemberContainers(id, nodeIds, (container) {
    nearest = container;
    return false;
  });
  return nearest;
}
