import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/core/config_source.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/bounded_resource_provider.dart';
import 'package:dartograph/src/index/incremental_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/read_boundary_support.dart';

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
    await File('${fixtureDirectory.path}/lib/callable.dart').writeAsString('''
class Validator {
  bool call(String input) => input.isNotEmpty;
}

class Holder {
  final Validator validator = Validator();
}

class Unused {
  void call() {}
}

bool check(Validator validator) => validator('x');
bool checkField(Holder holder) => holder.validator('y');
bool? checkNullAware(Holder? holder) => holder?.validator('z');
void checkCascade(Holder holder) => holder..validator('w');
bool Function(String) tearOff(Validator validator) => validator;
''');
    await File('${fixtureDirectory.path}/lib/patterns.dart').writeAsString('''
class Shape {
  Shape(this.side, this.name);
  final int side;
  final String name;
  int get area => side * side;
  int untouched = 0;
}

class Box {
  Box(this.width, this.inner);
  final int width;
  final Shape inner;
}

extension ShapeLabel on Shape {
  String get label => 'shape';
}

int ifCase(Object value) {
  if (value case Shape(:final side)) return side;
  return 0;
}

String switchStatement(Object value) {
  switch (value) {
    case Shape(name: final renamed):
      return renamed;
  }
  return '';
}

String switchExpression(Shape shape) =>
    switch (shape) { Shape(area: > 10) => 'big', _ => 'small' };

int destructure(Box box) {
  var Box(:width, inner: Shape(:label)) = box;
  return width + label.length;
}

int recordPattern(({int code, String text}) record) {
  final (:code, text: _) = record;
  return code;
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

  test('implicit call() invocations and tear-offs become usage edges', () async {
    final result = await AnalyzerGraphIndex().index(fixtureDirectory.path);
    bool has(String source, EdgeKind kind) => result.graph.edges.any(
      (edge) =>
          edge.sourceId == 'package:graph_fixture/callable.dart::$source' &&
          edge.targetId ==
              'package:graph_fixture/callable.dart::Validator.call' &&
          edge.kind == kind,
    );
    // callable 객체 호출(`validator('x')`)은 analyzer가 FunctionExpressionInvocation
    // 으로 해석하고 암묵 `call` 메서드를 element로 단다. 식별자 `validator`는
    // 매개변수라 기존 수집에서 간선이 없어 `Validator.call`이 dead로 보고됐다.
    expect(has('check', EdgeKind.call), isTrue);
    // getter 결과를 바로 호출하는 경우(`holder.validator('y')`)도 같다.
    expect(has('checkField', EdgeKind.call), isTrue);
    // null-aware(`?.`)·cascade(`..`) 호출도 analyzer가 같은 노드로 재작성한다.
    // 이 재작성에 기대는 수정이라 analyzer 버전이 바뀌어도 누락되지 않게 고정한다.
    expect(has('checkNullAware', EdgeKind.call), isTrue);
    expect(has('checkCascade', EdgeKind.call), isTrue);
    // 함수 타입 문맥의 암묵 tear-off(`=> validator`)는 호출이 아니라 참조다.
    expect(has('tearOff', EdgeKind.reference), isTrue);
    // 호출되지 않은 call 메서드에는 간선이 생기지 않는다(음성 고정).
    expect(
      result.graph.edges.any(
        (edge) =>
            edge.targetId ==
                'package:graph_fixture/callable.dart::Unused.call' &&
            edge.kind != EdgeKind.member,
      ),
      isFalse,
    );
  });

  test('object pattern fields become getter read edges', () async {
    final result = await AnalyzerGraphIndex().index(fixtureDirectory.path);
    const library = 'package:graph_fixture/patterns.dart';
    bool reads(String source, String target) => result.graph.edges.any(
      (edge) =>
          edge.sourceId == '$library::$source' &&
          edge.targetId == '$library::$target' &&
          edge.kind == EdgeKind.reference,
    );
    // 변수 패턴이 암시하는 이름(`:final side`)은 식별자 노드가 없어 간선이
    // 빠졌고, 패턴으로만 읽는 필드가 dead로 보고됐다.
    expect(reads('ifCase', 'Shape.side'), isTrue);
    // 이름을 적은 필드(`name: final renamed`)도 이름이 토큰이라 같았다.
    expect(reads('switchStatement', 'Shape.name'), isTrue);
    // 관계 하위 패턴(`area: > 10`)은 명시적 getter를 읽는다.
    expect(reads('switchExpression', 'Shape.area'), isTrue);
    // 구조 분해 선언과 중첩 객체 패턴, extension getter도 읽기다.
    expect(reads('destructure', 'Box.width'), isTrue);
    expect(reads('destructure', 'Box.inner'), isTrue);
    expect(reads('destructure', 'ShapeLabel.label'), isTrue);
    // 패턴에 없는 필드와 레코드 패턴 필드에는 간선이 생기지 않는다(음성 고정).
    expect(
      result.graph.edges.any(
        (edge) =>
            edge.targetId == '$library::Shape.untouched' &&
            edge.kind != EdgeKind.member,
      ),
      isFalse,
    );
    expect(
      result.graph.edges.where(
        (edge) =>
            edge.sourceId == '$library::recordPattern' &&
            edge.kind == EdgeKind.reference,
      ),
      isEmpty,
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
    'an unreadable directory under build/ does not fail the analysis',
    () async {
      final package = await Directory.systemTemp.createTemp(
        'dartograph-locked-build.',
      );
      addTearDown(() => package.delete(recursive: true));
      await File('${package.path}/pubspec.yaml').writeAsString('''
name: locked_build_fixture
environment:
  sdk: ^3.11.0
''');
      // analyzer가 제외한 생성 파일은 dartograph의 보충 열거로만 그래프에 든다.
      await File(
        '${package.path}/analysis_options.yaml',
      ).writeAsString('analyzer:\n  exclude:\n    - lib/model.g.dart\n');
      await Directory('${package.path}/lib').create();
      await File(
        '${package.path}/lib/model.g.dart',
      ).writeAsString('class GeneratedModel {}\n');
      // build/ 아래 생성물은 분석 대상이 아니다 — 보충 열거도 내려가지 않는다.
      await Directory('${package.path}/build/out').create(recursive: true);
      await File(
        '${package.path}/build/out/stale.g.dart',
      ).writeAsString('class StaleOutput {}\n');
      final locked = Directory('${package.path}/build/locked');
      await locked.create();
      final chmod = await Process.run('chmod', ['000', locked.path]);
      expect(chmod.exitCode, 0, reason: chmod.stderr as String);
      // 정리는 역순으로 돈다 — 권한을 먼저 되돌려야 재귀 삭제가 성공한다.
      addTearDown(() => Process.run('chmod', ['700', locked.path]));
      if (_canList(locked)) {
        markTestSkipped('directory permissions are not enforced (root?)');
        return;
      }

      final result = await AnalyzerGraphIndex(
        cache: _ColdCache(),
      ).index(package.path);

      expect(
        result.graph.nodes.keys,
        contains('project:lib/model.g.dart::GeneratedModel'),
      );
      expect(
        result.graph.nodes.keys.where((id) => id.contains('StaleOutput')),
        isEmpty,
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'device and FIFO links among analysis inputs fail closed before analysis',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'dartograph-special-inputs.',
      );
      addTearDown(() => workspace.delete(recursive: true));
      var fixtures = 0;

      /// [target]만 [linkTarget]을 가리키는 링크인 최소 패키지다.
      Future<String> package(String target, String linkTarget) async {
        final root = p.join(workspace.path, 'package-${fixtures++}');
        for (final entry in const {
          'pubspec.yaml':
              'name: special_inputs\nenvironment:\n'
              '  sdk: ^3.11.0\n',
          'lib/a.dart': 'class A {}\n',
        }.entries) {
          await File(p.join(root, entry.key)).create(recursive: true);
          await File(p.join(root, entry.key)).writeAsString(entry.value);
        }
        final link = File(p.join(root, target));
        if (link.existsSync()) await link.delete();
        await link.parent.create(recursive: true);
        await Link(link.path).create(linkTarget);
        return root;
      }

      // 이 경로는 analyzer(pubspec·analysis_options·package_config·.dart)나
      // dartograph(dartograph.yaml·build.yaml)가 상한 없이 읽던 입력이다.
      // /dev/null은 길이 0·즉시 EOF라 수정 전 코드도 멈추지 않는 안전한
      // 대역이다 — /dev/zero라면 같은 경로가 EOF 없이 메모리를 채운다.
      const targets = [
        'pubspec.yaml',
        'analysis_options.yaml',
        '.dart_tool/package_config.json',
        'dartograph.yaml',
        'build.yaml',
        'lib/x.dart',
      ];
      for (final target in targets) {
        final root = await package(target, '/dev/null');
        await expectLater(
          AnalyzerGraphIndex(cache: _ColdCache()).index(root),
          throwsFormatException,
          reason: target,
        );
        await expectLater(
          AnalyzerGraphIndex(
            cache: _ColdCache(),
            incremental: IncrementalCache(p.join(root, '..', 'facts')),
          ).index(root),
          throwsFormatException,
          reason: target,
        );
        // runtime·routes와 schema가 쓰는 해석 경로다.
        await expectLater(
          resolveProjectUnits(root),
          throwsFormatException,
          reason: target,
        );
        await expectLater(
          resolveProjectUnitsAt(root, {p.join(root, 'lib', 'a.dart')}),
          throwsFormatException,
          reason: target,
        );
      }

      // 쓰는 쪽이 없는 FIFO는 열기에서 영구 대기한다. 전체 결과 캐시 경로가
      // 먼저 키 해시를 비동기로 열어, 수정 전 코드라면 동기 읽기가 isolate를
      // 막기 전에 테스트 timeout으로 실패한다.
      final fifo = p.join(workspace.path, 'pipe');
      final mkfifo = await Process.run('mkfifo', [fifo]);
      expect(mkfifo.exitCode, 0, reason: mkfifo.stderr as String);
      final root = await package('pubspec.yaml', fifo);
      await expectLater(
        AnalyzerGraphIndex(cache: _ColdCache()).index(root),
        throwsFormatException,
      );
      await expectLater(
        AnalyzerGraphIndex(
          cache: _ColdCache(),
          incremental: IncrementalCache(p.join(workspace.path, 'facts')),
        ).index(root),
        throwsFormatException,
      );
      await expectLater(resolveProjectUnits(root), throwsFormatException);
    },
    skip: Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  group('devices and FIFOs that only the analyzer opens', () {
    late Directory workspace;
    var fixtures = 0;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp(
        'dartograph-read-boundary.',
      );
      // resolveProjectUnitsAt은 정규화한 루트 기준 경로로 대상을 고른다(macOS의
      // /var → /private/var 같은 링크를 풀어 둔다).
      workspace = Directory(workspace.resolveSymbolicLinksSync());
    });
    tearDown(() => workspace.delete(recursive: true));

    /// pubspec과 [files]만 둔 패키지다. 값이 `-> `로 시작하면 그 대상의 링크다.
    Future<String> package(Map<String, String> files) async {
      final root = p.join(workspace.path, 'package-${fixtures++}');
      final entries = {
        'pubspec.yaml': 'name: read_boundary\nenvironment:\n  sdk: ^3.11.0\n',
        ...files,
      };
      for (final MapEntry(key: path, value: content) in entries.entries) {
        final target = p.join(root, path);
        await Directory(p.dirname(target)).create(recursive: true);
        if (content.startsWith('-> ')) {
          await Link(target).create(content.substring(3));
        } else {
          await File(target).writeAsString(content);
        }
      }
      return root;
    }

    /// 전체·증분 색인과 두 해석 경로가 [root]에서 [matcher]로 실패한다.
    Future<void> expectAnalysisFails(
      String root,
      String unit, {
      Matcher matcher = const TypeMatcher<NonRegularFileException>(),
      String? reason,
    }) async {
      await expectLater(
        AnalyzerGraphIndex(cache: _ColdCache()).index(root),
        throwsA(matcher),
        reason: reason,
      );
      await expectLater(
        AnalyzerGraphIndex(
          cache: _ColdCache(),
          incremental: IncrementalCache('$root.facts'),
        ).index(root),
        throwsA(matcher),
        reason: reason,
      );
      await expectLater(
        resolveProjectUnits(root),
        throwsA(matcher),
        reason: reason,
      );
      await expectLater(
        resolveProjectUnitsAt(root, {p.join(root, unit)}),
        throwsA(matcher),
        reason: reason,
      );
    }

    // 사전 열거(캐시 키·탈출 링크 기록)가 보지 못하는 경로인데 analyzer는 연다.
    // 수정 전에는 /dev/null은 빈 파일로 읽혀 분석이 성공했고, 쓰는 쪽이 없는
    // FIFO나 /dev/zero라면 멈추거나 메모리를 소진했다. 링크 없이 절대 경로
    // import 한 줄로도 같다. 쓰는 쪽을 붙인 FIFO는 회귀를 멈춤 대신 시간 안의
    // 실패로 드러낸다.
    test('imports into hidden or build directories and absolute imports '
        'fail closed', () async {
      final fifo = await fifoWithRepeatingWriter(
        p.join(workspace.path, 'pipe'),
      );
      for (final target in ['/dev/null', fifo]) {
        final reason = 'target $target';
        // 숨김 디렉터리는 사전 열거가 가지치기한다.
        await expectAnalysisFails(
          await package({
            'lib/a.dart': "import '.hidden/x.dart';\n\nvoid main() => x();\n",
            'lib/.hidden/x.dart': '-> $target',
          }),
          'lib/a.dart',
          reason: '$reason, hidden directory',
        );
        // build·.dart_tool·.git은 사전 열거가 건너뛰지만 analyzer는 lib/build를
        // 분석 대상으로 연다. 증분 경로는 해석 전에 이 단위를 해시한다.
        await expectAnalysisFails(
          await package({
            'lib/a.dart': 'class A {}\n',
            'lib/build/x.dart': '-> $target',
          }),
          'lib/build/x.dart',
          reason: '$reason, build directory',
        );
        await expectAnalysisFails(
          await package({'lib/a.dart': "import '$target';\n\nclass A {}\n"}),
          'lib/a.dart',
          reason: '$reason, absolute import',
        );
      }
    });

    test(
      'an unreadable linked directory that stops the pre-scan does not let a '
      'later device link through',
      () async {
        final locked = Directory(p.join(workspace.path, 'locked'));
        await locked.create();
        final chmod = await Process.run('chmod', ['000', locked.path]);
        expect(chmod.exitCode, 0, reason: chmod.stderr as String);
        addTearDown(() => Process.run('chmod', ['700', locked.path]));
        if (_canList(locked)) {
          markTestSkipped('directory permissions are not enforced (root?)');
          return;
        }
        final root = await package({
          'lib/a.dart': 'class A {}\n',
          'lib/zz.dart': '-> /dev/null',
        });
        // 사전 열거는 목록 순서대로 훑다가 읽을 수 없는 디렉터리에서 멈추고
        // 남은 항목을 보지 않는다. 그 링크가 장치 링크보다 먼저 나오는 이름을
        // 고른다(목록 순서는 파일 시스템마다 다르다).
        final lib = Directory(p.join(root, 'lib'));
        String? lockedFirst;
        for (final name in const ['aaa', 'mmm', 'b0', 'q', 'zzz', 'a_']) {
          final link = Link(p.join(lib.path, name));
          await link.create(locked.path);
          final order = [
            for (final entity in lib.listSync(followLinks: false))
              p.basename(entity.path),
          ];
          if (order.indexOf(name) < order.indexOf('zz.dart')) {
            lockedFirst = name;
            break;
          }
          await link.delete();
        }
        if (lockedFirst == null) {
          markTestSkipped('no link name is listed before zz.dart here');
          return;
        }

        await expectLater(
          AnalyzerGraphIndex(cache: _ColdCache()).index(root),
          throwsA(isA<NonRegularFileException>()),
        );
        // 증분 경로는 해석 전에 입력을 다시 열거하다 읽을 수 없는 디렉터리에서
        // 실패한다(기존 동작). 어느 쪽이든 장치를 읽은 결과를 내지 않는다.
        await expectLater(
          AnalyzerGraphIndex(
            cache: _ColdCache(),
            incremental: IncrementalCache('$root.facts'),
          ).index(root),
          throwsA(
            anyOf(isA<NonRegularFileException>(), isA<FileSystemException>()),
          ),
        );
        await expectLater(
          resolveProjectUnits(root),
          throwsA(isA<NonRegularFileException>()),
        );
        await expectLater(
          resolveProjectUnitsAt(root, {p.join(root, 'lib', 'zz.dart')}),
          throwsA(isA<NonRegularFileException>()),
        );
      },
    );

    test(
      'analysis inputs above the read limit fail before they are read',
      () async {
        // 상한 검사는 읽기 전에 길이로 한다. 상한 없이 읽으면 이 공백 소스는
        // 몇 초 안에 빈 라이브러리로 해석돼, 거부가 없다는 실패로 드러난다.
        final root = await package({'lib/a.dart': 'class A {}\n'});
        await writeOversizedSource(
          p.join(root, 'lib', 'big.dart'),
          analysisReadLimit,
        );

        await expectAnalysisFails(
          root,
          'lib/big.dart',
          matcher: isA<InputTooLargeException>().having(
            (rejection) => rejection.message,
            'message',
            'analysis input exceeds the 64 MiB read limit',
          ),
        );
      },
    );
  }, skip: Platform.isWindows);

  test('an unreadable directory in a path dependency does not stop link-escape '
      'recording', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'dartograph-unreadable-dependency.',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final app = '${workspace.path}/app';
    final shared = '${workspace.path}/shared';
    for (final entry in {
      '$app/pubspec.yaml': 'name: app\nenvironment:\n  sdk: ^3.11.0\n',
      '$app/lib/a.dart': 'class A {}\n',
      '$app/.dart_tool/package_config.json':
          '{"configVersion":2,"packages":['
          '{"name":"app","rootUri":"../","packageUri":"lib/"},'
          '{"name":"shared","rootUri":"../../shared/","packageUri":"lib/"}]}',
      '$shared/pubspec.yaml': 'name: shared\n',
      '$shared/lib/shared.dart': 'class Shared {}\n',
    }.entries) {
      await File(entry.key).create(recursive: true);
      await File(entry.key).writeAsString(entry.value);
    }
    // path 의존의 lib/는 내용이 바뀌므로 키 열거가 통째로 훑는다. 루트 밖이라
    // 그래프 파일 열거(_dartFilesUnder)와 analyzer는 이 디렉터리를 보지 않는다.
    final locked = Directory('$shared/lib/locked');
    await locked.create();
    final chmod = await Process.run('chmod', ['000', locked.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr as String);
    // 정리는 역순으로 돈다 — 권한을 먼저 되돌려야 재귀 삭제가 성공한다.
    addTearDown(() => Process.run('chmod', ['700', locked.path]));
    if (_canList(locked)) {
      markTestSkipped('directory permissions are not enforced (root?)');
      return;
    }

    final units = <String>[];
    final escapes = <String>{};
    await resolveProjectUnitsEach(
      app,
      (unit) => units.add(p.basename(unit.path)),
      linkEscapes: escapes,
    );

    // runtime이 쓰는 경로다. 링크 탈출 기록용 열거가 실패해 종료 2가 됐다.
    expect(units, ['a.dart']);
    expect(escapes, isEmpty);
  }, skip: Platform.isWindows);

  test(
    'resolveProjectUnitsEach hands over units one by one in path order',
    () async {
      final package = await Directory.systemTemp.createTemp(
        'dartograph-units-each.',
      );
      addTearDown(() => package.delete(recursive: true));
      for (final entry in const {
        'pubspec.yaml': 'name: units_each\nenvironment:\n  sdk: ^3.11.0\n',
        'lib/b.dart': 'class B {}\n',
        'lib/a.dart': 'class A {}\n',
        'test/c_test.dart': 'void main() {}\n',
        'bin/tool.dart': 'void main() {}\n',
        // 표준 소스 디렉터리 밖이라 그래프와 같이 제외된다.
        'tool/ignored.dart': 'void main() {}\n',
      }.entries) {
        final file = File(p.join(package.path, entry.key));
        await file.create(recursive: true);
        await file.writeAsString(entry.value);
      }
      final root = package.resolveSymbolicLinksSync();
      String relative(String path) =>
          p.posix.joinAll(p.split(p.relative(path, from: root)));

      final visited = <String>[];
      final declared = <String>[];
      await resolveProjectUnitsEach(package.path, (unit) {
        visited.add(relative(unit.path));
        // 콜백 안에서 해석된 AST를 그대로 읽는다 — 호출자는 유닛을 붙잡지
        // 않고 바로 방문한다.
        declared.addAll(
          unit.unit.declarations.whereType<ClassDeclaration>().map(
            (declaration) => declaration.namePart.typeName.lexeme,
          ),
        );
      });

      expect(visited, [
        'bin/tool.dart',
        'lib/a.dart',
        'lib/b.dart',
        'test/c_test.dart',
      ]);
      expect(declared, ['A', 'B']);
      final listed = await resolveProjectUnits(package.path);
      expect([for (final unit in listed) relative(unit.path)], visited);
    },
  );

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

  test(
    'retained_names and retained_files add configured retention roots',
    () async {
      final package = await _entryPointPackage();
      addTearDown(() => package.delete(recursive: true));
      await File('${package.path}/dartograph.yaml').writeAsString('''
retained_names:
  - 'develop*'
retained_files:
  - 'lib/no_main.dart'
''');

      final result = await AnalyzerGraphIndex().index(package.path);

      // 파일 glob이 맞은 no_main.dart의 Helper는 보존 루트다.
      expect(
        result.retentionRoots.entries
            .singleWhere((entry) => entry.key.endsWith('::Helper'))
            .value,
        RetentionReason.configuredRetention,
      );
      // 이름 glob이 맞은 development도 보존 루트다 — 같은 파일의 main이
      // 이미 mainEntryPoint라 덮지 않는다.
      expect(
        result.retentionRoots.entries
            .singleWhere((entry) => entry.key.endsWith('::development'))
            .value,
        RetentionReason.configuredRetention,
      );
      expect(
        result.retentionRoots.entries
            .singleWhere((entry) => entry.key.endsWith('main_dev.dart::main'))
            .value,
        RetentionReason.mainEntryPoint,
      );
      // 설정이 보존 루트를 늘렸다는 사실이 한계로 남는다.
      expect(
        result.limitationDetails,
        anyElement(startsWith('retention-config:')),
      );
    },
  );

  test('repeated wildcards in retained globs keep long names', () async {
    final package = await _entryPointPackage();
    addTearDown(() => package.delete(recursive: true));
    // 두 glob은 이름의 앞쪽 a 10개와 b로만 맞는다. 백트래킹 정규식은 뒤쪽 a
    // 배치를 모두 시도하느라 정점마다 수십 초를 쓴 뒤 불일치로 답해 보존
    // 루트를 빠뜨렸다.
    final name = '${'a' * 10}b${'a' * 30}';
    await File(
      '${package.path}/lib/$name.dart',
    ).writeAsString('class Kept {}\n');
    await File(
      '${package.path}/lib/names.dart',
    ).writeAsString('void $name() {}\n');
    await File('${package.path}/dartograph.yaml').writeAsString('''
retained_files:
  - '${'*a' * 10}*b*'
retained_names:
  - '${'*a' * 10}*b*'
''');

    final result = await AnalyzerGraphIndex().index(package.path);

    RetentionReason reasonOf(String suffix) => result.retentionRoots.entries
        .singleWhere((entry) => entry.key.endsWith(suffix))
        .value;
    expect(reasonOf('$name.dart::Kept'), RetentionReason.configuredRetention);
    expect(reasonOf('names.dart::$name'), RetentionReason.configuredRetention);
    // 앞쪽 배치가 없는 다른 정점은 보존하지 않는다.
    expect(
      result.retentionRoots.keys,
      isNot(anyElement(endsWith('no_main.dart::Helper'))),
    );
  });

  test('include/exclude and thresholds surface on the index result', () async {
    final package = await _entryPointPackage();
    addTearDown(() => package.delete(recursive: true));
    await File('${package.path}/dartograph.yaml').writeAsString('''
include:
  - 'lib/**'
exclude:
  - 'lib/gen/**'
thresholds:
  distance: 0.5
  complexity: 10
''');

    final result = await AnalyzerGraphIndex().index(package.path);

    expect(result.includeGlobs, ['lib/**']);
    expect(result.excludeGlobs, ['lib/gen/**']);
    expect(result.metricsDistanceThreshold, 0.5);
    expect(result.metricsComplexityThreshold, 10);
  });

  test('unknown dartograph.yaml keys surface as a limitation', () async {
    final package = await _entryPointPackage();
    addTearDown(() => package.delete(recursive: true));
    await File(
      '${package.path}/dartograph.yaml',
    ).writeAsString('entry_points:\n  - lib/main.dart\ntypos_key: 1\n');

    final result = await AnalyzerGraphIndex().index(package.path);

    expect(
      result.limitationDetails,
      contains(
        'config-unknown-keys: dartograph.yaml has unrecognized keys: typos_key',
      ),
    );
  });

  test('invalid scope config fails instead of silently narrowing', () async {
    for (final config in const [
      'include: []\n',
      'exclude: nope\n',
      'exclude:\n  - 42\n',
      'retained_names: {a: b}\n',
      'retained_files:\n  - \n',
      'thresholds: []\n',
      'thresholds: {distance: 0}\n',
      'thresholds: {complexity: 1.5}\n',
      'thresholds: {bogus: 1}\n',
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
  });

  test('JS interop annotations retain declarations and their members', () async {
    final package = await Directory.systemTemp.createTemp(
      'dartograph-js-interop.',
    );
    addTearDown(() => package.delete(recursive: true));
    await File('${package.path}/pubspec.yaml').writeAsString('''
name: js_interop_fixture
environment:
  sdk: ^3.11.0
''');
    await Directory('${package.path}/lib').create();
    await File('${package.path}/lib/interop.dart').writeAsString('''
import 'dart:js_interop';

@JS('windowBridge')
external void bridge();

@staticInterop
class DomHandle {
  external factory DomHandle();
}

extension DomHandleApi on DomHandle {
  external void close();
}

// `anonymous`는 `const _Anonymous anonymous`로 선언된 상수다 — 작성명이
// 'anonymous'라 클래스명(JSAnonymous·_Anonymous)이 아닌 이 이름을 인식해야 한다.
@anonymous
@staticInterop
class JsOptions {
  external factory JsOptions({String label});
}
''');
    // 같은 이름의 사용자 annotation은 binding이 아니다 — 같은 라이브러리에
    // 두면 import를 섀도잉하므로 별도 파일에 둔다.
    await File('${package.path}/lib/fake.dart').writeAsString('''
class JS {
  const JS(String name);
}

@JS('fake')
void notBound() {}
''');
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: package.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);

    final result = await AnalyzerGraphIndex().index(package.path);

    expect(
      result.retentionRoots['package:js_interop_fixture/interop.dart::bridge'],
      RetentionReason.externalBinding,
    );
    expect(
      result
          .retentionRoots['package:js_interop_fixture/interop.dart::DomHandle'],
      RetentionReason.externalBinding,
    );
    // binding annotation이 붙은 타입의 멤버는 외부 런타임이 호출한다.
    expect(
      result
          .retentionRoots['package:js_interop_fixture/interop.dart::DomHandleApi.close'],
      RetentionReason.externalBinding,
    );
    // @anonymous도 binding이다 — 상수 이름 'anonymous'로 인식한다.
    expect(
      result
          .retentionRoots['package:js_interop_fixture/interop.dart::JsOptions'],
      RetentionReason.externalBinding,
    );
    // 이름만 같은 annotation은 실제 라이브러리 신원이 다르므로 보존하지 않는다.
    expect(
      result.retentionRoots.keys.where((id) => id.endsWith('::notBound')),
      isEmpty,
    );
  });

  test('build.yaml builder factories become retention roots', () async {
    final package = await Directory.systemTemp.createTemp(
      'dartograph-build-runner.',
    );
    addTearDown(() => package.delete(recursive: true));
    await File('${package.path}/pubspec.yaml').writeAsString('''
name: builder_fixture
environment:
  sdk: ^3.11.0
''');
    await Directory('${package.path}/lib').create();
    await File('${package.path}/lib/builder.dart').writeAsString('''
Object fixtureBuilder(Object options) => options;
Object unrelated() => Object();
''');
    await File('${package.path}/build.yaml').writeAsString('''
builders:
  fixture_builder:
    import: 'package:builder_fixture/builder.dart'
    builder_factories: ['fixtureBuilder']
    build_extensions:
      '.dart': ['.fixture.dart']
    build_to: source
    auto_apply: dependents
''');
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: package.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);

    final result = await AnalyzerGraphIndex().index(package.path);

    expect(
      result
          .retentionRoots['package:builder_fixture/builder.dart::fixtureBuilder'],
      RetentionReason.buildRunner,
    );
    expect(
      result.retentionRoots.keys.where((id) => id.endsWith('::unrelated')),
      isEmpty,
    );
  });

  test(
    'build.yaml entries with uninterpretable imports leave limitations',
    () async {
      final package = await Directory.systemTemp.createTemp(
        'dartograph-build-runner-bad-import.',
      );
      addTearDown(() => package.delete(recursive: true));
      await File('${package.path}/pubspec.yaml').writeAsString('''
name: bad_import_fixture
environment:
  sdk: ^3.11.0
''');
      await Directory('${package.path}/lib').create();
      await File('${package.path}/lib/builder.dart').writeAsString('''
Object fixtureBuilder(Object options) => options;
''');
      // `src/` 상대 경로는 lib/ 접두가 없어 라이브러리 ID로 해석되지 않는다 —
      // 보존 실패를 조용히 넘기지 않고 한계로 남겨야 한다.
      await File('${package.path}/build.yaml').writeAsString('''
builders:
  broken_builder:
    import: 'src/generator.dart'
    builder_factories: ['fixtureBuilder']
    build_extensions:
      '.dart': ['.fixture.dart']
    build_to: source
post_process_builders:
  missing_import:
    builder_factory: fixtureBuilder
    build_extensions:
      '.dart': ['.post.dart']
''');
      final pubGet = await Process.run(Platform.resolvedExecutable, const [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: package.path);
      expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);

      final result = await AnalyzerGraphIndex().index(package.path);

      expect(
        result.retentionRoots.keys.where(
          (id) => id.endsWith('::fixtureBuilder'),
        ),
        isEmpty,
      );
      expect(
        result.limitationDetails.where(
          (item) =>
              item.startsWith('build-yaml-import-unresolved: broken_builder'),
        ),
        hasLength(1),
      );
      expect(
        result.limitationDetails.where(
          (item) =>
              item.startsWith('build-yaml-import-unresolved: missing_import'),
        ),
        hasLength(1),
      );
    },
  );

  test('manifest facts and package imports feed the deps audit', () async {
    final package = await Directory.systemTemp.createTemp(
      'dartograph-manifest.',
    );
    addTearDown(() => package.delete(recursive: true));
    await File('${package.path}/pubspec.yaml').writeAsString('''
name: manifest_fixture
environment:
  sdk: ^3.11.0
dependencies:
  meta: ^1.17.0
dev_dependencies:
  lints: ^6.0.0
dependency_overrides:
  meta: ^1.17.0
''');
    await Directory('${package.path}/lib').create();
    await File('${package.path}/lib/main.dart').writeAsString('''
import 'package:meta/meta.dart';
import 'package:never_declared/never_declared.dart';

@visibleForTesting
void entry() {}
''');
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: package.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);

    final result = await AnalyzerGraphIndex().index(package.path);

    expect(result.packageName, 'manifest_fixture');
    expect(result.declaredDependencies, ['meta']);
    expect(result.declaredDevDependencies, ['lints']);
    expect(result.declaredDependencyOverrides, ['meta']);
    // 미해결 package: 지시문도 선언된 URI 기준으로 센다 — 미선언 신호를
    // 잃지 않는다.
    expect(result.packageImports.keys, containsAll(['meta', 'never_declared']));
    expect(result.packageImports['meta'], ['project:lib/main.dart']);
  });

  test('declaration bodies yield cyclomatic complexity facts', () async {
    final package = await Directory.systemTemp.createTemp(
      'dartograph-complexity.',
    );
    addTearDown(() => package.delete(recursive: true));
    await File('${package.path}/pubspec.yaml').writeAsString('''
name: complexity_fixture
environment:
  sdk: ^3.11.0
''');
    await Directory('${package.path}/lib').create();
    // decide의 기대 점수를 손으로 센다: 기본 1 +
    // ?? 1 + ??= 1 + if(&&) 2 + if(||) 2 + for 1 + 컬렉션 for 1 +
    // 컬렉션 if 1 + while 1 + do 1 + switch case 2(default 제외) +
    // switch-expression case 2 + ?: 1 + on 1 + 중첩 람다의 if 1 = 19
    await File('${package.path}/lib/main.dart').writeAsString('''
int decide(int? x) {
  final y = x ?? 0;
  var z = y;
  z ??= 1;
  if (y > 0 && z > 0) {}
  if (y > 1 || z > 1) {}
  for (var i = 0; i < 3; i++) {}
  final list = [for (var i = 0; i < 2; i++) i, if (y > 0) y];
  while (z > 10) {
    z--;
  }
  do {
    z--;
  } while (z > 5);
  switch (y) {
    case 1:
      break;
    case 2:
      break;
    default:
      break;
  }
  final s = switch (y) { 0 => 'a', _ => 'b' };
  final t = y > 3 ? 1 : 0;
  try {
    throw StateError('x');
  } on StateError {}
  final f = () {
    if (y > 9) return 1;
    return 0;
  };
  return f() + s.length + t + list.length;
}

int trivial() => 0;

abstract class Empty {
  void noBody();
}
''');
    final pubGet = await Process.run(Platform.resolvedExecutable, const [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: package.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);

    final result = await AnalyzerGraphIndex().index(package.path);

    const prefix = 'package:complexity_fixture/main.dart::';
    expect(result.complexity['${prefix}decide'], 19);
    expect(result.complexity['${prefix}trivial'], 1);
    // 본문이 없는 선언은 점수를 내지 않는다.
    expect(result.complexity.containsKey('${prefix}Empty.noBody'), isFalse);
  });
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

/// [directory]를 열거할 수 있는지 본다. 권한 000이어도 열거되면 root처럼 권한을
/// 무시하는 실행 환경이다.
bool _canList(Directory directory) {
  try {
    directory.listSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// 항상 miss인 캐시 — OS 사용자 캐시를 쓰지 않고 전체 해석 경로를 탄다.
final class _ColdCache implements FactCache {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String payload) async {}
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
