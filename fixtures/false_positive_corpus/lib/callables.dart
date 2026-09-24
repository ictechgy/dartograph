class Validator {
  Validator();

  bool call(String input) => input.isNotEmpty;
}

class Formatter {
  Formatter();

  String call(String input) => input.trim();
}

class IdleCallable {
  IdleCallable();

  // 인스턴스는 쓰이지만 호출·tear-off되지 않는다. 클래스가 도달 가능해도
  // 이 call은 계속 보고돼야 한다(과보존 방향의 양방향 검증).
  void call() {}
}
