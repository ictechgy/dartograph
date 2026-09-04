import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';

/// dartograph를 시작하고 문서화한 프로세스 상태를 보존한다.
Future<void> main(List<String> arguments) async {
  exitCode = await runDartograph(arguments);
}
