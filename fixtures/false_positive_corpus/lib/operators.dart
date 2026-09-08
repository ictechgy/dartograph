class Vector {
  Vector(this.x);

  final int x;

  Vector operator +(Vector other) => Vector(x + other.x);
  Vector operator -() => Vector(-x);

  // main에서 소비하지 않는다. 사용된 연산자만 보존되고 이것은 계속 보고돼야 한다.
  Vector operator *(Vector other) => Vector(x * other.x);
}

class WriteOnly {
  WriteOnly();

  final List<int> cells = [0, 0];

  // 읽기 연산자는 어디서도 소비되지 않는다. `w[0] = 7` 쓰기가 `[]`까지
  // 함께 살리면 안 된다(과보존 방향의 양방향 검증).
  int operator [](int index) => cells[index];
  void operator []=(int index, int value) {
    cells[index] = value;
  }
}

extension type Meters(int value) {
  Meters operator -(Meters other) => Meters(value - other.value);

  // 소비되지 않는 extension type 연산자 — 계속 보고돼야 한다.
  Meters operator ~/(int divisor) => Meters(value ~/ divisor);
}
