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
  });

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
