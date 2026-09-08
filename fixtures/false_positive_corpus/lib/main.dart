import 'enums.dart';
import 'model.dart';
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
}

String routeFactory(String route) => route == '/settings' ? 'settings' : 'home';
