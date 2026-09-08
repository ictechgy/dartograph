class Vector {
  Vector(this.x);

  final int x;

  Vector operator +(Vector other) => Vector(x + other.x);
  Vector operator -() => Vector(-x);

  // main에서 소비하지 않는다. 사용된 연산자만 보존되고 이것은 계속 보고돼야 한다.
  Vector operator *(Vector other) => Vector(x * other.x);
}

extension type Meters(int value) {
  Meters operator -(Meters other) => Meters(value - other.value);

  // 소비되지 않는 extension type 연산자 — 계속 보고돼야 한다.
  Meters operator ~/(int divisor) => Meters(value ~/ divisor);
}
