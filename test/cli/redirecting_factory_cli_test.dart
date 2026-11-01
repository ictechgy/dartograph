import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

/// 리다이렉트 factory(`factory S() = C;`)의 대상 클래스가 호출된 것으로 보이는지
/// 고정한다. 대상은 InstanceCreationExpression 없이 생성되므로 간선이 없으면
/// 실제로 쓰이는 구현 클래스가 dead로 보고된다.
void main() {
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('dartograph-redirecting.');
    Future<void> write(String relative, String content) async {
      final file = File('${root.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    await write('pubspec.yaml', '''
name: redirecting
environment:
  sdk: ^3.11.0
''');
    await write('bin/main.dart', '''
import '../lib/shapes.dart';

void main() {
  print(Shape());
  print(Shape.named());
  print(Generic<int>());
  print(Shape.plain());
}
''');
    await write('lib/shapes.dart', '''
/// 이름 없는 리다이렉트와 이름 있는 리다이렉트를 함께 둔다.
abstract class Shape {
  /// 기본 구현으로 리다이렉트한다.
  factory Shape() = Circle;

  /// 이름 있는 생성자로 리다이렉트한다.
  factory Shape.named() = Square.named;

  /// 재정의 멤버가 없는 구현으로 리다이렉트한다.
  factory Shape.plain() = Plain;
}

/// 재정의 멤버가 없어 기본 dead에서도 리다이렉트 간선만이 살린다.
class Plain implements Shape {}

/// `Shape()`가 만드는 구현이다.
class Circle implements Shape {
  @override
  String toString() => 'circle';
}

/// `Shape.named()`가 만드는 구현이다.
class Square implements Shape {
  /// 이름 있는 생성자다.
  Square.named();

  @override
  String toString() => 'square';
}

/// 타입 인자가 있는 리다이렉트다.
abstract class Generic<T> {
  /// 구현으로 리다이렉트한다.
  const factory Generic() = _GenericImpl<T>;
}

class _GenericImpl<T> implements Generic<T> {
  const _GenericImpl();

  @override
  String toString() => 'generic';
}

/// 어디서도 만들지 않는 구현이다(대조군).
class Unused implements Shape {
  @override
  String toString() => 'unused';
}
''');
  });

  tearDownAll(() => root.delete(recursive: true));

  Future<List<Object?>> ids(List<String> extra) async {
    final output = StringBuffer();
    await runDartograph([
      'dead',
      ...extra,
      '--closed-app',
      '--format',
      'json',
      root.path,
    ], output: output);
    return ((jsonDecode(output.toString()) as Map)['findings'] as List)
        .cast<Map<String, Object?>>()
        .map((finding) => finding['id'])
        .toList();
  }

  test(
    'redirect targets are reached through the redirecting factory',
    () async {
      expect(await ids(const []), isEmpty);
      // 조건부 재정의 루트에서도 리다이렉트 대상은 살아 있다. 아무도 만들지 않는
      // Unused만 재정의 루트로만 살아 있는 타입으로 남는다.
      expect(await ids(const ['--report-override-only']), [
        'project:lib/shapes.dart::Unused',
        'project:lib/shapes.dart::Unused.toString',
      ]);
    },
  );
}
