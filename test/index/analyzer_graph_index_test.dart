import 'dart:io';
import 'dart:isolate';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixtureDirectory;

  setUpAll(() async {
    final libraryUri = await Isolate.resolvePackageUri(
      Uri.parse('package:dartograph/dartograph.dart'),
    );
    if (libraryUri == null) {
      throw StateError('Could not resolve the dartograph package root.');
    }
    final repositoryRoot = File.fromUri(libraryUri).parent.parent;
    fixtureDirectory = await Directory.systemTemp.createTemp(
      'dartograph-index-fixture.',
    );
    final sourceFixture = Directory(
      '${repositoryRoot.path}/test/index/fixture',
    );
    expect(sourceFixture.existsSync(), isTrue);
    await _copyFixture(sourceFixture, fixtureDirectory);
    final fixturePubspec = File('${fixtureDirectory.path}/pubspec.yaml');
    await fixturePubspec.writeAsString(
      (await fixturePubspec.readAsString()).replaceFirst(
        'name: graph_fixture',
        'name: "graph_fixture"',
      ),
    );
    await File('${fixtureDirectory.path}/lib/routes.dart').writeAsString('''
void navigate(dynamic context, dynamic navigator) {
  Navigator.pushNamed(context, '/missing');
  navigator.pushNamed('/known');
  Navigator.pushNamed(context, '/inline');
}
final routes = {'/known': Object()};
final app = MaterialApp(routes: {'/inline': Object()});
''');
    await File(
      '${fixtureDirectory.path}/lib/graph_fixture.dart',
    ).writeAsString("export 'api.dart';\n");
    await File('${fixtureDirectory.path}/lib/callback.dart').writeAsString('''
abstract class Framework {
  void invokedByFramework();
}
class FrameworkCallback extends Framework {
  @override
  void invokedByFramework() {}
}
''');
    await File('${fixtureDirectory.path}/lib/ignored.dart').writeAsString('''
// dartograph:ignore
void ignoredAbove() {}

void trailingNotIgnored() {} // dartograph:ignore

// dartograph:ignore
@Deprecated('use something else')
class IgnoredAnnotated {}

/// doc comment
// dartograph:ignore
void docThenMarker() {}

// dartograph:ignore
/// doc after marker
void markerThenDoc() {}

/// doc comment
// dartograph:ignore
@Deprecated('use something else')
void docMarkerAnnotation() {}

class FieldHolder {
  // dartograph:ignore
  int fieldIgnored = 0;
  int fieldControl = 1;
}

// kept: prose that mentions dartograph:ignore mid-sentence is not a directive
int proseMention = 2;

enum IgnoredEnumConstants {
  // dartograph:ignore
  keptConstant,
  plainConstant,
}
''');
    await File('${fixtureDirectory.path}/lib/operators.dart').writeAsString('''
class Vector {
  final int x;
  Vector(this.x);
  Vector operator +(Vector other) => Vector(x + other.x);
  Vector operator *(Vector other) => Vector(x * other.x);
}

class Counter {
  final int n;
  Counter(this.n);
  Counter operator +(int step) => Counter(n + step);
  Counter operator -() => Counter(-n);
  Counter operator -(Counter other) => Counter(n - other.n);
}

class Score {
  final List<int> cells = [0, 0];
  int operator [](int index) => cells[index];
  void operator []=(int index, int value) {
    cells[index] = value;
  }
}

class Matrix {
  final List<int> cells;
  Matrix(this.cells);
  int operator [](int index) => cells[index];
  void operator []=(int index, int value) {
    cells[index] = value;
  }
}

extension type Meters(int value) {
  Meters operator -(Meters other) => Meters(value - other.value);
  Meters operator ~/(int divisor) => Meters(value ~/ divisor);
}

void useOperators() {
  final sum = Vector(1) + Vector(2);
  final neg = -Counter(1);
  var counter = Counter(0);
  counter++;
  counter += 2;
  final matrix = Matrix([1, 2]);
  final first = matrix[0];
  matrix[1] = 5;
  final delta = Meters(9) - Meters(3);
  final difference = Counter(2) - Counter(1);
  final score = Score();
  score[0] += 1;
  score[1]++;
  Matrix? maybeMatrix = Matrix([0]);
  final probe = maybeMatrix?[0];
  print('\$sum \$neg \$counter \$first \$delta \$difference \$probe \${matrix.cells} \${score.cells}');
}
''');
    await Directory('${fixtureDirectory.path}/bin').create();
    await File('${fixtureDirectory.path}/bin/cli.dart').writeAsString('''
import 'package:graph_fixture/api.dart';
void main() => Service();
''');
    await Directory(
      '${fixtureDirectory.path}/example/integration_test',
    ).create(recursive: true);
    await File(
      '${fixtureDirectory.path}/example/integration_test/app_test.dart',
    ).writeAsString('class ExampleIntegrationFixture {}\n');
    await Directory(
      '${fixtureDirectory.path}/fixtures/nested/lib',
    ).create(recursive: true);
    await File(
      '${fixtureDirectory.path}/fixtures/nested/lib/noise.dart',
    ).writeAsString('void main() {}');
    await Directory('${fixtureDirectory.path}/tool').create();
    await File(
      '${fixtureDirectory.path}/tool/helper.dart',
    ).writeAsString('void main() {}');
    final generated = File('${fixtureDirectory.path}/lib/model.g.dart');
    final source = File('${fixtureDirectory.path}/lib/model.dart');
    await source.writeAsString('class ModelSource {}\n');
    final old = DateTime.utc(2020);
    await generated.setLastModified(old);
    await source.setLastModified(old.add(const Duration(days: 1)));
    final ignoredDirectory = Directory('${fixtureDirectory.path}/.dart_tool')
      ..createSync();
    final ignoredGenerated = File('${ignoredDirectory.path}/noise.g.dart')
      ..writeAsStringSync('// generated');
    final ignoredSource = File('${ignoredDirectory.path}/noise.dart')
      ..writeAsStringSync('class Noise {}');
    await ignoredGenerated.setLastModified(old);
    await ignoredSource.setLastModified(old.add(const Duration(days: 1)));
    final copiedNames = await fixtureDirectory
        .list(recursive: true)
        .map((entity) => entity.uri.pathSegments.last)
        .where((name) => name.isNotEmpty)
        .toList();
    expect(
      File('${fixtureDirectory.path}/pubspec.yaml').existsSync(),
      isTrue,
      reason: 'copied entries: ${copiedNames.join(', ')}',
    );
    final result = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: fixtureDirectory.path);
    expect(result.exitCode, 0, reason: result.stderr as String);
  });

  tearDownAll(() => fixtureDirectory.delete(recursive: true));

  test('resolved units become declaration and relationship facts', () async {
    final root = fixtureDirectory.path;

    final result = await AnalyzerGraphIndex().index(root);
    final ids = result.graph.nodes.keys.toSet();
    final edges = result.graph.edges;

    expect(ids, contains('package:graph_fixture/api.dart::Service'));
    expect(ids.any((id) => id.startsWith('project:fixtures/')), isFalse);
    expect(ids.any((id) => id.startsWith('project:tool/')), isFalse);
    expect(ids, contains('package:graph_fixture/api.dart::GeneratedModel'));
    expect(
      result.graph.node('package:graph_fixture/base.dart::Contract'),
      isA<GraphNode>()
          .having((node) => node.isTypeDeclaration, 'is type', isTrue)
          .having((node) => node.isAbstract, 'is abstract', isTrue),
    );
    expect(
      result.graph.node('package:graph_fixture/base.dart::Base'),
      isA<GraphNode>()
          .having((node) => node.isTypeDeclaration, 'is type', isTrue)
          .having((node) => node.isAbstract, 'is abstract', isFalse),
    );
    expect(
      result.graph.node('package:graph_fixture/base.dart::Trait'),
      isA<GraphNode>()
          .having((node) => node.isTypeDeclaration, 'is type', isTrue)
          .having((node) => node.isAbstract, 'is abstract', isTrue),
    );
    expect(
      result.retentionRoots['project:bin/cli.dart::main'],
      RetentionReason.mainEntryPoint,
    );
    expect(
      result
          .retentionRoots['project:example/integration_test/app_test.dart::ExampleIntegrationFixture'],
      RetentionReason.visibleForTesting,
    );
    expect(
      result.retentionRoots['package:graph_fixture/api.dart::Service.work'],
      RetentionReason.overrideContract,
    );
    expect(
      result
          .retentionRoots['package:graph_fixture/callback.dart::FrameworkCallback.invokedByFramework']
          ?.name,
      'overrideContract',
    );
    expect(
      result.retentionRoots['package:graph_fixture/api.dart::Service']?.name,
      'publicApi',
    );
    expect(
      result.retentionRoots['package:graph_fixture/api.dart::helper']?.name,
      'publicApi',
    );
    expect(
      result.retentionRoots['package:graph_fixture/api.dart::value']?.name,
      'publicApi',
    );
    expect(
      result
          .retentionRoots['package:graph_fixture/api.dart::PublicApi.call']
          ?.name,
      'publicApi',
    );
    expect(
      result
          .retentionRoots['package:graph_fixture/api.dart::PublicApi._privateCall'],
      isNull,
    );
    expect(
      ids.where(
        (id) =>
            id.contains(
              '<unnamed-extension@package:graph_fixture/unnamed.dart#',
            ) &&
            id.endsWith('>'),
      ),
      hasLength(1),
    );
    expect(
      result.graph.node('package:graph_fixture/api.dart::GeneratedModel'),
      GraphNode(
        id: 'package:graph_fixture/api.dart::GeneratedModel',
        sourceUri: 'project:lib/model.g.dart',
        line: 3,
        column: 1,
        synthesized: true,
        isTypeDeclaration: true,
      ),
    );

    bool has(String sourceSuffix, String targetSuffix, EdgeKind kind) =>
        edges.any(
          (edge) =>
              edge.sourceId.endsWith(sourceSuffix) &&
              edge.targetId.endsWith(targetSuffix) &&
              edge.kind == kind,
        );

    expect(has('::Service', '::Base', EdgeKind.inheritance), isTrue);
    expect(has('::Service', '::Contract', EdgeKind.implements), isTrue);
    expect(has('::Service', '::Trait', EdgeKind.mixin), isTrue);
    expect(has('::Service', '::Service.work', EdgeKind.member), isTrue);
    expect(has('::Service.work', '::Base.work', EdgeKind.override), isTrue);
    expect(has('::Service.work', '::helper', EdgeKind.call), isTrue);
    expect(has('::Service.work', '::value', EdgeKind.reference), isTrue);
    expect(has('::value', '::Service', EdgeKind.call), isTrue);
    expect(has('::invoke', '::Service.work', EdgeKind.call), isTrue);
    expect(has('::invoke', '::value', EdgeKind.reference), isTrue);
    expect(has('::invoke', '::value', EdgeKind.call), isFalse);
    expect(has('::echo', '::Service', EdgeKind.reference), isTrue);
    expect(has('::update', '::value', EdgeKind.reference), isTrue);
    expect(has('::update', '::Service', EdgeKind.call), isTrue);
    expect(
      has(
        'package:graph_fixture/api.dart',
        'package:graph_fixture/base.dart',
        EdgeKind.import,
      ),
      isTrue,
    );
    expect(
      edges.where(
        (edge) =>
            edge.sourceId == 'package:graph_fixture/api.dart' &&
            edge.targetId == 'package:graph_fixture/base.dart' &&
            edge.kind == EdgeKind.import,
      ),
      hasLength(1),
    );
    expect(
      has(
        'package:graph_fixture/platform.dart',
        'package:graph_fixture/platform_stub.dart',
        EdgeKind.export,
      ),
      isTrue,
    );
    expect(
      has(
        'package:graph_fixture/platform.dart',
        'package:graph_fixture/platform_io.dart',
        EdgeKind.export,
      ),
      isFalse,
    );
    expect(
      result.limitations,
      contains(AnalyzerLimitation.conditionalConfiguration),
    );
    expect(
      result.limitationDetails,
      containsAll(const [
        'conditional-imports: 1 directive(s) use only the analyzer-selected configuration',
        'string-routes: 1 named route use(s) have no matching route table entry',
        'generated-code-staleness: 1 generated file(s) are older than their source',
      ]),
    );
    // dartograph.yaml이 없으면 entry-points 좁힘 limitation도 없다(음성 고정).
    expect(
      result.limitationDetails,
      isNot(anyElement(startsWith('entry-points:'))),
    );
  });

  test('operator invocations become usage edges', () async {
    final result = await AnalyzerGraphIndex().index(fixtureDirectory.path);
    const source = 'package:graph_fixture/operators.dart::useOperators';
    bool has(String target, [EdgeKind kind = EdgeKind.call]) =>
        result.graph.edges.any(
          (edge) =>
              edge.sourceId == source &&
              edge.targetId ==
                  'package:graph_fixture/operators.dart::$target' &&
              edge.kind == kind,
        );
    // 연산자 구문(`a + b`·`a[i]`·`-a`·`a++`)은 SimpleIdentifier가 아니라
    // 토큰이라 기존 참조 수집에서 전부 빠져 사용 중인데 dead로 보고됐다.
    expect(has('Vector.+'), isTrue); // 이항
    expect(has('Counter.unary-'), isTrue); // 전위 단항(analyzer lookupName)
    expect(has('Counter.+'), isTrue); // 후위 `++`·복합 대입 `+=`
    expect(has('Matrix.[]'), isTrue); // 인덱스 읽기(null-aware `?[0]` 포함)
    expect(has('Matrix.[]=', EdgeKind.reference), isTrue); // 기존 writeElement 경로
    expect(has('Meters.-'), isTrue); // extension type 이항
    // 단항 `-`와 이항 `-`가 같은 클래스에 공존해도 lookupName(unary-·-)으로
    // ID가 갈린다(analyzer가 수렴시키면 두 간선 중 하나가 사라진다).
    expect(has('Counter.-'), isTrue); // 이항
    // 복합 대입·증감(`score[0] += 1`·`score[1]++`)의 인덱스 읽기·쓰기.
    expect(has('Score.[]'), isTrue);
    expect(has('Score.[]=', EdgeKind.call), isTrue);
    // 미사용 연산자는 노드로 남아 dead가 계속 보고할 수 있다.
    expect(
      result.graph.containsNode(
        'package:graph_fixture/operators.dart::Vector.*',
      ),
      isTrue,
    );
    expect(
      result.graph.containsNode(
        'package:graph_fixture/operators.dart::Meters.~/',
      ),
      isTrue,
    );
  });

  test(
    'dartograph:ignore comments become inlineIgnore retention roots',
    () async {
      final result = await AnalyzerGraphIndex().index(fixtureDirectory.path);
      String? reason(String id) => result
          .retentionRoots['package:graph_fixture/ignored.dart::$id']
          ?.name;

      // 선언 위 마커(파일 첫 줄·annotation 위·doc 앞뒤·doc+marker+annotation)는
      // 억제로 해석된다.
      expect(reason('ignoredAbove'), 'inlineIgnore');
      expect(reason('IgnoredAnnotated'), 'inlineIgnore');
      expect(reason('docThenMarker'), 'inlineIgnore');
      expect(reason('markerThenDoc'), 'inlineIgnore');
      expect(reason('docMarkerAnnotation'), 'inlineIgnore');
      // 변수·필드는 마커가 감싸는 선언의 타입 키워드에 붙는다.
      expect(reason('FieldHolder.fieldIgnored'), 'inlineIgnore');
      expect(reason('FieldHolder.fieldControl'), isNull);
      // enum 상수도 선언 단위로 억제된다(컨테이너 enum은 영향받지 않는다).
      expect(reason('IgnoredEnumConstants.keptConstant'), 'inlineIgnore');
      expect(reason('IgnoredEnumConstants.plainConstant'), isNull);
      expect(reason('IgnoredEnumConstants'), isNull);
      // 같은 줄 꼬리 주석은 다음 선언의 억제가 아니다(오귀속 방지).
      expect(reason('trailingNotIgnored'), isNull);
      // 산문이 마커를 언급해도 지시문이 아니다(본문 시작 마커만).
      expect(reason('proseMention'), isNull);
      // 선언만 억제된다 — 파일(라이브러리)은 루트가 되지 않는다.
      expect(
        result.retentionRoots.containsKey('package:graph_fixture/ignored.dart'),
        isFalse,
      );
      // part 파일의 마커는 호스트 라이브러리 귀속 선언을 억제한다.
      expect(
        result.retentionRoots['package:graph_fixture/api.dart::IgnoredInPart'],
        RetentionReason.inlineIgnore,
      );
    },
  );

  test('project ids use URL separators on Windows', () {
    expect(
      projectIdForPath(
        r'C:\repo\lib\feature.dart',
        r'C:\repo',
        context: p.windows,
      ),
      'project:lib/feature.dart',
    );
    expect(
      isPathWithinRoot(
        r'C:\repo\lib\feature.dart',
        r'C:\repo',
        context: p.windows,
      ),
      isTrue,
    );
    expect(
      isPathWithinRoot(
        r'C:\repository\lib\feature.dart',
        r'C:\repo',
        context: p.windows,
      ),
      isFalse,
    );
  });

  test('omits conditional configuration limitation when none exist', () async {
    final plainPackage = await Directory.systemTemp.createTemp(
      'dartograph-plain-fixture.',
    );
    addTearDown(() => plainPackage.delete(recursive: true));
    await File('${plainPackage.path}/pubspec.yaml').writeAsString('''
name: plain_fixture
environment:
  sdk: ^3.11.0
''');
    await Directory('${plainPackage.path}/lib').create();
    await File(
      '${plainPackage.path}/lib/main.dart',
    ).writeAsString('void main() {}\n');
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: plainPackage.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);

    final result = await AnalyzerGraphIndex().index(plainPackage.path);

    expect(result.limitations, isEmpty);
  });

  test(
    'prefixed visibleForTesting annotations remain retention roots',
    () async {
      final package = await Directory.systemTemp.createTemp(
        'dartograph-prefixed-annotation.',
      );
      addTearDown(() => package.delete(recursive: true));
      await File('${package.path}/pubspec.yaml').writeAsString('''
name: prefixed_annotation_fixture
environment:
  sdk: ^3.11.0
dependencies:
  meta: ^1.17.0
''');
      await Directory('${package.path}/lib').create();
      await File('${package.path}/lib/main.dart').writeAsString('''
import 'package:meta/meta.dart' as meta;
@meta.visibleForTesting
void retainedForTesting() {}
void main() {}
''');
      final pubGet = await Process.run(Platform.resolvedExecutable, const [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: package.path);
      expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);

      final result = await AnalyzerGraphIndex().index(package.path);
      final retained = result.retentionRoots.entries.singleWhere(
        (entry) => entry.key.endsWith('::retainedForTesting'),
      );

      expect(retained.value, RetentionReason.visibleForTesting);
    },
  );

  test('protobuf sibling outputs are synthesized retention roots', () async {
    final package = await Directory.systemTemp.createTemp(
      'dartograph-protobuf-generated.',
    );
    addTearDown(() => package.delete(recursive: true));
    await File('${package.path}/pubspec.yaml').writeAsString('''
name: protobuf_fixture
environment:
  sdk: ^3.11.0
''');
    await Directory('${package.path}/lib').create();
    for (final entry in const {
      'message.pbenum.dart': 'GeneratedEnum',
      'message.pbgrpc.dart': 'GeneratedGrpc',
      'message.pbjson.dart': 'GeneratedJson',
      'message.pbserver.dart': 'GeneratedServer',
    }.entries) {
      await File(
        '${package.path}/lib/${entry.key}',
      ).writeAsString('class ${entry.value} {}\n');
    }
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: package.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);

    final result = await AnalyzerGraphIndex().index(package.path);
    final generated = result.graph.nodes.values
        .where((node) => node.id.contains('::Generated'))
        .toList();

    expect(generated, hasLength(4));
    expect(
      generated,
      everyElement(
        isA<GraphNode>().having(
          (node) => node.synthesized,
          'synthesized',
          isTrue,
        ),
      ),
    );
    expect(
      generated.map((node) => result.retentionRoots[node.id]),
      everyElement(RetentionReason.generatedCode),
    );
  });

  test(
    'entry_points narrows main retention to declared build targets',
    () async {
      final package = await _entryPointPackage();
      addTearDown(() => package.delete(recursive: true));

      final conservative = await AnalyzerGraphIndex().index(package.path);
      expect(
        conservative.retentionRoots.entries
            .where((entry) => entry.key.endsWith('::main'))
            .map((entry) => entry.value),
        everyElement(RetentionReason.mainEntryPoint),
      );
      expect(
        conservative.retentionRoots.keys
            .where((id) => id.endsWith('::main'))
            .length,
        3,
        reason: 'lib/main.dart·lib/main_dev.dart·bin/cli.dart의 main을 모두 보존',
      );

      await File('${package.path}/dartograph.yaml').writeAsString('''
entry_points:
  - lib/main.dart
''');
      final narrowed = await AnalyzerGraphIndex().index(package.path);
      final mainRoots = narrowed.retentionRoots.entries
          .where((entry) => entry.value == RetentionReason.mainEntryPoint)
          .map((entry) => entry.key)
          .toList();
      expect(
        mainRoots.where((id) => id.endsWith('main_dev.dart::main')),
        isEmpty,
        reason: '설정되지 않은 진입점의 main은 강제 루트가 아니다',
      );
      expect(
        mainRoots.where((id) => id.endsWith('bin/cli.dart::main')),
        isEmpty,
        reason: '다른 디렉터리의 설정되지 않은 main도 루트가 아니다',
      );
      expect(
        mainRoots.where((id) => id.endsWith('main.dart::main')),
        isNotEmpty,
        reason: '설정된 lib/main.dart의 main은 보존 루트로 남는다',
      );
    },
  );

  test('a leading BOM does not hide the entry_points key', () async {
    // BOM이 키 이름에 섞이면 선언한 진입점이 조용히 무시되고 보존 루트가 잘못
    // 좁혀진다. 이 기능이 막으려는 실패 모드 그 자체이므로, yaml이 BOM을
    // 제거한다는 사실을 라이브러리 업그레이드에 대비해 고정한다.
    final package = await _entryPointPackage();
    addTearDown(() => package.delete(recursive: true));
    await File(
      '${package.path}/dartograph.yaml',
    ).writeAsString('\uFEFFentry_points:\n  - bin/cli.dart\n');

    final result = await AnalyzerGraphIndex().index(package.path);
    final mainRoots = result.retentionRoots.entries
        .where((entry) => entry.value == RetentionReason.mainEntryPoint)
        .map((entry) => entry.key)
        .toList();

    expect(mainRoots, hasLength(1));
    expect(mainRoots.single, endsWith('bin/cli.dart::main'));
    // entry_points가 보존 루트를 좁혔다는 사실 자체가 출력에 남아야 한다 —
    // 설정 추가만으로 죽은 코드가 조용히 사라지면 클린 저장소와 구별되지 않는다.
    expect(
      result.limitationDetails,
      anyElement(
        startsWith('entry-points: main retention roots narrowed to 1'),
      ),
    );
  });

  test('entry_points accepts non-lib build targets under bin/', () async {
    final package = await _entryPointPackage();
    addTearDown(() => package.delete(recursive: true));
    await File('${package.path}/dartograph.yaml').writeAsString('''
entry_points:
  - bin/cli.dart
''');

    final result = await AnalyzerGraphIndex().index(package.path);
    final mainRoots = result.retentionRoots.entries
        .where((entry) => entry.value == RetentionReason.mainEntryPoint)
        .map((entry) => entry.key)
        .toList();

    expect(mainRoots, hasLength(1), reason: '설정된 bin/cli.dart의 main만 보존 루트다');
    expect(mainRoots.single, endsWith('bin/cli.dart::main'));
  });

  test(
    'configured entry point without a main is reported as a limitation',
    () async {
      final package = await _entryPointPackage();
      addTearDown(() => package.delete(recursive: true));
      await File('${package.path}/dartograph.yaml').writeAsString('''
entry_points:
  - lib/main.dart
  - lib/no_main.dart
''');

      final result = await AnalyzerGraphIndex().index(package.path);

      expect(
        result.limitationDetails,
        contains('configured-entry-point-without-main: lib/no_main.dart'),
      );
    },
  );

  test(
    'invalid entry_points config fails instead of silently narrowing',
    () async {
      for (final config in const [
        'entry_points: []\n',
        'entry_points:\n  - /abs/main.dart\n',
        'entry_points:\n  - ../escape/main.dart\n',
        'entry_points:\n  - 42\n',
        'entry_points:\n  - lib/does_not_exist.dart\n',
        'entry_points:\n  - test/helper_test.dart\n',
        'entry_points:\n  - lib/notes.txt\n',
        '- lib/main.dart\n',
        'a bare scalar document\n',
        'entry_points: lib/main.dart\n',
        'entry_points: 5\n',
        'entry_points: {a: b}\n',
      ]) {
        final package = await _entryPointPackage();
        addTearDown(() => package.delete(recursive: true));
        await File('${package.path}/dartograph.yaml').writeAsString(config);

        await expectLater(
          AnalyzerGraphIndex().index(package.path),
          throwsA(isA<FormatException>()),
          reason: 'config: $config',
        );
      }
    },
  );

  test(
    'an empty dartograph.yaml keeps the default conservative policy',
    () async {
      // 파일이나 키가 없으면 기본 보수 정책을 유지한다는 계약은 아무것도
      // 선언하지 않는 문서에도 적용된다. yaml은 빈 문서·주석뿐인 문서·`---`만
      // 있는 문서·명시적 null을 모두 null로 돌려주므로, 이를 비-map으로 묶어
      // 거부하면 `touch dartograph.yaml` 한 번으로 모든 명령이 실패한다.
      for (final config in const [
        '',
        '# only a comment\n',
        '---\n',
        'null\n',
        '~\n',
        '\uFEFF',
        'other_key: 1\n',
        '{}\n',
      ]) {
        final package = await _entryPointPackage();
        addTearDown(() => package.delete(recursive: true));
        await File('${package.path}/dartograph.yaml').writeAsString(config);

        final result = await AnalyzerGraphIndex().index(package.path);
        final mainRoots = result.retentionRoots.entries
            .where((entry) => entry.value == RetentionReason.mainEntryPoint)
            .map((entry) => entry.key)
            .toList();

        expect(mainRoots, hasLength(3), reason: 'config: $config');
      }
    },
  );
}

/// 여러 디렉터리의 main과 검증 케이스를 갖춘 임시 패키지를 만든다.
///
/// - `lib/main.dart`, `lib/main_dev.dart`, `bin/cli.dart`: main 진입점
/// - `lib/no_main.dart`: 존재하지만 main이 없는 파일(limitation 케이스)
/// - `test/helper_test.dart`: 보존 루트 범위 밖 .dart(거부 케이스)
/// - `lib/notes.txt`: .dart가 아닌 파일(거부 케이스)
Future<Directory> _entryPointPackage() async {
  final package = await Directory.systemTemp.createTemp(
    'dartograph-entry-points.',
  );
  await File('${package.path}/pubspec.yaml').writeAsString('''
name: entry_points_fixture
environment:
  sdk: ^3.11.0
''');
  await Directory('${package.path}/lib').create();
  await File(
    '${package.path}/lib/main.dart',
  ).writeAsString('void main() => production();\nvoid production() {}\n');
  await File(
    '${package.path}/lib/main_dev.dart',
  ).writeAsString('void main() => development();\nvoid development() {}\n');
  await File(
    '${package.path}/lib/no_main.dart',
  ).writeAsString('class Helper {}\n');
  await File('${package.path}/lib/notes.txt').writeAsString('not dart\n');
  await Directory('${package.path}/bin').create();
  await File('${package.path}/bin/cli.dart').writeAsString('void main() {}\n');
  await Directory('${package.path}/test').create();
  await File(
    '${package.path}/test/helper_test.dart',
  ).writeAsString('class HelperTest {}\n');
  final pubGet = await Process.run(Platform.resolvedExecutable, const [
    'pub',
    'get',
    '--offline',
  ], workingDirectory: package.path);
  expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
  return package;
}

Future<void> _copyFixture(Directory source, Directory destination) async {
  final canonicalSource = Directory(await source.resolveSymbolicLinks());
  await for (final entity in canonicalSource.list(
    recursive: true,
    followLinks: false,
  )) {
    final relativePath = entity.path.substring(canonicalSource.path.length + 1);
    if (relativePath.startsWith('.dart_tool/') ||
        relativePath == 'pubspec.lock') {
      continue;
    }
    final targetPath = '${destination.path}/$relativePath';
    if (entity is Directory) {
      await Directory(targetPath).create(recursive: true);
    } else if (entity is File) {
      await File(targetPath).parent.create(recursive: true);
      await entity.copy(targetPath);
    }
  }
}
