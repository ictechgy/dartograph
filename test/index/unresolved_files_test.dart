import 'dart:io';

import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/incremental_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// analyzer가 해석하지 않아 그래프에 없는 파일을 실제 analyzer 색인이
/// `unresolved-files:` 한계로 세는지 고정한다.
///
/// analyzer는 패키지 `lib/` 아래 경로를 이스케이프 없이 `package:` URI로 만들어,
/// `%20` 같은 유효한 퍼센트 이스케이프가 든 파일은 경로로 되돌리면 다른 경로가 되고
/// `NotPathOfUriResult`를 준다. 이전에는 그 파일이 finding도 한계도 없이 빠졌고,
/// 그 파일에서만 쓰는 선언이 이유 없이 미도달로 보고됐다.
void main() {
  late Directory workspace;
  late String app;

  void write(String relative, String content) {
    File(p.join(workspace.path, relative))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() {
    workspace = Directory(
      Directory.systemTemp
          .createTempSync('dartograph-unresolved-files.')
          .resolveSymbolicLinksSync(),
    );
    app = p.join(workspace.path, 'app');
    write('app/pubspec.yaml', 'name: app\npublish_to: none\n');
    write(
      'app/.dart_tool/package_config.json',
      '{"configVersion": 2, "packages": '
          '[{"name": "app", "rootUri": "../", "packageUri": "lib/"}]}\n',
    );
    // 공개 라이브러리가 퍼센트 이름 라이브러리를 import해 그 안의 클래스를 쓰고,
    // 그 클래스만 helper.dart의 함수를 부른다. analyzer는 import 쪽 URI
    // (`%2520`)는 해석하므로 `dart analyze`는 깨끗하다.
    write(
      'app/lib/app.dart',
      "import 'src/enc%2520x.dart';\n"
          'void api() => EncUsed().run();\n',
    );
    write(
      'app/lib/src/enc%20x.dart',
      "import 'helper.dart';\n"
          'class EncUsed { void run() => helperOnlyFromEnc(); }\n',
    );
    write('app/lib/src/helper.dart', 'void helperOnlyFromEnc() {}\n');
    // 디렉터리 이름의 이스케이프도 같은 이유로 해석되지 않는다.
    write('app/lib/src%20dir/a.dart', 'class InDirA {}\n');
    write('app/lib/src%20dir/b.dart', 'class InDirB {}\n');
    write('app/lib/src%25dir/c.dart', 'class InDirC {}\n');
    // 해석되는 대조군: 유효하지 않은 이스케이프(`%zz`)와 `package:` URI가 아닌
    // bin/ 파일의 이스케이프는 경로가 URI로 왕복한다.
    write('app/lib/src/bad%zz.dart', 'class BadEscape {}\n');
    write('app/bin/tool%20x.dart', 'void main() {}\n');
  });
  tearDown(() => workspace.deleteSync(recursive: true));

  List<String> unresolvedOf(AnalyzerGraphResult result) => [
    for (final detail in result.limitationDetails)
      if (detail.startsWith('unresolved-files:')) detail,
  ];

  const expected =
      'unresolved-files: 4 Dart file(s) in analyzed source directories were '
      'not resolved by the analyzer and are not in the graph: '
      'lib/src%20dir/a.dart, lib/src%20dir/b.dart, lib/src%25dir/c.dart and '
      '1 more; the analyzer resolves a file only when its path maps to a URI '
      'and back (a path under a package lib/ that contains a percent escape '
      'such as %20 does not); declarations used only from them are reported '
      'as unreachable';

  test(
    'files the analyzer does not resolve are counted, others are not',
    () async {
      final result = await AnalyzerGraphIndex(
        userCacheEnvironment: const {},
      ).index(app);

      // 넷째 파일(lib/src/enc%20x.dart)은 목록에서 잘리고 수에만 든다.
      expect(unresolvedOf(result), [expected]);
      final nodes = result.graph.nodes.keys.toSet();
      // 세지 않은 대조군과 해석된 helper.dart는 그래프에 있다.
      expect(nodes, contains('package:app/src/bad%25zz.dart::BadEscape'));
      expect(nodes, contains('project:bin/tool%20x.dart::main'));
      expect(nodes, contains('package:app/src/helper.dart::helperOnlyFromEnc'));
      // 센 파일의 선언은 그래프에 없다 — 한계가 이 사실을 알린다.
      expect(nodes.where((id) => id.contains('EncUsed')), isEmpty);
      expect(nodes.where((id) => id.contains('InDir')), isEmpty);
    },
  );

  test('a package with only resolvable files has no such limitation', () async {
    for (final name in [
      'lib/src/enc%20x.dart',
      'lib/src%20dir/a.dart',
      'lib/src%20dir/b.dart',
      'lib/src%25dir/c.dart',
    ]) {
      File(p.join(app, name)).deleteSync();
    }

    final result = await AnalyzerGraphIndex(
      userCacheEnvironment: const {},
    ).index(app);

    expect(unresolvedOf(result), isEmpty);
  });

  test(
    'the incremental path counts them on first, reused and changed runs',
    () async {
      final facts = Directory(p.join(workspace.path, 'facts'));
      Future<AnalyzerGraphResult> incremental() => AnalyzerGraphIndex(
        incremental: IncrementalCache(facts.path),
      ).index(app);

      final first = await incremental();
      // 두 번째 실행은 해석한 파일의 사실을 재사용한다. 해석하지 못한 파일은
      // 사실이 캐시에 없어 다시 해석을 시도한다.
      final reused = await incremental();
      write('app/lib/src/helper.dart', 'void helperOnlyFromEnc() {}\n// x\n');
      final changed = await incremental();

      expect(unresolvedOf(first), [expected]);
      expect(unresolvedOf(reused), [expected]);
      expect(unresolvedOf(changed), [expected]);
    },
  );
}
