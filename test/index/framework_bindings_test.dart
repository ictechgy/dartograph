import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

/// DI·bloc·router가 클래스를 참조하는 전형적 모양을 실제 analyzer로 통과시켜
/// 관측한다. 핵심은 **타입 인자 참조**(`register<T>`·`on<E>`·`add<E>`)와
/// **구현 클래스 생성**(`() => Impl()`)이 그래프 간선으로 남는지다. 이 계열을
/// 위한 별도 보존 사유(retention reason)가 필요 없는 근거를 회귀로 고정한다.
void main() {
  late Directory package;

  setUp(() async {
    package = await Directory.systemTemp.createTemp('dartograph-framework.');
    addTearDown(() => package.delete(recursive: true));
    await File('${package.path}/pubspec.yaml').writeAsString('''
name: framework_fixture
environment:
  sdk: ^3.11.0
''');
    final lib = Directory('${package.path}/lib')..createSync();
    // 외부 패키지 없이 호출 모양만 재현하는 스텁이다. 실제 get_it/bloc/go_router
    // 왕복 실측은 HANDOFF에 기록돼 있고, 여기서는 analyzer 해석만 고정한다.
    File('${lib.path}/framework.dart').writeAsStringSync('''
class Registry {
  void register<T>(T Function() create) {}
  T get<T>() => throw UnimplementedError();
}

class EventBus {
  void on<E>(void Function(E event) handler) {}
}

class Router {
  void add<E>(String path, Object Function() builder) {}
}
''');
    File('${lib.path}/app.dart').writeAsStringSync('''
import 'framework.dart';

abstract class Service {
  void run();
}

class ServiceImpl implements Service {
  @override
  void run() {}
}

class DomainEvent {}

class RouteState {}

class HomePage {
  const HomePage();
}

final registry = Registry();

void configure() {
  registry.register<Service>(() => ServiceImpl());
  EventBus().on<DomainEvent>((event) {});
  Router().add<RouteState>('/home', () => const HomePage());
  registry.get<Service>();
}

void main() => configure();
''');
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: package.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
  });

  test(
    'DI, bloc, and router bindings leave no unreachable declaration',
    () async {
      final output = StringBuffer();
      final error = StringBuffer();
      final status = await runDartograph(
        ['dead', '--format', 'json', package.path],
        output: output,
        error: error,
      );
      expect(status, ExitStatus.success.code, reason: error.toString());
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(document['findings'], isEmpty);
    },
  );

  test('impacting the injected interface reaches its implementation', () async {
    final output = StringBuffer();
    final status = await runDartograph(
      [
        'impact',
        '--symbol',
        'package:framework_fixture/app.dart::Service',
        '--format',
        'json',
        package.path,
      ],
      output: output,
      error: StringBuffer(),
    );
    expect(status, ExitStatus.success.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    final impacted = (document['impacted'] as List)
        .map((item) => (item as Map)['id'])
        .toSet();
    expect(
      impacted,
      contains('package:framework_fixture/app.dart::ServiceImpl'),
    );
  });
}
