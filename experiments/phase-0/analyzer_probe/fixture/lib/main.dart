import 'part_host.dart';
import 'platform.dart';

part 'extensions.dart';

void main() {
  greet();
  platformName();
  final localOnly = greet;
  localOnly();
  'x'.markerOne();
  1.markerTwo();
}
