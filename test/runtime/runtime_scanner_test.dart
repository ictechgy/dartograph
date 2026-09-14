import 'dart:io';

import 'package:dartograph/src/runtime/runtime_facts.dart';
import 'package:dartograph/src/runtime/runtime_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('runtime-scanner.');
  });

  tearDown(() => directory.delete(recursive: true));

  /// [sources]를 임시 패키지로 쓰고 스캔한다.
  Future<List<RuntimeFact>> scan(Map<String, String> sources) async {
    for (final entry in sources.entries) {
      File(p.join(directory.path, entry.key))
        ..createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
    return RuntimeScanner().scan(directory.path);
  }

  List<RuntimeFact> ofKind(List<RuntimeFact> facts, RuntimeFactKind kind) =>
      facts.where((fact) => fact.kind == kind).toList();

  RuntimeFact named(List<RuntimeFact> facts, String name) =>
      facts.firstWhere((fact) => fact.name == name);

  group('env', () {
    test('프로세스 환경과 dart-define을 채널로 나눠 탐지한다', () async {
      final facts = await scan({
        'lib/env.dart': '''import 'dart:io';

const String baseUrl = String.fromEnvironment('BASE_URL');
const int port = int.fromEnvironment('PORT', defaultValue: 8080);
const bool flag = bool.fromEnvironment('FLAG');

String? token() => Platform.environment['API_TOKEN'];
Map<String, String> all() => Platform.environment;
String? byKey(String key) => Platform.environment[key];
''',
      });
      final env = ofKind(facts, RuntimeFactKind.env);
      expect(env, hasLength(6));

      final baseUrl = named(env, 'BASE_URL');
      expect(baseUrl.channel, RuntimeFactChannel.dartDefine);
      expect(baseUrl.literal, isTrue);
      expect(baseUrl.defaultValue, isNull);
      expect(baseUrl.detail, 'const String.fromEnvironment("BASE_URL")');
      expect(baseUrl.source, 'project:lib/env.dart');
      expect(baseUrl.line, 3);
      expect(baseUrl.column, 24);

      // 명시적 기본값은 유무 자체가 판정 결과를 가른다.
      expect(named(env, 'PORT').defaultValue, '8080');
      expect(named(env, 'FLAG').defaultValue, isNull);
      expect(named(env, 'FLAG').channel, RuntimeFactChannel.dartDefine);

      final token = named(env, 'API_TOKEN');
      expect(token.channel, RuntimeFactChannel.processEnvironment);
      expect(token.literal, isTrue);
      expect(token.detail, 'Platform.environment["API_TOKEN"]');
      expect(token.line, 7);

      // 리터럴이 아닌 키·맵 전체는 개별 이름을 확정하지 않고 미판정으로 남긴다.
      final computed = env
          .where((fact) => fact.name == runtimeComputedName)
          .toList();
      expect(computed, hasLength(2));
      final wholeMap = computed.firstWhere(
        (fact) => fact.unverifiableReason != null,
      );
      expect(wholeMap.literal, isFalse);
      expect(wholeMap.unverifiableReason, startsWith('whole-environment-map'));
      expect(
        computed.where((fact) => fact.unverifiableReason == null),
        hasLength(1),
      );
    });

    test('동명의 사용자 정의 메서드는 dart-define으로 보지 않는다', () async {
      final facts = await scan({
        'lib/env.dart': '''class Config {
  static String fromEnvironment(String key) => key;
}

String read() => Config.fromEnvironment('NOT_A_DEFINE');
''',
      });

      expect(ofKind(facts, RuntimeFactKind.env), isEmpty);
    });
  });

  group('dynamicLoad', () {
    test('간접 참조 호출을 호출 형태별로 탐지한다', () async {
      final facts = await scan({
        'lib/dynamic.dart': '''import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

void spawnUri() {
  Isolate.spawnUri(Uri.parse('bin/worker.dart'), const [], null);
}

void spawn(void Function(Null) entry) {
  Isolate.spawn(entry, null);
}

void apply(Object? Function() callee) {
  Function.apply(callee, const []);
}

void byName() {
  DynamicLibrary.open('libfoo.so');
}

void byPath() {
  DynamicLibrary.open('/usr/lib/libz.so');
}

void run() {
  Process.run('git', const []);
  Process.runSync('ls', const []);
  Process.start('make', const []);
}

void parse(String raw) {
  Uri.parse(raw);
}
''',
      });
      final dynamicLoad = ofKind(facts, RuntimeFactKind.dynamicLoad);
      expect(dynamicLoad, hasLength(9));

      final spawnUri = named(dynamicLoad, 'bin/worker.dart');
      expect(spawnUri.channel, RuntimeFactChannel.uri);
      expect(spawnUri.path, 'bin/worker.dart');
      expect(spawnUri.detail, 'Isolate.spawnUri(Uri.parse("bin/worker.dart"))');

      final spawn = named(dynamicLoad, 'entry');
      expect(spawn.channel, RuntimeFactChannel.reflection);
      expect(spawn.unverifiableReason, startsWith('isolate-entry-point'));

      final apply = named(dynamicLoad, 'callee');
      expect(apply.channel, RuntimeFactChannel.reflection);
      expect(apply.unverifiableReason, startsWith('dynamic-invocation'));

      // 맨 이름은 OS 로더가 루트 밖에서 찾으므로 경로 검사를 하지 않는다.
      final bare = named(dynamicLoad, 'libfoo.so');
      expect(bare.channel, RuntimeFactChannel.nativeLibrary);
      expect(bare.path, isNull);
      expect(bare.unverifiableReason, startsWith('bare-library-name'));

      final byPath = named(dynamicLoad, '/usr/lib/libz.so');
      expect(byPath.path, '/usr/lib/libz.so');
      expect(byPath.unverifiableReason, isNull);

      expect(named(dynamicLoad, 'git').detail, 'Process.run("git")');
      expect(named(dynamicLoad, 'ls').detail, 'Process.runSync("ls")');
      expect(named(dynamicLoad, 'make').detail, 'Process.start("make")');
      for (final executable in const ['git', 'ls', 'make']) {
        final fact = named(dynamicLoad, executable);
        expect(fact.channel, RuntimeFactChannel.executable);
        expect(fact.path, executable);
      }

      final parse = named(dynamicLoad, runtimeComputedName);
      expect(parse.channel, RuntimeFactChannel.uri);
      expect(parse.literal, isFalse);
      expect(parse.detail, 'Uri.parse(<computed>)');
    });

    test('dart:mirrors import를 리플렉션 사실로 남긴다', () async {
      final facts = await scan({
        'lib/mirrors.dart': '''import 'dart:mirrors';

ClassMirror reflect(Object target) => reflectClass(target.runtimeType);
''',
      });

      final fact = named(
        ofKind(facts, RuntimeFactKind.dynamicLoad),
        'dart:mirrors',
      );
      expect(fact.channel, RuntimeFactChannel.reflection);
      expect(fact.line, 1);
      expect(fact.detail, 'import "dart:mirrors"');
      expect(fact.unverifiableReason, startsWith('reflection-import'));
    });
  });

  group('config', () {
    test('설정 확장자와 명확한 경로만 config로 보고한다', () async {
      final facts = await scan({
        'lib/config.dart': '''import 'dart:io';

void read() {
  File('config/app.yaml');
  File('output.csv');
  Directory('logs/');
  File(computedPath());
  File('event.json');
}

String computedPath() => 'data.json';
''',
      });
      final config = ofKind(facts, RuntimeFactKind.config);
      expect(config, hasLength(4));

      final yaml = named(config, 'config/app.yaml');
      expect(yaml.channel, RuntimeFactChannel.filePath);
      expect(yaml.path, 'config/app.yaml');
      expect(yaml.line, 4);

      // 설정 확장자는 단일 세그먼트여도 후보지만, 그 밖의 확장자는 경로
      // 구분자가 있어야 후보다(임시 출력 파일을 설정 의존성으로 오탐하지 않는다).
      final declared = named(config, 'event.json');
      expect(declared.channel, RuntimeFactChannel.filePath);
      expect(declared.line, 8);
      expect(config.where((fact) => fact.name == 'output.csv'), isEmpty);
      // 경로 구분자가 있으면 설정 후보다.
      final directory = named(config, 'logs/');
      expect(directory.channel, RuntimeFactChannel.directoryPath);
      expect(directory.path, 'logs/');
      // 계산된 경로는 판정하지 않고 사실로만 남긴다.
      final computed = named(config, runtimeComputedName);
      expect(computed.literal, isFalse);
      expect(computed.unverifiableReason, isNull);
    });
  });

  group('asset', () {
    test('Flutter SDK 없이 분석해도 이름으로 폴백해 에셋 호출을 잡는다', () async {
      final facts = await scan({
        'lib/assets.dart': '''import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

Future<void> read() async {
  await rootBundle.load('assets/logo.json');
  await rootBundle.loadString('assets/text.txt');
}

Object image() => Image.asset('assets/icon.json');
Object painting() => AssetImage('assets/paint.json');
Object packaged() =>
    AssetImage('packages/other/logo.json', package: 'other');
''',
      });
      final asset = ofKind(facts, RuntimeFactKind.asset);
      expect(asset, hasLength(5));

      final loaded = named(asset, 'assets/logo.json');
      expect(loaded.channel, RuntimeFactChannel.assetBundle);
      expect(loaded.path, 'assets/logo.json');
      expect(loaded.detail, 'rootBundle.load("assets/logo.json")');
      expect(loaded.line, 5);
      expect(loaded.column, 9);

      expect(
        named(asset, 'assets/text.txt').detail,
        'rootBundle.loadString("assets/text.txt")',
      );
      expect(
        named(asset, 'assets/icon.json').detail,
        'Image.asset("assets/icon.json")',
      );
      expect(
        named(asset, 'assets/paint.json').detail,
        'AssetImage("assets/paint.json")',
      );

      // 다른 패키지 에셋은 이 패키지 루트로 판정할 수 없다.
      final packaged = named(asset, 'packages/other/logo.json');
      expect(packaged.path, isNull);
      expect(packaged.unverifiableReason, startsWith('package-asset'));
    });

    test('해석되는 명명 생성자 형태도 같은 사실로 만든다', () async {
      final facts = await scan({
        'lib/assets.dart': '''class Image {
  Image.asset(String name);
}

class AssetImage {
  AssetImage(String name, {String? package});
}

void use() {
  Image.asset('assets/icon.json');
  AssetImage('assets/paint.json');
  AssetImage('packages/other/logo.json', package: 'other');
}
''',
      });
      final asset = ofKind(facts, RuntimeFactKind.asset);
      expect(asset, hasLength(3));

      final constructor = named(asset, 'assets/icon.json');
      expect(constructor.path, 'assets/icon.json');
      expect(constructor.detail, 'Image.asset("assets/icon.json")');
      expect(constructor.line, 10);

      expect(
        named(asset, 'assets/paint.json').detail,
        'AssetImage("assets/paint.json")',
      );
      final packaged = named(asset, 'packages/other/logo.json');
      expect(packaged.path, isNull);
      expect(packaged.unverifiableReason, startsWith('package-asset'));
    });
  });

  group('external', () {
    test('목적지 자리의 URL 리터럴과 HttpClient를 외부 자원으로 남긴다', () async {
      final facts = await scan({
        'lib/external.dart': '''import 'dart:io';
import 'package:http/http.dart' as http;

const String endpoint = 'https://example.com/api';

final Uri health = Uri.parse('http://127.0.0.1:8080/health');
Uri unknown(String raw) => Uri.parse(raw);

Future<void> fetch(HttpClient client) async {
  await client.getUrl(Uri.parse('https://example.com/status'));
  await http.post('https://example.com/events', body: '{}');
  await Socket.connect('https://example.com:443');
}

HttpClient client() => HttpClient();
''',
      });
      final external = ofKind(facts, RuntimeFactKind.external);
      expect(external.map((fact) => fact.name), [
        'http://127.0.0.1:8080/health',
        'https://example.com/status',
        'https://example.com/events',
        'https://example.com:443',
        'HttpClient',
      ]);

      // Uri.parse 리터럴은 목적지를 파싱하는 자리다.
      final health = named(external, 'http://127.0.0.1:8080/health');
      expect(health.channel, RuntimeFactChannel.externalUrl);
      expect(health.detail, 'Uri.parse("http://127.0.0.1:8080/health")');
      expect(
        health.unverifiableReason,
        startsWith('external-resource: verification performs no network'),
      );

      expect(
        named(external, 'https://example.com/status').detail,
        'Uri.parse("https://example.com/status")',
      );
      // 알려진 네트워크 호출의 목적지 인자다.
      expect(
        named(external, 'https://example.com/events').detail,
        'http.post("https://example.com/events")',
      );
      expect(
        named(external, 'https://example.com:443').detail,
        'Socket.connect("https://example.com:443")',
      );

      // 목적지를 받지 않는 상수 선언만으로는 외부 자원이 아니다.
      expect(
        external.where((fact) => fact.name == 'https://example.com/api'),
        isEmpty,
      );

      // HttpClient는 dart:io가 재수출하는 dart:_http 선언이다.
      final client = named(external, 'HttpClient');
      expect(client.detail, 'HttpClient()');
      expect(client.unverifiableReason, startsWith('http-client'));

      // http가 아닌 URI는 외부 자원이 아니라 dynamicLoad의 계산된 대상이다.
      final computed = named(
        ofKind(facts, RuntimeFactKind.dynamicLoad),
        runtimeComputedName,
      );
      expect(computed.detail, 'Uri.parse(<computed>)');
    });

    test('비교·검증·상수 선언은 외부 자원으로 잡지 않는다', () async {
      // 예전 규칙은 문자열이 http(s)로 시작하기만 하면 외부 자원으로 보고해
      // 이 코드를 전부 오탐했다.
      final facts = await scan({
        'lib/compare.dart': '''const String schema =
    'https://json.schemastore.org/sarif-2.1.0.json';

bool isRemote(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

bool mentions(String text) => text.contains('https://example.com/api');

String describe() => 'see https://example.com/docs for details';
''',
      });

      expect(ofKind(facts, RuntimeFactKind.external), isEmpty);
    });

    test('spawnUri 대상은 uri 채널이 잡고 외부 자원으로 중복 보고하지 않는다', () async {
      final facts = await scan({
        'lib/spawn.dart': '''import 'dart:isolate';

Future<void> spawn() async {
  await Isolate.spawnUri(
      Uri.parse('https://example.com/worker.dart'), const [], null);
}
''',
      });

      expect(ofKind(facts, RuntimeFactKind.external), isEmpty);
      final spawn = named(
        ofKind(facts, RuntimeFactKind.dynamicLoad),
        'https://example.com/worker.dart',
      );
      expect(spawn.channel, RuntimeFactChannel.uri);
    });
  });

  group('pubspec assets', () {
    test('선언 목록을 파일·디렉터리 사실로 바꾼다', () async {
      final facts = await scan({
        'pubspec.yaml': '''name: corpus
flutter:
  assets:
    - assets/logo.json
    - assets/
''',
      });

      expect(facts, hasLength(2));
      final logo = named(facts, 'assets/logo.json');
      expect(logo.kind, RuntimeFactKind.asset);
      expect(logo.channel, RuntimeFactChannel.assetBundle);
      expect(logo.source, 'project:pubspec.yaml');
      expect(logo.line, 4);
      expect(logo.column, 7);
      expect(logo.path, 'assets/logo.json');

      final directory = named(facts, 'assets/');
      expect(directory.channel, RuntimeFactChannel.directoryPath);
      expect(directory.line, 5);
    });

    test('flutter 선언이 없으면 에셋 사실도 없다', () async {
      final facts = await scan({'pubspec.yaml': 'name: corpus\n'});

      expect(facts, isEmpty);
    });
  });

  test('두 번 스캔해도 같은 순서를 낸다', () async {
    final sources = {
      'lib/b.dart':
          "import 'dart:io';\nString? b() => Platform.environment['B'];\n",
      'lib/a.dart':
          "import 'dart:io';\nString? a() => Platform.environment['A'];\n",
    };
    final first = await scan(sources);
    final second = await RuntimeScanner().scan(directory.path);

    final ids = first.map((fact) => fact.id).toList();
    expect(ids, isNotEmpty);
    expect(second.map((fact) => fact.id).toList(), ids);
    // 종류 → 소스 → 위치 순으로 정렬되고, 소스가 같으면 줄 순서다.
    expect(ids, [
      'env:A@project:lib/a.dart:2:16',
      'env:B@project:lib/b.dart:2:16',
    ]);
  });
}
