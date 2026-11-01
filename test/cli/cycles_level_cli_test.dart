import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

/// `cycles --level`이 같은 파일 안의 재귀를 라이브러리 순환과 구분하는지 고정한다.
/// 기본 해상도(symbol)는 기존 출력과 같아야 한다.
void main() {
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('dartograph-cycles-level.');
    await File('${root.path}/pubspec.yaml').writeAsString('''
name: cycles_level
environment:
  sdk: ^3.11.0
''');
    await Directory('${root.path}/lib').create();
    // 같은 파일의 상호 재귀(파서·트리 순회 같은 정상 재귀)다.
    await File('${root.path}/lib/rec.dart').writeAsString('''
/// 짝수 판정.
bool isEven(int n) => n == 0 || isOdd(n - 1);

/// 홀수 판정.
bool isOdd(int n) => n != 0 && isEven(n - 1);
''');
    // 같은 클래스 안 메서드의 상호 재귀다.
    await File('${root.path}/lib/walker.dart').writeAsString('''
/// 트리 순회기.
class Walker {
  /// 왼쪽.
  int left(int n) => n == 0 ? 0 : right(n - 1);

  /// 오른쪽.
  int right(int n) => n == 0 ? 1 : left(n - 1);
}
''');
    // 두 라이브러리의 상호 import다. 심볼 사이에는 순환이 없다.
    await File('${root.path}/lib/a.dart').writeAsString('''
import 'b.dart';

/// b를 부른다.
int a() => b() + 1;

/// b가 부른다.
int leaf() => 0;
''');
    await File('${root.path}/lib/b.dart').writeAsString('''
import 'a.dart';

/// a의 leaf를 부른다.
int b() => leaf();
''');
  });

  tearDownAll(() => root.delete(recursive: true));

  Future<({int status, String out, String err})> run(
    List<String> arguments,
  ) async {
    final output = StringBuffer();
    final error = StringBuffer();
    final status = await runDartograph(arguments, output: output, error: error);
    return (status: status, out: output.toString(), err: error.toString());
  }

  List<List<Object?>> componentsOf(String json) =>
      ((jsonDecode(json) as Map)['cycles'] as List)
          .cast<Map<String, Object?>>()
          .map((cycle) => (cycle['component']! as List).cast<Object?>())
          .toList();

  test('the default symbol level keeps same-file recursion', () async {
    final implicit = await run(['cycles', root.path]);
    final symbol = await run(['cycles', '--level', 'symbol', root.path]);
    expect(implicit.status, ExitStatus.success.code);
    expect(symbol.out, implicit.out);
    expect(componentsOf(implicit.out), [
      ['project:lib/a.dart', 'project:lib/b.dart'],
      ['project:lib/rec.dart::isEven', 'project:lib/rec.dart::isOdd'],
      [
        'project:lib/walker.dart::Walker.left',
        'project:lib/walker.dart::Walker.right',
      ],
    ]);
  });

  test('--level file reports only cycles between libraries', () async {
    final result = await run([
      'cycles',
      '--level',
      'file',
      '--strict',
      root.path,
    ]);
    expect(result.status, ExitStatus.findings.code);
    expect(componentsOf(result.out), [
      ['project:lib/a.dart', 'project:lib/b.dart'],
    ]);
    final text = await run([
      'cycles',
      '--format',
      'text',
      '--level',
      'file',
      root.path,
    ]);
    expect(text.out, contains('cycles: 1'));
    expect(text.out, isNot(contains('isEven')));
  });

  test('--level type folds members into their type', () async {
    final result = await run(['cycles', '--level', 'type', root.path]);
    expect(result.status, ExitStatus.success.code);
    expect(componentsOf(result.out), [
      ['project:lib/a.dart', 'project:lib/b.dart'],
      ['project:lib/rec.dart::isEven', 'project:lib/rec.dart::isOdd'],
    ]);
  });

  test('--explain answers at the requested level', () async {
    final library = await run([
      'cycles',
      '--level',
      'file',
      '--explain',
      'project:lib/a.dart',
      root.path,
    ]);
    expect(library.status, ExitStatus.success.code);
    expect(((jsonDecode(library.out) as Map)['cycles'] as List).length, 1);
    // 해당 해상도에 없는 정점은 미발견(64)이다.
    final folded = await run([
      'cycles',
      '--level',
      'file',
      '--explain',
      'project:lib/rec.dart::isEven',
      root.path,
    ]);
    expect(folded.status, ExitStatus.usage.code);
  });

  test('--level rejects unknown, missing, and repeated values', () async {
    for (final arguments in [
      ['cycles', '--level', 'module', root.path],
      ['cycles', '--level'],
      ['cycles', '--level', 'file', '--level', 'file', root.path],
    ]) {
      expect(
        (await run(arguments)).status,
        ExitStatus.usage.code,
        reason: '$arguments',
      );
    }
  });
}
