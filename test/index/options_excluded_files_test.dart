import 'dart:io';

import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// analysis options의 `analyzer: exclude:`로 빠져 분석하지 않은 비생성 Dart 파일을
/// 실제 analyzer 색인이 `options-excluded-files:` 한계로 세는지 고정한다.
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
          .createTempSync('dartograph-options-excluded.')
          .resolveSymbolicLinksSync(),
    );
    app = p.join(workspace.path, 'app');
    write('app/pubspec.yaml', 'name: app\npublish_to: none\n');
  });
  tearDown(() => workspace.deleteSync(recursive: true));

  Future<AnalyzerGraphResult> index() =>
      AnalyzerGraphIndex(userCacheEnvironment: const {}).index(app);

  List<String> excludedOf(AnalyzerGraphResult result) => [
    for (final detail in result.limitationDetails)
      if (detail.startsWith('options-excluded-files:')) detail,
  ];

  String limitation(int count, String files) =>
      'options-excluded-files: $count Dart file(s) in analyzed source '
      'directories are excluded by analysis options (analysis_options.yaml '
      'or a file it includes) and were not analyzed: $files; declarations '
      'used only from them are reported as unreachable (retain them with '
      'retained_names or retained_files in dartograph.yaml)';

  test(
    'direct excludes count only non-generated files in source directories',
    () async {
      write('app/analysis_options.yaml', '''
analyzer:
  exclude:
    - "lib/legacy/**"
    - "**/*.config.dart"
    - "**/*.g.dart"
    - "tool/**"
''');
      write('app/bin/main.dart', 'void main() {}\n');
      write('app/lib/legacy/old.dart', 'void old() {}\n');
      write('app/lib/legacy/older.dart', 'void older() {}\n');
      write('app/lib/injection.config.dart', 'void init() {}\n');
      write('app/test/fake.config.dart', 'void fake() {}\n');
      write('app/lib/legacy/notes.txt', 'not Dart\n');
      // 제외돼도 생성 파일은 다시 더해 분석한다.
      write('app/lib/model.g.dart', 'void generated() {}\n');
      // 표준 소스 디렉터리 밖·숨김 경로는 원래 분석 대상이 아니다.
      write('app/tool/gen.dart', 'void main() {}\n');
      write('app/lib/.cache/hidden.dart', 'void hidden() {}\n');

      final result = await index();

      expect(excludedOf(result), [
        limitation(
          4,
          'lib/injection.config.dart, lib/legacy/old.dart, '
          'lib/legacy/older.dart and 1 more',
        ),
      ]);
      expect(result.graph.containsNode('project:lib/model.g.dart'), isTrue);
    },
  );

  test('nothing is reported without an analysis options exclusion', () async {
    write('app/bin/main.dart', 'void main() {}\n');
    write('app/lib/a.dart', 'void a() {}\n');
    // 자기 pubspec을 가진 중첩 패키지는 자기 컨텍스트로 분석한다.
    write('app/example/pubspec.yaml', 'name: example\n');
    write('app/example/lib/e.dart', 'void e() {}\n');

    expect(excludedOf(await index()), isEmpty);
  });

  /// [files]가 그래프에 없으면, 그리고 그때만 한계에 그 경로가 실리는지 본다.
  ///
  /// include한 옵션 파일의 패턴을 analyzer 14.3–14.5는 include한 파일 기준으로,
  /// 14.6부터는 패키지 기준으로 해석한다. 어느 analyzer든 한계가 실제 제외만 센다.
  void expectCountedIffExcluded(
    AnalyzerGraphResult result,
    List<String> files,
  ) {
    final details = excludedOf(result);
    final excluded = [
      for (final file in files)
        if (!result.graph.containsNode('package:app/$file')) 'lib/$file',
    ];
    if (excluded.isEmpty) {
      expect(details, isEmpty);
      return;
    }
    expect(details, hasLength(1));
    expect(
      details.single,
      startsWith('options-excluded-files: ${excluded.length} Dart file(s)'),
    );
    for (final file in excluded) {
      expect(details.single, contains(file));
    }
  }

  void packageConfig(String lintPackage) =>
      write('app/.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {"name": "app", "rootUri": "../", "packageUri": "lib/"},
    {"name": "$lintPackage", "rootUri": "../../$lintPackage/", "packageUri": "lib/"}
  ]
}
''');

  test(
    'an in-house lint package excluding injectable and intl_utils output',
    () async {
      // 리뷰 재현: 14.5는 0 finding, 14.6·14.7은 실제로 쓰이는 코드 3 finding.
      write(
        'app/analysis_options.yaml',
        'include: package:company_lints/analysis_options.yaml\n',
      );
      write('company_lints/pubspec.yaml', 'name: company_lints\n');
      write('company_lints/lib/analysis_options.yaml', '''
analyzer:
  exclude:
    - "**/*.g.dart"
    - "**/*.config.dart"
    - "lib/generated/**"
''');
      packageConfig('company_lints');
      write('app/bin/main.dart', '''
import 'package:app/generated/l10n.dart';
import 'package:app/injection.dart';

void main() {
  configureDependencies();
  print(S.current.title);
}
''');
      write('app/lib/generated/l10n.dart', '''
import '../strings.dart';

class S {
  static final S current = S();
  String get title => defaultTitle;
}
''');
      write('app/lib/strings.dart', "const defaultTitle = 'Hello';\n");
      write('app/lib/injection.config.dart', '''
import 'locator.dart';

void initGetIt() => locator.register();
''');
      write('app/lib/injection.dart', '''
import 'injection.config.dart';

void configureDependencies() => initGetIt();
''');
      write('app/lib/locator.dart', '''
final locator = ServiceLocator();

class ServiceLocator {
  void register() {}
}
''');

      expectCountedIffExcluded(await index(), [
        'generated/l10n.dart',
        'injection.config.dart',
      ]);
    },
  );

  test(
    'a very_good_analysis-style include excluding the plugin registrant',
    () async {
      // very_good_analysis 11.0.0은 package:로 버전별 파일을 다시 include하고 그
      // 파일이 lib/generated_plugin_registrant.dart를 제외한다. 접미사로 생성
      // 파일을 알아볼 수 없으므로 dartograph가 다시 더하지 않는다.
      write(
        'app/analysis_options.yaml',
        'include: package:vga_like/analysis_options.yaml\n',
      );
      write('vga_like/pubspec.yaml', 'name: vga_like\n');
      write(
        'vga_like/lib/analysis_options.yaml',
        'include: package:vga_like/analysis_options.11.0.0.yaml\n',
      );
      write('vga_like/lib/analysis_options.11.0.0.yaml', '''
analyzer:
  exclude:
    - test/.test_coverage.dart
    - lib/generated_plugin_registrant.dart
''');
      packageConfig('vga_like');
      write('app/bin/main.dart', 'void main() {}\n');
      write('app/lib/generated_plugin_registrant.dart', '''
void registerPlugins() {}
''');
      write('app/test/.test_coverage.dart', 'void main() {}\n');

      final result = await index();

      expectCountedIffExcluded(result, ['generated_plugin_registrant.dart']);
      // 숨김 파일은 원래 분석 대상이 아니라 세지 않는다.
      expect(excludedOf(result).join(), isNot(contains('.test_coverage.dart')));
    },
  );
}
