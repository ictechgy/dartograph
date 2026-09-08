import 'enums.dart';
import 'model.dart';
import 'operators.dart';
import 'traits.dart';

void main() {
  routeFactory('/settings');
  User.fromJson(const {'name': 'Ada'}).toJson();
  MixedFeature().label.decorated;
  // enum을 `.values`로만 소비한다. 개별 상수를 직접 참조하지 않아도, enum이
  // 도달 가능하면 상수도 보존돼야 한다(오탐 회귀).
  for (final level in TelemetryLevel.values) {
    print(level.name);
  }
  // 연산자를 연산자 구문으로만 소비한다. `+`·단항 `-`·복합 대입 `-=`는
  // 식별자가 아닌 토큰 참조라 사용 간선이 빠져 dead로 잘못 보고됐었다(오탐 회귀).
  print((Vector(1) + Vector(2)).x);
  print((-Vector(3)).x);
  var walked = Meters(9);
  walked -= Meters(3);
  print(walked);
}

String routeFactory(String route) => route == '/settings' ? 'settings' : 'home';
