/// 객체 패턴으로만 읽는 필드·getter다. 패턴 필드 이름은 식별자 노드가 아니라
/// 토큰이거나(`station:`) 변수 패턴에서 암시되어(`:celsius`) 사용 간선이 빠졌고,
/// 도달 가능한 필드가 dead로 잘못 보고됐었다(오탐 회귀).
class Reading {
  Reading(this.celsius, this.station, this.neverMatched);

  final double celsius;
  final String station;

  // 어떤 패턴·식에서도 읽지 않는다. 클래스가 도달 가능해도 계속 보고돼야
  // 한다(과보존 방향의 양방향 검증).
  final int neverMatched;

  bool get isFreezing => celsius <= 0;
}

class Envelope {
  Envelope(this.payload);

  final Object payload;
}

String describeReading(Object value) {
  if (value case Envelope(payload: Reading(:final celsius))) {
    return 'wrapped $celsius';
  }
  final summary = switch (value) {
    Reading(isFreezing: true) => 'freezing',
    _ => 'mild',
  };
  switch (value) {
    case Reading(station: final name):
      return '$summary at $name';
  }
  return summary;
}
