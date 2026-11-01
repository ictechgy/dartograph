import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

/// 분석 디렉터리 밖의 관례적 진입점 디렉터리(web/·tool/·hook/·benchmark/)를
/// 조용히 빼지 않고 limitation으로 알리는지 고정한다. 보고 대상은 바뀌지 않는다.
void main() {
  late Directory root;

  Future<void> write(String relative, String content) async {
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dartograph-unanalyzed.');
    await write('pubspec.yaml', '''
name: webapp
environment:
  sdk: ^3.11.0
''');
    await write('lib/src/x.dart', '''
/// web/main.dart만 쓴다.
int onlyWeb() => 1;
''');
    await write('bin/main.dart', '''
void main() {}
''');
  });

  tearDown(() => root.delete(recursive: true));

  Future<Map<String, Object?>> deadJson({List<String> extra = const []}) async {
    final output = StringBuffer();
    final status = await runDartograph([
      'dead',
      '--closed-app',
      ...extra,
      '--format',
      'json',
      root.path,
    ], output: output);
    expect(status, ExitStatus.findings.code);
    return jsonDecode(output.toString()) as Map<String, Object?>;
  }

  String limitationFor(String directories) =>
      'unanalyzed-directories: Dart files under $directories are not '
      'analyzed; declarations used only from them are reported as unreachable '
      '(retain them with retained_names or retained_files in dartograph.yaml)';

  final limitation = limitationFor('test_driver/ (1), tool/ (2), web/ (1)');

  Iterable<Object?> unanalyzedOf(Map<String, Object?> document) =>
      (document['limitations']! as List).where(
        (item) => '$item'.startsWith('unanalyzed-directories:'),
      );

  test('Dart files under web/ and tool/ are reported as unanalyzed', () async {
    await write('web/main.dart', '''
import 'package:webapp/src/x.dart';

void main() => print(onlyWeb());
''');
    await write('tool/gen.dart', 'void main() {}\n');
    await write('tool/src/helper.dart', 'void helper() {}\n');
    // flutter_driver 진입점도 분석 밖이다.
    await write('test_driver/app.dart', 'void main() {}\n');
    // 중첩 패키지와 숨김 디렉터리의 파일은 이 패키지의 진입점이 아니다.
    await write('tool/pkg/pubspec.yaml', 'name: pkg\n');
    await write('tool/pkg/lib/y.dart', 'void y() {}\n');
    await write('web/.cache/z.dart', 'void z() {}\n');
    // 표준 디렉터리 밖이지만 관례적 진입점 디렉터리가 아닌 곳은 세지 않는다.
    await write('scripts/run.dart', 'void main() {}\n');

    final document = await deadJson();
    expect(document['limitations'], contains(limitation));
    final findings = (document['findings']! as List)
        .cast<Map<String, Object?>>();
    // 보고 대상은 그대로다. 각 finding도 같은 전역 한계를 싣는다.
    final onlyWeb = findings.singleWhere(
      (finding) => finding['id'] == 'project:lib/src/x.dart::onlyWeb',
    );
    expect(onlyWeb['limitations'], contains(limitation));
  });

  test('no limitation without Dart files in those directories', () async {
    await write('web/index.html', '<html></html>\n');
    await write('tool/pkg/pubspec.yaml', 'name: pkg\n');
    await write('tool/pkg/lib/y.dart', 'void y() {}\n');
    final document = await deadJson();
    expect(unanalyzedOf(document), isEmpty);
  });

  test('workspace members are scanned under their own paths', () async {
    await write('pubspec.yaml', '''
name: webapp
environment:
  sdk: ^3.11.0
workspace:
  - pkgs/a
''');
    await write('pkgs/a/pubspec.yaml', '''
name: a
environment:
  sdk: ^3.11.0
resolution: workspace
''');
    await write('pkgs/a/lib/a.dart', '/// 멤버 선언.\nint a() => 1;\n');
    await write('pkgs/a/web/main.dart', 'void main() {}\n');
    await write('pkgs/a/tool/gen.dart', 'void main() {}\n');
    // 멤버 안의 중첩 패키지는 그 멤버의 진입점이 아니다.
    await write('pkgs/a/tool/inner/pubspec.yaml', 'name: inner\n');
    await write('pkgs/a/tool/inner/bin/run.dart', 'void main() {}\n');
    await write('tool/root.dart', 'void main() {}\n');

    final document = await deadJson(extra: const ['--workspace']);
    expect(unanalyzedOf(document), [
      limitationFor('pkgs/a/tool/ (1), pkgs/a/web/ (1), tool/ (1)'),
    ]);
  });
}
