import 'model.dart';
import 'traits.dart';

void main() {
  routeFactory('/settings');
  User.fromJson(const {'name': 'Ada'}).toJson();
  MixedFeature().label.decorated;
}

String routeFactory(String route) => route == '/settings' ? 'settings' : 'home';
