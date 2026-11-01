/// 이 파일 밖에서 쓰이지 않는 추상 기반이다.
abstract class Widget {
  /// 프레임워크가 부르는 계약이다.
  String build();
}

/// 어디서도 만들지 않는 위젯이다.
class OrphanWidget extends Widget {
  @override
  String build() => 'orphan';
}

/// toString만 재정의한 미사용 값 타입이다.
class OrphanValue {
  @override
  String toString() => 'value';
}

/// VM이 이름으로 부를 수 있는 재정의다. pragma가 override보다 강한 보존 근거다.
class NativeHook {
  @override
  @pragma('vm:entry-point')
  String toString() => 'native';
}
