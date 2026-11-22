import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// export만 하는 대표 라이브러리(`lib/<package-name>.dart`)가 dead 파일로 보고되지
/// 않는지 실제 analyzer 색인으로 고정한다.
///
/// 수정 전에는 대표 라이브러리가 export한 선언을 공개 API로 보존하면서, 정작 그
/// 근거인 대표 라이브러리 파일은 자기 선언이 없다는 이유로
/// `no reachable declaration or reachable library import`로 보고했다(종료 1).
/// `dead --explain`도 export한 선언은 `publicApi`로 살아 있다고, 대표 라이브러리는
/// 미도달이라고 한 실행에서 상반되게 답했다.
void main() {
  late Directory root;

  Future<void> write(String relative, String content) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  /// 대표 라이브러리 `lib/widgets.dart`가 `lib/src/`의 선언을 export만 하는
  /// 패키지를 만든다. [pubspecExtra]는 pubspec에 덧붙일 줄이다.
  Future<void> writePackage({String pubspecExtra = ''}) async {
    await write(
      'pubspec.yaml',
      'name: widgets\n${pubspecExtra}environment:\n  sdk: ^3.0.0\n',
    );
    await write('lib/widgets.dart', "export 'src/widget.dart';\n");
    // 대표 라이브러리가 export하지 않으므로 공개 API가 아니다.
    await write('lib/src/widget.dart', 'class Widget {}\n');
    await write('lib/src/orphan.dart', 'class Orphan {}\n');
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dartograph-entry-cli.');
  });
  tearDown(() => root.delete(recursive: true));

  Future<({int code, String output, String error})> run(
    List<String> command,
  ) async {
    final output = StringBuffer();
    final error = StringBuffer();
    // 사용자 캐시를 쓰지 않는다(격리).
    final code = await runDartograph(
      [...command, root.path],
      output: output,
      error: error,
      userCacheEnvironment: const {},
    );
    return (code: code, output: output.toString(), error: error.toString());
  }

  /// `dead --format json` 결과의 finding ID 목록이다.
  Future<({int code, List<String> ids})> deadIds([
    List<String> flags = const [],
  ]) async {
    final result = await run(['dead', ...flags, '--format', 'json']);
    expect(result.error, isEmpty);
    final document = jsonDecode(result.output) as Map<String, Object?>;
    final ids = [
      for (final finding in document['findings']! as List<Object?>)
        (finding! as Map<String, Object?>)['id']! as String,
    ];
    return (code: result.code, ids: ids);
  }

  // package_config이 없어 자기 패키지 라이브러리도 project: ID다.
  const entry = 'project:lib/widgets.dart';
  const orphanFile = 'project:lib/src/orphan.dart';
  const orphan = 'project:lib/src/orphan.dart::Orphan';

  for (final (name, pubspecExtra) in [
    ('a publishable package', ''),
    // 앱도 기본으로는 대표 라이브러리를 공개 API로 본다(export한 선언 보존과
    // 같은 전제). 그 전제를 걷어내는 것은 --closed-app이다.
    ('an application', 'publish_to: none\n'),
  ]) {
    test('$name keeps its export-only entry library alive', () async {
      await writePackage(pubspecExtra: pubspecExtra);

      final dead = await deadIds();
      // 진짜로 아무도 쓰지 않는 파일은 그대로 보고한다.
      expect(dead.ids, unorderedEquals([orphan, orphanFile]));
      expect(dead.code, ExitStatus.findings.code);

      final explained = await run([
        'dead',
        '--explain',
        entry,
        '--format',
        'json',
      ]);
      expect(explained.code, ExitStatus.success.code, reason: explained.error);
      expect(jsonDecode(explained.output), {
        'evidence': const <Object>[],
        'id': entry,
        'limitations': const <String>[],
        'path': [entry],
        'reachable': true,
        'reason': 'retained as a root',
        'retentionReason': 'publicApi',
      });
    });
  }

  test('--closed-app reports the entry library together with its exports, '
      'as before', () async {
    await writePackage();

    final dead = await deadIds(['--closed-app']);

    expect(
      dead.ids,
      unorderedEquals([
        entry,
        'project:lib/src/widget.dart',
        'project:lib/src/widget.dart::Widget',
        orphan,
        orphanFile,
      ]),
    );
    expect(dead.code, ExitStatus.findings.code);
  });

  test(
    'an entry library that exports no public name is still reported',
    () async {
      // 공개 API가 없으면 보존할 근거도 없다. 소비자가 import해도 쓸 이름이 없다.
      await write(
        'pubspec.yaml',
        'name: widgets\nenvironment:\n  sdk: ^3.0.0\n',
      );
      await write(
        'lib/widgets.dart',
        "export 'src/hidden.dart' hide Hidden;\n",
      );
      await write('lib/src/hidden.dart', 'class Hidden {}\n');

      final dead = await deadIds();

      expect(
        dead.ids,
        unorderedEquals([
          entry,
          'project:lib/src/hidden.dart',
          'project:lib/src/hidden.dart::Hidden',
        ]),
      );
    },
  );
}
