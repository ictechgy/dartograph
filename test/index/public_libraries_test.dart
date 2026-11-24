import 'dart:io';

import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

/// 대표 라이브러리 밖 공개 라이브러리를 한계로 세는지 실제 analyzer로 고정한다.
void main() {
  Future<List<String>> limitationsFor({required String publishTo}) async {
    final root = await Directory.systemTemp.createTemp('public-libraries.');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib/src').create(recursive: true);
    await File('${root.path}/pubspec.yaml').writeAsString('''
name: widgets
$publishTo
environment:
  sdk: ^3.11.0
''');
    final files = {
      'widgets.dart': "export 'reexported.dart'; class Widget {}",
      // 대표 라이브러리가 다시 export하므로 이미 공개 API로 보존된다.
      'reexported.dart': 'class Reexported {}',
      // 소비자가 `package:widgets/testing.dart`로만 쓰는 공개 라이브러리다.
      'testing.dart': 'class FakeWidget {} class _Private {}',
      'src/impl.dart': 'class Impl {}',
    };
    for (final entry in files.entries) {
      await File('${root.path}/lib/${entry.key}').writeAsString(entry.value);
    }
    final result = await AnalyzerGraphIndex(
      userCacheEnvironment: const {},
    ).index(root.path);
    return result.limitationDetails;
  }

  test(
    'a publishable package counts public libraries outside its entry',
    () async {
      final details = await limitationsFor(publishTo: '');
      final public = details.where(
        (line) => line.startsWith('public-libraries:'),
      );
      expect(public, hasLength(1));
      expect(public.single, contains('lib/testing.dart'));
      expect(public.single, isNot(contains('reexported.dart')));
      expect(public.single, isNot(contains('lib/src/impl.dart')));
      expect(public.single, contains('lib/widgets.dart'));
    },
  );

  /// 게시할 수 있는 패키지 `widgets`의 `lib/` 아래에 [libraries]를 쓰고, 루트에
  /// [rootFiles](build.yaml·dartograph.yaml 등)를 써서 색인한 `public-libraries:`
  /// 한계 목록이다.
  Future<List<String>> publicLibrariesFor(
    Map<String, String> libraries, {
    Map<String, String> rootFiles = const {},
  }) async {
    final root = await Directory.systemTemp.createTemp('public-libraries.');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create(recursive: true);
    await File(
      '${root.path}/pubspec.yaml',
    ).writeAsString('name: widgets\nenvironment:\n  sdk: ^3.11.0\n');
    for (final entry in libraries.entries) {
      final file = File('${root.path}/lib/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    for (final entry in rootFiles.entries) {
      final file = File('${root.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    final result = await AnalyzerGraphIndex(
      userCacheEnvironment: const {},
    ).index(root.path);
    return [
      for (final line in result.limitationDetails)
        if (line.startsWith('public-libraries:')) line,
    ];
  }

  test('libraries whose public declarations are all retained on other grounds '
      'are not counted', () async {
    // 수정 전에는 publicApi가 아닌 보존 근거를 모두 '미보존'으로 셌고, 설정
    // 보존(retained_files)과 build.yaml builder 보존보다 먼저 셌다. 그래서 이
    // 한계가 권하는 retained_files를 따른 kept.dart와 builder factory만 있는
    // builder.dart도 '미도달로 보고된다'고 알렸다. 아래 파일에는 소비자만 써서
    // 미도달로 보고될 공개 선언이 없다. retained_files는 멤버(Kept.run)까지
    // 보존하고, pragma enum의 상수는 enum으로 보존되며, Hook에는 비공개 멤버만
    // 있다(소비자가 쓸 수 없다).
    final limitations = await publicLibrariesFor(
      {
        'widgets.dart': 'class Widget {}',
        'builder.dart': 'Object widgetBuilder(Object options) => options;',
        'hooks.dart':
            "@pragma('vm:entry-point')\nvoid nativeHook() {}\n"
            "@pragma('vm:entry-point')\nclass Hook { void _internal() {} }",
        'kept.dart': 'class Kept { void run() {} }',
        'levels.dart': "@pragma('vm:entry-point')\nenum Level { low, high }",
        'tool.dart': 'void main() {}',
        'testing.dart': 'class FakeWidget {}',
      },
      rootFiles: {
        'build.yaml': '''
builders:
  widget:
    import: "package:widgets/builder.dart"
    builder_factories: ["widgetBuilder"]
    build_extensions: {".dart": [".widget.dart"]}
''',
        'dartograph.yaml': 'retained_files:\n  - lib/kept.dart\n',
        // builder factory는 package: ID로만 찾는다. package config이 없으면
        // 보존되지 않아 실제로 미도달로 보고되므로 세는 것이 맞다.
        '.dart_tool/package_config.json': '''
{"configVersion": 2, "packages": [{"name": "widgets", "rootUri": "../",
"packageUri": "lib/", "languageVersion": "3.11"}]}
''',
      },
    );

    expect(limitations, [
      'public-libraries: lib/testing.dart is a public library outside '
          'lib/widgets.dart; its declarations are not retained as public API, '
          'so ones used only by package consumers are reported as unreachable '
          '(export it from lib/widgets.dart or retain it with retained_files)',
    ]);
  });

  test(
    'a library with one unretained public declaration is still counted',
    () async {
      final limitations = await publicLibrariesFor({
        'widgets.dart': 'class Widget {}',
        // nativeHook은 보존되지만 Helper는 소비자만 쓰면 미도달로 보고된다.
        'hooks.dart':
            "@pragma('vm:entry-point')\nvoid nativeHook() {}\nclass Helper {}",
        'testing.dart': 'class FakeWidget {}',
      });

      expect(limitations, [
        'public-libraries: lib/hooks.dart, lib/testing.dart are public libraries '
            'outside lib/widgets.dart; their declarations are not retained as '
            'public API, so ones used only by package consumers are reported as '
            'unreachable (export them from lib/widgets.dart or retain them with '
            'retained_files)',
      ]);
    },
  );

  test('a class retained without its members is still counted', () async {
    // pragma·dartograph:ignore·retained_names는 그 선언만 보존하고 공개 멤버는
    // 보존하지 않는다(publicApi와 다르다). 소비자만 쓰는 FakeClock.now·
    // FakeExt.doubled는 계속 미도달로 보고되므로 한계도 남아야 한다. 대표
    // 라이브러리 밖 최상위 선언만 보던 판정은 이 파일들을 뺐다.
    final limitations = await publicLibrariesFor(
      {
        'widgets.dart': 'class Widget {}',
        'pragma.dart':
            "@pragma('vm:entry-point')\n"
            'class FakeClock { DateTime now() => DateTime(2000); }',
        'ignored.dart':
            '// dartograph:ignore\n'
            'extension FakeExt on int { int get doubled => this * 2; }',
        'named.dart': 'class FakeTimer { void tick() {} }',
      },
      rootFiles: {'dartograph.yaml': 'retained_names:\n  - FakeTimer\n'},
    );

    expect(limitations, [
      'public-libraries: lib/ignored.dart, lib/named.dart, lib/pragma.dart are '
          'public libraries outside lib/widgets.dart; their declarations are '
          'not retained as public API, so ones used only by package consumers '
          'are reported as unreachable (export them from lib/widgets.dart or '
          'retain them with retained_files)',
    ]);
  });

  test('declarations in part files count for their host library', () async {
    // part의 선언은 호스트 라이브러리의 것이다. 이전에는 라이브러리 파일 자신의
    // 정점만 봐서, 소비자만 쓰는 part 안 클래스(FakeX·FakeX.m, FakeY)가 보고되는데도
    // x.dart·y.dart를 세지 않았다. 최상위 `lib/` 아래 part 파일(z_part.dart)은
    // 라이브러리가 아니므로 이름으로 싣지 않고 그 선언을 호스트 z.dart에 돌린다.
    final limitations = await publicLibrariesFor({
      'widgets.dart': 'class Widget {}',
      'x.dart':
          "part 'src/x_part.dart';\n"
          "@pragma('vm:entry-point')\nvoid hook() {}",
      'src/x_part.dart': "part of '../x.dart';\nclass FakeX { void m() {} }",
      'y.dart': "part 'src/y_part.dart';",
      'src/y_part.dart': "part of '../y.dart';\nclass FakeY {}",
      'z.dart': "part 'z_part.dart';",
      'z_part.dart': "part of 'z.dart';\nclass FakeZ {}",
    });

    expect(limitations, [
      'public-libraries: lib/x.dart, lib/y.dart, lib/z.dart are public '
          'libraries outside lib/widgets.dart; their declarations are not '
          'retained as public API, so ones used only by package consumers are '
          'reported as unreachable (export them from lib/widgets.dart or '
          'retain them with retained_files)',
    ]);
  });

  test('an unnamed extension is pointed at retained_files', () async {
    // 익명 extension은 이름이 없어 대표 라이브러리에서 export할 수 없다.
    final limitations = await publicLibrariesFor({
      'widgets.dart': 'class Widget {}',
      'ext.dart': 'extension on int { int get doubled => this * 2; }',
    });

    expect(limitations, [
      'public-libraries: lib/ext.dart is a public library outside '
          'lib/widgets.dart; its declarations are not retained as public API, '
          'so ones used only by package consumers are reported as unreachable '
          '(export it from lib/widgets.dart or retain it with retained_files; '
          'an unnamed extension cannot be exported, so retain its file with '
          'retained_files)',
    ]);
  });

  test(
    'an application that is not published is not told about consumers',
    () async {
      final details = await limitationsFor(publishTo: "publish_to: 'none'");
      expect(
        details.where((line) => line.startsWith('public-libraries:')),
        isEmpty,
      );
    },
  );
}
