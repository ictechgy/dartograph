import 'package:dev_pkg/dev_pkg.dart';
import 'package:ghost_pkg/ghost_pkg.dart';
import 'package:meta/meta.dart';

// meta는 사용 중, dev_pkg는 lib/에서 참조, ghost_pkg는 어느 섹션에도 없다.
@visibleForTesting
void entry() {
  devPkgMarker();
}
