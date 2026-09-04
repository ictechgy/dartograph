import 'part_host.dart';
import 'platform.dart';

part 'extensions.dart';
part 'extensions_two.dart';

void main() {
  greet();
  platformName();
  final localOnly = greet;
  localOnly();
  'x'.markerOne();
  1.markerTwo();
  1.0.markerThree();
}
