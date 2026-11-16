import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `options-excluded-files:` 한계가 발견·종료 코드를 바꾸지 않고 limitations에만
/// 실리는지 CLI 출력으로 고정한다.
void main() {
  late Directory root;

  void write(String relative, String content) {
    File(p.join(root.path, relative))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartograph-options-cli.');
    write('pubspec.yaml', 'name: excluded_app\npublish_to: none\n');
    write('bin/main.dart', 'void main() {}\n');
    write('lib/legacy/old.dart', 'void old() {}\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<(int, Map<String, Object?>)> run(List<String> command) async {
    final output = StringBuffer();
    final status = await runDartograph(
      [...command, '--format', 'json', root.path],
      output: output,
      userCacheEnvironment: const {},
    );
    return (status, jsonDecode(output.toString()) as Map<String, Object?>);
  }

  Iterable<Object?> excludedOf(Map<String, Object?> document) =>
      (document['limitations']! as List).where(
        (item) => '$item'.startsWith('options-excluded-files:'),
      );

  test('an excluded file adds only the limitation', () async {
    final (reportedStatus, reported) = await run(['dead']);
    write(
      'analysis_options.yaml',
      'analyzer:\n  exclude:\n    - lib/legacy/**\n',
    );
    final (excludedStatus, excluded) = await run(['dead']);
    final (cyclesStatus, cycles) = await run(['cycles', '--strict']);

    // 분석할 때는 old가 미도달로 보고된다. 제외하면 보고만 사라지고 이유가 남는다.
    expect(reportedStatus, ExitStatus.findings.code);
    expect(excludedOf(reported), isEmpty);
    expect(excludedStatus, ExitStatus.success.code);
    expect(excluded['findings'], isEmpty);
    expect(excludedOf(excluded).single, contains(': lib/legacy/old.dart;'));
    expect(cyclesStatus, ExitStatus.success.code);
    expect(excludedOf(cycles), hasLength(1));
  });
}
