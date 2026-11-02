import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

/// `rules`가 레이어 밖 정점으로의 의존을 조용히 건너뛰지 않고 limitation으로
/// 알리는지 고정한다. 위반 판정과 종료 코드는 바뀌지 않는다.
void main() {
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp(
      'dartograph-rules-unassigned.',
    );
    Future<void> write(String relative, String content) async {
      final file = File('${root.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    await write('pubspec.yaml', '''
name: rules_unassigned
environment:
  sdk: ^3.11.0
''');
    await write('lib/ui/screen.dart', '''
import '../util.dart';

/// util을 부른다.
int screen() => util();
''');
    await write('lib/util.dart', '''
/// 어느 레이어에도 없다.
int util() => 1;
''');
    await write('layers.yaml', '''
layers:
  - name: ui
    match: ["project:lib/ui/**"]
  - name: data
    match: ["project:lib/data/**"]
rules:
  - name: ui cannot reach data
    from: ui
    deny: [data]
''');
  });

  tearDownAll(() => root.delete(recursive: true));

  test(
    'rules reports dependencies on unassigned code as a limitation',
    () async {
      final output = StringBuffer();
      final status = await runDartograph(
        [
          'rules',
          '--strict',
          '--config',
          '${root.path}/layers.yaml',
          root.path,
        ],
        output: output,
        error: StringBuffer(),
      );
      expect(status, ExitStatus.success.code);
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(document['violations'], isEmpty);
      // screen 라이브러리의 import 간선과 screen 함수의 호출 간선이다.
      expect(
        document['limitations'],
        contains(
          'unassigned-layer-targets: 2 usage edge(s) from layers with rules '
          'reach 2 node(s) outside every layer; layer rules do not check them',
        ),
      );
    },
  );
}
