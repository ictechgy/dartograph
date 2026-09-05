import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import '../core/code_graph.dart';
import '../core/fact_cache.dart';
import '../core/graph_edge.dart';
import '../core/graph_node.dart';
import '../core/retention_reason.dart';
import '../core/tool_info.dart';

/// 공개 analyzer가 한 실행에서 조건부 구성 하나만 해석한다는 한계다.
enum AnalyzerLimitation {
  /// 조건부 import/export의 선택된 구성만 그래프에 들어간다.
  conditionalConfiguration,

  /// 생성 선언을 보수적으로 모두 보존 루트로 사용한다.
  generatedCodeRetention,

  /// 테스트와 `visibleForTesting` 선언을 보수적으로 보존한다.
  testCodeRetention,

  /// 플러그인 클래스 이름이 여러 선언과 일치해 모두 보존했다.
  ambiguousPluginEntryPoint,

  /// pubspec의 플러그인 클래스와 일치하는 선언을 찾지 못했다.
  unresolvedPluginEntryPoint,
}

/// analyzer 타입을 노출하지 않는 index 결과다.
final class AnalyzerGraphResult {
  /// 완성된 그래프와 적용된 분석 한계를 보존한다.
  const AnalyzerGraphResult({
    required this.graph,
    required this.limitations,
    this.limitationDetails = const [],
    this.retentionRoots = const {},
  });

  /// resolved unit에서 얻은 선언과 관계다.
  final CodeGraph graph;

  /// 결과 해석 시 항상 알려야 하는 analyzer 한계다.
  final List<AnalyzerLimitation> limitations;

  /// 프로젝트에서 실제로 센, 에이전트 응답용 분석 한계다.
  final List<String> limitationDetails;

  /// analyzer와 manifest에서 확인한 명시적 보존 루트다.
  final Map<String, RetentionReason> retentionRoots;
}

/// analyzer 14.3.0 resolved unit을 안정적인 core 그래프로 바꾼다.
final class AnalyzerGraphIndex {
  /// 기본 프로젝트 캐시 또는 테스트가 주입한 [cache]를 사용한다.
  AnalyzerGraphIndex({FactCache? cache}) : _cache = cache;

  final FactCache? _cache;

  /// [rootPath] 아래 분석 대상과 제외된 생성 파일을 함께 색인한다.
  Future<AnalyzerGraphResult> index(String rootPath) async {
    final root = Directory(rootPath).absolute.resolveSymbolicLinksSync();
    final cache = _cache ?? _defaultFactCache(root);
    final initialCacheKey = cache == null
        ? null
        : await _tryAnalysisCacheKey(root);
    if (cache != null && initialCacheKey != null) {
      final cached = await _readCachedAnalysis(cache, initialCacheKey);
      if (cached != null &&
          await _tryAnalysisCacheKey(root) == initialCacheKey) {
        return cached;
      }
    }
    final collection = AnalysisContextCollection(
      includedPaths: [root],
      sdkPath: _dartSdkPath(),
    );
    final units = <ResolvedUnitResult>[];
    try {
      for (final path in _dartFilesUnder(root, collection)) {
        final result = await _contextIncluding(
          collection,
          path,
        ).currentSession.getResolvedUnit(path);
        if (result is ResolvedUnitResult) units.add(result);
      }

      final graph = CodeGraph();
      final retentionRoots = <String, RetentionReason>{};
      for (final unit in units) {
        final libraryId = _libraryId(unit.libraryElement.uri, root);
        if (!graph.containsNode(libraryId)) {
          graph.addNode(GraphNode(id: libraryId));
        }
        unit.unit.accept(_DeclarationCollector(graph, root, retentionRoots));
      }
      final libraries = <String, LibraryElement>{};
      for (final unit in units) {
        final libraryId = _libraryId(unit.libraryElement.uri, root);
        libraries.putIfAbsent(libraryId, () => unit.libraryElement);
      }
      final libraryIds = libraries.keys.toList()..sort();
      for (final libraryId in libraryIds) {
        final library = libraries[libraryId]!;
        for (final import in library.firstFragment.libraryImports) {
          final imported = import.importedLibrary;
          if (imported == null) continue;
          final target = _libraryId(imported.uri, root);
          if (graph.containsNode(target)) {
            graph.addEdge(
              GraphEdge(
                sourceId: libraryId,
                targetId: target,
                kind: EdgeKind.import,
              ),
            );
          }
        }
        for (final export in library.firstFragment.libraryExports) {
          final exported = export.exportedLibrary;
          if (exported == null) continue;
          final target = _libraryId(exported.uri, root);
          if (graph.containsNode(target)) {
            graph.addEdge(
              GraphEdge(
                sourceId: libraryId,
                targetId: target,
                kind: EdgeKind.export,
              ),
            );
          }
        }
      }
      _addPublicApiRoots(root, libraries, graph, retentionRoots);
      for (final unit in units) {
        unit.unit.accept(_RelationshipCollector(graph, root));
      }
      final limitations = <AnalyzerLimitation>{
        ..._addPluginRoots(root, graph, retentionRoots),
      };
      final hasConditionalConfiguration = units.any(
        (unit) => unit.unit.directives.any(
          (directive) => switch (directive) {
            ImportDirective() => directive.configurations.isNotEmpty,
            ExportDirective() => directive.configurations.isNotEmpty,
            _ => false,
          },
        ),
      );
      if (hasConditionalConfiguration) {
        limitations.add(AnalyzerLimitation.conditionalConfiguration);
      }
      if (retentionRoots.values.contains(RetentionReason.generatedCode)) {
        limitations.add(AnalyzerLimitation.generatedCodeRetention);
      }
      if (retentionRoots.values.contains(RetentionReason.visibleForTesting)) {
        limitations.add(AnalyzerLimitation.testCodeRetention);
      }
      final result = AnalyzerGraphResult(
        graph: graph,
        limitations: limitations.toList()..sort((a, b) => a.index - b.index),
        limitationDetails: _agentLimitations(root, units),
        retentionRoots: Map.unmodifiable(retentionRoots),
      );
      if (cache != null &&
          initialCacheKey != null &&
          await _tryAnalysisCacheKey(root) == initialCacheKey) {
        await _writeCachedAnalysis(cache, initialCacheKey, result);
      }
      return result;
    } finally {
      await collection.dispose();
    }
  }
}

const _cacheSchemaVersion = 1;
const _cacheIdentity =
    'dartograph-analysis-$toolVersion-cache-v2-source-evidence';

Future<String?> _tryAnalysisCacheKey(String root) async {
  try {
    return await _analysisCacheKey(root);
  } on Object {
    return null;
  }
}

Future<String> _analysisCacheKey(String root) async {
  final files = await _analysisInputFiles(root);
  late Digest digest;
  final digestSink = ChunkedConversionSink<Digest>.withCallback(
    (digests) => digest = digests.single,
  );
  final bytes = sha256.startChunkedConversion(digestSink);
  bytes.add(utf8.encode('$_cacheIdentity\u0000${Platform.version}\u0000'));
  for (final file in files) {
    final relative = p.posix.joinAll(
      p.relative(file.path, from: root).split(p.separator),
    );
    final stat = await file.stat();
    bytes
      ..add(utf8.encode(relative))
      ..add(const [0])
      ..add(utf8.encode(stat.modified.microsecondsSinceEpoch.toString()))
      ..add(const [0]);
    await for (final chunk in file.openRead()) {
      bytes.add(chunk);
    }
    bytes.add(const [0]);
  }
  bytes.close();
  return digest.toString();
}

Future<List<File>> _analysisInputFiles(String root) async {
  final files = <String, File>{};

  void addFile(File file) {
    if (file.existsSync()) files[p.normalize(file.absolute.path)] = file;
  }

  void addDirectory(Directory directory) {
    if (!directory.existsSync()) return;
    for (final file in _projectFiles(directory)) {
      if (file.path.endsWith('.dart') ||
          p.basename(file.path) == 'analysis_options.yaml') {
        addFile(file);
      }
    }
  }

  Future<void> addPackage(Directory packageRoot) async {
    addFile(File(p.join(packageRoot.path, 'pubspec.yaml')));
    addFile(File(p.join(packageRoot.path, 'analysis_options.yaml')));
    final packageConfiguration = File(
      p.join(packageRoot.path, '.dart_tool', 'package_config.json'),
    );
    addFile(packageConfiguration);
    if (!packageConfiguration.existsSync()) return;
    final document =
        (jsonDecode(await packageConfiguration.readAsString()) as Map)
            .cast<String, Object?>();
    final packages = document['packages']! as List<Object?>;
    for (final value in packages) {
      final package = (value! as Map).cast<String, Object?>();
      final rootUri = packageConfiguration.parent.uri
          .resolve(package['rootUri']! as String)
          .normalizePath();
      if (rootUri.scheme != 'file') continue;
      final dependencyRoot = await _resolved(Directory(rootUri.toFilePath()));
      if (p.equals(dependencyRoot.path, packageRoot.path)) continue;
      addFile(File(p.join(dependencyRoot.path, 'pubspec.yaml')));
      addFile(File(p.join(dependencyRoot.path, 'analysis_options.yaml')));
      final library = Directory(p.join(dependencyRoot.path, 'lib'));
      addDirectory(library.existsSync() ? await _resolved(library) : library);
    }
  }

  final nestedPackages = <String, Directory>{};
  for (final name in _sourceDirectories) {
    final directory = Directory(p.join(root, name));
    final resolved = directory.existsSync()
        ? await _resolved(directory)
        : directory;
    addDirectory(resolved);
    if (!resolved.existsSync()) continue;
    for (final file in _projectFiles(resolved)) {
      if (p.basename(file.path) != 'pubspec.yaml') continue;
      final packageRoot = file.parent;
      if (!p.equals(packageRoot.path, root)) {
        nestedPackages[p.normalize(packageRoot.path)] = packageRoot;
      }
    }
  }
  await addPackage(Directory(root));
  final nestedPaths = nestedPackages.keys.toList()..sort();
  for (final path in nestedPaths) {
    await addPackage(nestedPackages[path]!);
  }
  final result = files.values.toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return result;
}

Future<Directory> _resolved(Directory directory) async =>
    Directory(await directory.resolveSymbolicLinks());

FactCache? _defaultFactCache(String root) {
  final directory = defaultAnalyzerCacheDirectory(root);
  return directory == null ? null : FileFactCache(directory);
}

/// 신뢰하지 않는 프로젝트 밖의 사용자 캐시 위치를 선택한다.
Directory? defaultAnalyzerCacheDirectory(
  String canonicalProjectRoot, {
  Map<String, String>? environment,
}) {
  final values = environment ?? Platform.environment;
  String? base;
  if (Platform.isWindows) {
    base = values['LOCALAPPDATA'];
  } else if (Platform.isMacOS) {
    final userDirectory = values['HOME'];
    if (userDirectory != null) {
      base = p.join(userDirectory, 'Library', 'Caches');
    }
  } else {
    final xdg = values['XDG_CACHE_HOME'];
    if (xdg != null && p.isAbsolute(xdg)) {
      base = xdg;
    } else {
      final userDirectory = values['HOME'];
      if (userDirectory != null) base = p.join(userDirectory, '.cache');
    }
  }
  if (base == null || !p.isAbsolute(base)) return null;
  final projectKey = sha256
      .convert(utf8.encode(canonicalProjectRoot))
      .toString();
  return Directory(p.join(base, 'dartograph', projectKey));
}

Future<AnalyzerGraphResult?> _readCachedAnalysis(
  FactCache cache,
  String key,
) async {
  try {
    final payload = await cache.read(key);
    return payload == null ? null : _decodeCachedAnalysis(payload);
  } on Object {
    return null;
  }
}

Future<void> _writeCachedAnalysis(
  FactCache cache,
  String key,
  AnalyzerGraphResult result,
) async {
  try {
    await cache.write(key, _encodeCachedAnalysis(result));
  } on Object {
    // 캐시는 성능 계층이다. 쓸 수 없어도 같은 분석 결과를 반환한다.
  }
}

String _encodeCachedAnalysis(AnalyzerGraphResult result) {
  final snapshot = result.graph.snapshot();
  final rootIds = result.retentionRoots.keys.toList()..sort();
  return jsonEncode({
    'edges': [
      for (final edge in snapshot.edges)
        {
          'kind': edge.kind.name,
          'source': edge.sourceId,
          'target': edge.targetId,
        },
    ],
    'limitationDetails': result.limitationDetails,
    'limitations': result.limitations.map((item) => item.name).toList(),
    'nodes': [
      for (final node in snapshot.nodes)
        {
          'column': ?node.column,
          'id': node.id,
          'isAbstract': node.isAbstract,
          'isTypeDeclaration': node.isTypeDeclaration,
          'line': ?node.line,
          'sourceUri': ?node.sourceUri,
          'synthesized': node.synthesized,
        },
    ],
    'retentionRoots': {
      for (final id in rootIds) id: result.retentionRoots[id]!.name,
    },
    'schemaVersion': _cacheSchemaVersion,
  });
}

AnalyzerGraphResult? _decodeCachedAnalysis(String payload) {
  try {
    final document = (jsonDecode(payload) as Map).cast<String, Object?>();
    if (document['schemaVersion'] != _cacheSchemaVersion) return null;
    final graph = CodeGraph();
    for (final value in document['nodes']! as List<Object?>) {
      final node = (value! as Map).cast<String, Object?>();
      graph.addNode(
        GraphNode(
          id: node['id']! as String,
          sourceUri: node['sourceUri'] as String?,
          line: node['line'] as int?,
          column: node['column'] as int?,
          synthesized: node['synthesized']! as bool,
          isTypeDeclaration: node['isTypeDeclaration']! as bool,
          isAbstract: node['isAbstract']! as bool,
        ),
      );
    }
    for (final value in document['edges']! as List<Object?>) {
      final edge = (value! as Map).cast<String, Object?>();
      graph.addEdge(
        GraphEdge(
          sourceId: edge['source']! as String,
          targetId: edge['target']! as String,
          kind: EdgeKind.values.byName(edge['kind']! as String),
        ),
      );
    }
    final encodedRoots = (document['retentionRoots']! as Map)
        .cast<String, Object?>();
    return AnalyzerGraphResult(
      graph: graph,
      limitations: (document['limitations']! as List<Object?>)
          .map((value) => AnalyzerLimitation.values.byName(value! as String))
          .toList(growable: false),
      limitationDetails: (document['limitationDetails']! as List<Object?>)
          .map((value) => value! as String)
          .toList(growable: false),
      retentionRoots: {
        for (final entry in encodedRoots.entries)
          entry.key: RetentionReason.values.byName(entry.value! as String),
      },
    );
  } on Object {
    return null;
  }
}

List<String> _agentLimitations(String root, List<ResolvedUnitResult> units) {
  final sourceGaps = <String>{};
  for (final unit in units) {
    final source = _sourcePathId(unit.path, root);
    if (unit.diagnostics.any(
      (error) => error.diagnosticCode.severity.name == 'ERROR',
    )) {
      sourceGaps.add('source-analysis-errors: $source');
    }
    final visitor = _UnresolvedInvocationVisitor();
    unit.unit.accept(visitor);
    if (visitor.found) sourceGaps.add('source-unresolved-invocations: $source');
    if (unit.unit.directives.any(
      (directive) => switch (directive) {
        ImportDirective() => directive.configurations.isNotEmpty,
        ExportDirective() => directive.configurations.isNotEmpty,
        _ => false,
      },
    )) {
      sourceGaps.add('source-conditional-configuration: $source');
    }
  }
  final conditionalCount = units.fold<int>(0, (count, unit) {
    return count +
        unit.unit.directives
            .where(
              (directive) => switch (directive) {
                ImportDirective() => directive.configurations.isNotEmpty,
                ExportDirective() => directive.configurations.isNotEmpty,
                _ => false,
              },
            )
            .length;
  });
  final routeTables = <String>{};
  final routeUses = <String>[];
  for (final unit in units) {
    unit.unit.accept(_RouteCollector(routeTables, routeUses));
  }
  final unmatchedRoutes = routeUses
      .where((route) => !routeTables.contains(route))
      .length;
  final staleGenerated = _staleGeneratedCount(root);
  return [
    if (sourceGaps.isNotEmpty)
      'analysis gaps may affect reachability outside the source files where they were observed',
    ...sourceGaps.toList()..sort(),
    if (conditionalCount > 0)
      'conditional-imports: $conditionalCount directive(s) use only the analyzer-selected configuration',
    if (unmatchedRoutes > 0)
      'string-routes: $unmatchedRoutes named route use(s) have no matching route table entry',
    if (staleGenerated > 0)
      'generated-code-staleness: $staleGenerated generated file(s) are older than their source',
  ];
}

final class _UnresolvedInvocationVisitor extends RecursiveAstVisitor<void> {
  bool found = false;
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.element == null) found = true;
    super.visitMethodInvocation(node);
  }
}

final class _RouteCollector extends RecursiveAstVisitor<void> {
  _RouteCollector(this.tables, this.uses);

  final Set<String> tables;
  final List<String> uses;

  @override
  void visitMapLiteralEntry(MapLiteralEntry node) {
    final key = node.key;
    final map = node.parent;
    final owner = map?.parent;
    final isRouteTable =
        (owner is VariableDeclaration && owner.name.lexeme == 'routes') ||
        (owner is NamedArgument && owner.name.lexeme == 'routes');
    if (isRouteTable && key is SimpleStringLiteral) tables.add(key.value);
    super.visitMapLiteralEntry(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_namedNavigationMethods.contains(node.methodName.name)) {
      final arguments = node.argumentList.arguments;
      final target = node.target;
      final staticNavigator =
          target is SimpleIdentifier && target.name == 'Navigator';
      final routeIndex = staticNavigator ? 1 : 0;
      if (arguments.length > routeIndex &&
          arguments[routeIndex] is SimpleStringLiteral) {
        uses.add((arguments[routeIndex] as SimpleStringLiteral).value);
      }
    }
    super.visitMethodInvocation(node);
  }
}

int _staleGeneratedCount(String root) {
  var count = 0;
  for (final name in _sourceDirectories) {
    final directory = Directory(p.join(root, name));
    if (!directory.existsSync()) continue;
    for (final entity in _projectFiles(directory)) {
      if (!_isGenerated(entity.path)) continue;
      final suffix = RegExp(r'\.(g|freezed|pb)\.dart$').firstMatch(entity.path);
      if (suffix == null) continue;
      final source = File(
        entity.path.replaceRange(suffix.start, suffix.end, '.dart'),
      );
      if (source.existsSync() &&
          source.lastModifiedSync().isAfter(entity.lastModifiedSync())) {
        count++;
      }
    }
  }
  return count;
}

Iterable<File> _projectFiles(Directory directory) sync* {
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is Directory) {
      if (_ignoredProjectDirectories.contains(p.basename(entity.path))) {
        continue;
      }
      yield* _projectFiles(entity);
    } else if (entity is File) {
      yield entity;
    }
  }
}

const _ignoredProjectDirectories = {'.dart_tool', '.git', 'build'};
const _namedNavigationMethods = {
  'popAndPushNamed',
  'pushNamed',
  'pushNamedAndRemoveUntil',
  'pushReplacementNamed',
  'restorablePopAndPushNamed',
  'restorablePushNamed',
  'restorablePushNamedAndRemoveUntil',
  'restorablePushReplacementNamed',
};

String? _dartSdkPath() {
  final resolved = File(Platform.resolvedExecutable);
  final candidates = <File>[resolved];
  final path = Platform.environment['PATH'];
  if (path != null) {
    for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
      candidates.add(
        File(p.join(directory, Platform.isWindows ? 'dart.exe' : 'dart')),
      );
    }
  }
  for (final candidate in candidates) {
    if (!candidate.existsSync()) continue;
    final executable = File(candidate.resolveSymbolicLinksSync());
    final sdk = executable.parent.parent;
    if (File(
      p.join(
        sdk.path,
        'lib',
        '_internal',
        'sdk_library_metadata',
        'lib',
        'libraries.dart',
      ),
    ).existsSync()) {
      return sdk.path;
    }
  }
  return null;
}

final class _DeclarationCollector extends GeneralizingAstVisitor<void> {
  _DeclarationCollector(this.graph, this.root, this.retentionRoots);

  final CodeGraph graph;
  final String root;
  final Map<String, RetentionReason> retentionRoots;

  @override
  void visitDeclaration(Declaration node) {
    final element = node.declaredFragment?.element;
    if (element != null && _isGraphElement(element)) {
      final location = node
          .thisOrAncestorOfType<CompilationUnit>()!
          .lineInfo
          .getLocation(node.offset);
      final id = _elementId(element, root);
      if (!graph.containsNode(id)) {
        graph.addNode(
          GraphNode(
            id: id,
            sourceUri: _sourcePathId(
              element.firstFragment.libraryFragment!.source.fullName,
              root,
            ),
            line: location.lineNumber,
            column: location.columnNumber,
            synthesized: _isGenerated(
              element.firstFragment.libraryFragment!.source.fullName,
            ),
            isTypeDeclaration: element is InterfaceElement,
            isAbstract:
                (element is ClassElement && element.isAbstract) ||
                element is MixinElement,
          ),
        );
      }
      final source = _sourcePathId(
        element.firstFragment.libraryFragment!.source.fullName,
        root,
      );
      final reason = _retentionReason(node, element, source);
      if (reason != null) retentionRoots[id] = reason;
    }
    super.visitDeclaration(node);
  }
}

RetentionReason? _retentionReason(
  Declaration node,
  Element element,
  String source,
) {
  if (element is TopLevelFunctionElement &&
      element.displayName == 'main' &&
      const [
        'project:lib/',
        'project:bin/',
        'project:example/',
      ].any(source.startsWith)) {
    return RetentionReason.mainEntryPoint;
  }
  if (source.startsWith('project:test/') ||
      source.startsWith('project:integration_test/') ||
      source.startsWith('project:example/test/') ||
      source.startsWith('project:example/integration_test/')) {
    return RetentionReason.visibleForTesting;
  }
  if (_isGenerated(source)) return RetentionReason.generatedCode;
  for (final annotation in node.metadata) {
    final name = annotation.name.name.split('.').last;
    final annotationLibrary = annotation.element?.library?.uri.toString();
    if (name == 'override' && annotationLibrary == 'dart:core') {
      return RetentionReason.overrideContract;
    }
    if (name == 'visibleForTesting' &&
        annotationLibrary == 'package:meta/meta.dart') {
      return RetentionReason.visibleForTesting;
    }
    final arguments = annotation.arguments?.arguments;
    if (name == 'pragma' &&
        annotationLibrary == 'dart:core' &&
        arguments?.length == 1 &&
        arguments!.single is SimpleStringLiteral &&
        (arguments.single as SimpleStringLiteral).value == 'vm:entry-point') {
      return RetentionReason.vmEntryPoint;
    }
  }
  if (_overridesInheritedMember(element)) {
    return RetentionReason.overrideContract;
  }
  return null;
}

void _addPublicApiRoots(
  String root,
  Map<String, LibraryElement> libraries,
  CodeGraph graph,
  Map<String, RetentionReason> roots,
) {
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return;
  final document = loadYaml(pubspec.readAsStringSync());
  final packageName = document is YamlMap ? document['name'] : null;
  if (packageName is! String ||
      !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(packageName)) {
    throw const FormatException('pubspec name must be a valid package name');
  }
  final entryPath = p.normalize(p.join(root, 'lib', '$packageName.dart'));
  final entryLibrary = libraries.values.where((library) {
    return p.normalize(library.firstFragment.source.fullName) == entryPath;
  }).firstOrNull;
  if (entryLibrary == null) return;
  final exported = entryLibrary.exportNamespace.definedNames2.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final entry in exported) {
    if (entry.key.startsWith('_')) continue;
    final id = _elementId(_graphTarget(entry.value) ?? entry.value, root);
    if (!graph.containsNode(id)) continue;
    roots.putIfAbsent(id, () => RetentionReason.publicApi);
    final memberPrefix = '$id.';
    for (final nodeId in graph.nodes.keys.where(
      (candidate) => candidate.startsWith(memberPrefix),
    )) {
      final memberName = nodeId.substring(memberPrefix.length);
      if (!memberName.contains('.') && !memberName.startsWith('_')) {
        roots.putIfAbsent(nodeId, () => RetentionReason.publicApi);
      }
    }
  }
}

bool _overridesInheritedMember(Element element) {
  if (element is! ExecutableElement) return false;
  final enclosing = element.enclosingElement;
  final name = element.name;
  return enclosing is InterfaceElement &&
      name != null &&
      enclosing.inheritedMembers.values.any(
        (candidate) => candidate.name == name,
      );
}

Set<AnalyzerLimitation> _addPluginRoots(
  String root,
  CodeGraph graph,
  Map<String, RetentionReason> roots,
) {
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return const {};
  final matches = RegExp(
    r'^\s*(?:pluginClass|dartPluginClass):\s*([A-Za-z_$][\w$]*)\s*$',
    multiLine: true,
  ).allMatches(pubspec.readAsStringSync());
  final classNames = <String>{for (final match in matches) match.group(1)!};
  final limitations = <AnalyzerLimitation>{};
  for (final className in classNames) {
    final candidates =
        graph.nodes.keys.where((id) => id.endsWith('::$className')).toList()
          ..sort();
    if (candidates.isEmpty) {
      limitations.add(AnalyzerLimitation.unresolvedPluginEntryPoint);
      continue;
    }
    if (candidates.length > 1) {
      limitations.add(AnalyzerLimitation.ambiguousPluginEntryPoint);
    }
    for (final candidate in candidates) {
      roots[candidate] = RetentionReason.pluginEntryPoint;
      final registration = '$candidate.registerWith';
      if (graph.containsNode(registration)) {
        roots[registration] = RetentionReason.pluginEntryPoint;
      }
    }
  }
  return limitations;
}

final class _RelationshipCollector extends GeneralizingAstVisitor<void> {
  _RelationshipCollector(this.graph, this.root);

  final CodeGraph graph;
  final String root;
  String? _owner;

  @override
  void visitDeclaration(Declaration node) {
    final previous = _owner;
    final element = node.declaredFragment?.element;
    if (element != null && _isGraphElement(element)) {
      _owner = _elementId(element, root);
      final enclosing = element.enclosingElement;
      if (enclosing != null && _isGraphElement(enclosing)) {
        _add(_elementId(enclosing, root), _owner!, EdgeKind.member);
      }
      if (element is InterfaceElement) {
        final supertype = element.supertype;
        if (supertype != null &&
            supertype.element.library.uri.scheme != 'dart') {
          _add(
            _owner!,
            _elementId(supertype.element, root),
            EdgeKind.inheritance,
          );
        }
        for (final type in element.interfaces) {
          _add(_owner!, _elementId(type.element, root), EdgeKind.implements);
        }
        for (final type in element.mixins) {
          _add(_owner!, _elementId(type.element, root), EdgeKind.mixin);
        }
      }
      if (element is ExecutableElement && enclosing is InterfaceElement) {
        final name = element.name;
        if (name != null) {
          for (final overridden in enclosing.inheritedMembers.values.where(
            (candidate) => candidate.name == name,
          )) {
            _add(
              _owner!,
              _elementId(overridden.baseElement, root),
              EdgeKind.override,
            );
          }
        }
      }
    }
    node.visitChildren(this);
    _owner = previous;
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final owner = _owner;
    final element = _graphTarget(node.element);
    if (owner != null && !node.inDeclarationContext() && element != null) {
      final target = _callTarget(node, element);
      if (target != null && _isGraphElement(target)) {
        _add(
          owner,
          _elementId(target, root),
          _isCall(node) ? EdgeKind.call : EdgeKind.reference,
        );
      }
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final owner = _owner;
    final target = node.constructorName.element?.enclosingElement;
    if (owner != null && target != null && _isGraphElement(target)) {
      _add(owner, _elementId(target, root), EdgeKind.call);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final owner = _owner;
    final target = _graphTarget(node.writeElement);
    if (owner != null && target != null && _isGraphElement(target)) {
      _add(owner, _elementId(target, root), EdgeKind.reference);
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final owner = _owner;
    final element = node.element?.baseElement;
    final parent = node.parent;
    final isStructural =
        parent is ExtendsClause ||
        parent is ImplementsClause ||
        parent is WithClause ||
        parent is ConstructorName;
    if (owner != null &&
        element != null &&
        !isStructural &&
        _isGraphElement(element)) {
      _add(owner, _elementId(element, root), EdgeKind.reference);
    }
    super.visitNamedType(node);
  }

  Element? _callTarget(SimpleIdentifier node, Element element) {
    final constructorName = node.thisOrAncestorOfType<ConstructorName>();
    if (constructorName != null) {
      return constructorName.element?.enclosingElement ?? element;
    }
    return element;
  }

  bool _isCall(SimpleIdentifier node) {
    final parent = node.parent;
    return (parent is MethodInvocation && parent.methodName == node) ||
        (parent is FunctionExpressionInvocation && parent.function == node) ||
        node.thisOrAncestorOfType<ConstructorName>() != null;
  }

  void _add(String source, String target, EdgeKind kind) {
    if (source != target &&
        graph.containsNode(source) &&
        graph.containsNode(target)) {
      graph.addEdge(GraphEdge(sourceId: source, targetId: target, kind: kind));
    }
  }
}

Element? _graphTarget(Element? element) {
  final base = element?.baseElement;
  return switch (base) {
    GetterElement() => base.variable,
    SetterElement() => base.variable,
    _ => base,
  };
}

bool _isGraphElement(Element element) =>
    element is ClassElement ||
    element is MixinElement ||
    element is EnumElement ||
    element is ExtensionElement ||
    element is ExtensionTypeElement ||
    element is TopLevelFunctionElement ||
    element is MethodElement ||
    element is FieldElement ||
    element is TopLevelVariableElement ||
    element is GetterElement ||
    element is SetterElement;

String _elementId(Element element, String root) {
  final libraryUri = _libraryId(element.library?.uri, root);
  final names = <String>[];
  Element? current = element;
  while (current != null && current is! LibraryElement) {
    final name = current.lookupName ?? current.displayName;
    if (name.isNotEmpty) {
      names.add(name);
    } else if (current is ExtensionElement) {
      final sourceId = _sourceId(
        current.firstFragment.libraryFragment.source.uri,
        root,
      );
      names.add(
        '<unnamed-extension@$sourceId#${current.firstFragment.offset}>',
      );
    }
    current = current.enclosingElement;
  }
  return '$libraryUri::${names.reversed.join('.')}';
}

String _libraryId(Uri? uri, String root) {
  if (uri == null) return '<no-library>';
  if (uri.scheme != 'file') return uri.toString();
  return _sourceId(uri, root);
}

String _sourceId(Uri uri, String root) {
  if (uri.scheme != 'file') return uri.toString();
  return projectIdForPath(File.fromUri(uri).absolute.path, root);
}

String _sourcePathId(String path, String root) {
  return projectIdForPath(path, root);
}

/// [path]를 플랫폼 경로 구분자와 무관한 프로젝트 source ID로 바꾼다.
String projectIdForPath(String path, String root, {p.Context? context}) {
  final paths = context ?? p.context;
  final absolutePath = paths.normalize(paths.absolute(path));
  final absoluteRoot = paths.normalize(paths.absolute(root));
  if (!isPathWithinRoot(absolutePath, absoluteRoot, context: paths)) {
    return Uri.file(
      absolutePath,
      windows: paths.style == p.Style.windows,
    ).toString();
  }
  final relativePath = paths.relative(absolutePath, from: absoluteRoot);
  return 'project:${p.url.joinAll(paths.split(relativePath))}';
}

/// [path]가 [root] 자체이거나 그 아래인지 플랫폼 구분자에 맞춰 확인한다.
bool isPathWithinRoot(String path, String root, {p.Context? context}) {
  final paths = context ?? p.context;
  final absolutePath = paths.normalize(paths.absolute(path));
  final absoluteRoot = paths.normalize(paths.absolute(root));
  return paths.equals(absolutePath, absoluteRoot) ||
      paths.isWithin(absoluteRoot, absolutePath);
}

List<String> _dartFilesUnder(
  String root,
  AnalysisContextCollection collection,
) {
  final paths = <String>{};
  for (final context in collection.contexts) {
    paths.addAll(
      context.contextRoot.analyzedFiles().where(
        (path) =>
            path.endsWith('.dart') &&
            isPathWithinRoot(path, root) &&
            _isStandardSourcePath(path, root),
      ),
    );
  }
  paths.addAll(
    Directory(root)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((file) => file.path)
        .where(_isGenerated)
        .where((path) => _isStandardSourcePath(path, root))
        .where(
          (path) => !p
              .split(p.relative(path, from: root))
              .any((segment) => segment == '.dart_tool' || segment == 'build'),
        ),
  );
  return paths.toList()..sort();
}

bool _isStandardSourcePath(String path, String root) {
  final relative = p.relative(path, from: root);
  final segments = p.split(relative);
  return segments.isNotEmpty && _sourceDirectories.contains(segments.first);
}

const _sourceDirectories = {
  'bin',
  'example',
  'integration_test',
  'lib',
  'test',
};

AnalysisContext _contextIncluding(
  AnalysisContextCollection collection,
  String path,
) {
  try {
    return collection.contextFor(path);
  } on StateError {
    final contexts = [...collection.contexts]
      ..sort(
        (a, b) => b.contextRoot.root.path.length.compareTo(
          a.contextRoot.root.path.length,
        ),
      );
    return contexts.firstWhere(
      (context) => isPathWithinRoot(path, context.contextRoot.root.path),
      orElse: () => throw StateError(
        'No analyzer context contains the generated source.',
      ),
    );
  }
}

bool _isGenerated(String path) => _generatedDartSuffixes.any(path.endsWith);

const _generatedDartSuffixes = {
  '.g.dart',
  '.freezed.dart',
  '.pb.dart',
  '.pbenum.dart',
  '.pbgrpc.dart',
  '.pbjson.dart',
  '.pbserver.dart',
};
