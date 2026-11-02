/// main이 상위 타입으로만 호출하는 계약이다.
abstract class Shape {
  /// 구현이 재정의한다.
  int area();
}

/// main이 만드는 구현이다. 재정의 멤버는 계속 보존된다.
class Square extends Shape {
  @override
  int area() => 4;

  @override
  String toString() => 'square';
}

/// 아무도 만들지 않는 구현이다. 재정의 멤버 루트만이 이 타입을 살린다.
class Circle extends Shape {
  @override
  int area() => 3;
}
