import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
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
      final entryPoints = _readEntryPoints(root);
      final mainEntrySources = <String>{};
      for (final unit in units) {
        final libraryId = _libraryId(unit.libraryElement.uri, root);
        if (!graph.containsNode(libraryId)) {
          graph.addNode(GraphNode(id: libraryId));
        }
        unit.unit.accept(
          _DeclarationCollector(
            graph,
            root,
            retentionRoots,
            entryPoints,
            mainEntrySources,
          ),
        );
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
      final limitationDetails = _agentLimitations(root, units);
      if (entryPoints != null) {
        final missing = entryPoints.difference(mainEntrySources).toList()
          ..sort();
        for (final source in missing) {
          limitationDetails.add(
            'configured-entry-point-without-main: ${source.substring('project:'.length)}',
          );
        }
      }
      final result = AnalyzerGraphResult(
        graph: graph,
        limitations: limitations.toList()..sort((a, b) => a.index - b.index),
        limitationDetails: limitationDetails,
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

// 노드 직렬화에 isEnumConstant를 추가해 스키마를 v2로 올렸다. 옛 캐시는 decode에서
// schemaVersion 불일치로 거부되어 재분석됐으므로 그때는 identity를 올리지 않았다.
const _cacheSchemaVersion = 2;
// 연산자 호출 usage 간선(v4)과 dartograph:ignore 주석 보존 루트(v5) 추가로
// 추출 의미가 바뀌어 identity를 올린다. 직렬화 형식(노드·간선·루트 필드)은
// 그대로라 schemaVersion은 v2를 유지한다.
const _cacheIdentity =
    'dartograph-analysis-$toolVersion-cache-v5-inline-ignore';

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
    addFile(File(p.join(packageRoot.path, 'dartograph.yaml')));
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
          'isEnumConstant': node.isEnumConstant,
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
          isEnumConstant: node['isEnumConstant']! as bool,
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

Iterable<File> _projectFiles(Directory directory) =>
    _projectFilesIn(directory, <String>{});

/// [directory] 아래의 파일을 심볼릭 링크까지 따라가며 돌려준다.
///
/// `followLinks: false` 목록에서 심볼릭 링크는 `Link`로 나와 `File`·`Directory`
/// 분기에 걸리지 않는다. 그런데 analyzer는 링크 경로를 그대로 분석 대상에
/// 넣으므로, 링크를 빠뜨리면 링크된 소스가 그래프에는 있고 캐시 키에는 없어
/// 대상을 수정해도 낡은 사실이 재사용된다.
///
/// [visitedLinkTargets]는 이미 따라간 디렉터리 링크의 실제 경로다. 링크 순환에서
/// 무한 재귀하지 않도록 같은 대상은 한 번만 순회한다. 링크 자체의 경로로 재귀해
/// analyzer가 사용하는 경로와 같은 모양을 유지한다.
Iterable<File> _projectFilesIn(
  Directory directory,
  Set<String> visitedLinkTargets,
) sync* {
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is Directory) {
      if (_ignoredProjectDirectories.contains(p.basename(entity.path))) {
        continue;
      }
      yield* _projectFilesIn(entity, visitedLinkTargets);
    } else if (entity is File) {
      yield entity;
    } else if (entity is Link) {
      // typeSync는 링크를 따라가므로 끊어진 링크는 notFound가 되어 제외된다.
      final type = FileSystemEntity.typeSync(entity.path);
      if (type == FileSystemEntityType.file) {
        yield File(entity.path);
      } else if (type == FileSystemEntityType.directory &&
          !_ignoredProjectDirectories.contains(p.basename(entity.path))) {
        final target = _resolvedLinkTarget(entity);
        if (target != null && visitedLinkTargets.add(target)) {
          yield* _projectFilesIn(Directory(entity.path), visitedLinkTargets);
        }
      }
    }
  }
}

/// 디렉터리 링크의 실제 경로를 돌려주고, 해석에 실패하면 null을 돌려준다.
///
/// [FileSystemEntity.typeSync]로 종류를 확인한 뒤 실제 경로를 해석하기까지의
/// 사이에 외부 프로세스가 대상을 지우면 [FileSystemException]이 난다. 그 경우
/// 인덱싱 전체를 실패시키지 않고 그 링크만 건너뛴다.
String? _resolvedLinkTarget(Link link) {
  try {
    return link.resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
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
  _DeclarationCollector(
    this.graph,
    this.root,
    this.retentionRoots,
    this.entryPoints,
    this.mainEntrySources,
  );

  final CodeGraph graph;
  final String root;
  final Map<String, RetentionReason> retentionRoots;

  /// null이면 `lib/`·`bin/`·`example/`의 모든 main을 보수적으로 보존한다.
  /// 값이 있으면 나열된 진입점 파일의 main만 보존 루트로 삼는다.
  final Set<String>? entryPoints;

  /// 관측된 main 진입점의 source ID다. 설정 검증 한계를 계산하는 데 쓴다.
  final Set<String> mainEntrySources;

  /// 컴파일 단위별로 캐시한 `dartograph:ignore` 주석의 부착 토큰 offset이다.
  final Map<CompilationUnit, Set<int>> _ignoreClaims = {};

  @override
  void visitDeclaration(Declaration node) {
    final element = node.declaredFragment?.element;
    if (element != null && _isGraphElement(element)) {
      final unit = node.thisOrAncestorOfType<CompilationUnit>()!;
      final location = unit.lineInfo.getLocation(node.offset);
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
            isEnumConstant: element is FieldElement && element.isEnumConstant,
          ),
        );
      }
      final source = _sourcePathId(
        element.firstFragment.libraryFragment!.source.fullName,
        root,
      );
      // 사용자의 명시적 억제 지시(인라인 주석)가 다른 보존 이유보다 먼저다.
      // 둘 다 보존이지만 explain은 실제로 작동한 근거를 답해야 한다.
      final claims = _ignoreClaimsFor(unit);
      final ignored =
          claims.contains(node.offset) ||
          claims.contains(node.firstTokenAfterCommentAndMetadata.offset);
      final reason = ignored
          ? RetentionReason.inlineIgnore
          : _retentionReason(
              node,
              element,
              source,
              entryPoints,
              mainEntrySources,
            );
      if (reason != null) retentionRoots[id] = reason;
    }
    super.visitDeclaration(node);
  }

  Set<int> _ignoreClaimsFor(CompilationUnit unit) =>
      _ignoreClaims.putIfAbsent(unit, () => _collectIgnoreClaims(unit));

  /// `// dartograph:ignore` 주석이 부착되는 선언 claim 토큰의 offset을 모은다.
  ///
  /// 주석은 다음 실 토큰의 precedingComments 사슬에 붙는다. 실 토큰이 선언의
  /// 첫 토큰(annotation `@`·doc 뒤 키워드)이면 그 선언의 억제로 해석한다.
  /// 같은 줄 꼬리 주석(이전 실 토큰의 끝 줄에서 끝나지 않고 시작된 주석)은
  /// 다음 선언의 억제가 아니다 — `void a() {} // dartograph:ignore`가 b를
  /// 억제하지 않는다. 선언 claim이 아닌 토큰(클래스 `{`·`;` 등)에 붙은
  /// 주석은 visitDeclaration의 offset 대조에서 자연스럽게 버려진다.
  static Set<int> _collectIgnoreClaims(CompilationUnit unit) {
    final lineInfo = unit.lineInfo;
    final claims = <int>{};
    Token? token = unit.beginToken;
    while (token != null && token.type != TokenType.EOF) {
      var comment = token.precedingComments;
      while (comment != null) {
        if (comment.lexeme.contains('dartograph:ignore')) {
          // 파일 첫 토큰의 previous는 offset -1의 EOF 센티널이라 이전 토큰
          // 없음과 같이 취급한다.
          final previous = token.previous;
          final leading =
              previous == null ||
              previous.offset < 0 ||
              lineInfo.getLocation(comment.offset).lineNumber >
                  lineInfo.getLocation(previous.end).lineNumber;
          if (leading) claims.add(token.offset);
        }
        comment = comment.next as CommentToken?;
      }
      token = token.next;
    }
    return claims;
  }
}

/// `entry_points`가 가리킬 수 있는 보존 루트 디렉터리다.
/// 이 밖의 `main`은 원래 mainEntryPoint 루트가 아니므로 설정으로 받지 않는다.
const _entryPointDirectories = {'bin', 'example', 'lib'};

/// 프로젝트 루트의 선택적 `dartograph.yaml`에서 `entry_points`를 읽어
/// canonical `project:` source ID 집합으로 변환한다.
///
/// 파일이나 `entry_points` 키가 없으면 null을 반환해 기본 보수 정책
/// (`lib/`·`bin/`·`example/`의 모든 main 보존)을 유지한다. 아무것도 선언하지 않는
/// 문서(빈 문서·주석뿐·`---`만·명시적 `null`)도 같게 취급한다. 항목이 비어 있거나
/// 문자열이 아니거나, 절대·루트 밖 경로이거나, `lib/`·`bin/`·`example/` 밖이거나,
/// 존재하지 않거나, `.dart`가 아니면 [FormatException]을 던진다. 잘못된 설정으로
/// 사용자가 선언한 build target이 조용히 무시되거나 보존 루트가 잘못 좁혀지는
/// 것을 막기 위해서다. malformed YAML의 `YamlException`도 `FormatException`이라
/// 같은 종료 코드 계약(2)을 따른다.
Set<String>? _readEntryPoints(String root) {
  final file = File(p.join(root, 'dartograph.yaml'));
  if (!file.existsSync()) return null;
  final document = loadYaml(file.readAsStringSync());
  // loadYaml은 빈 문서·주석뿐인 문서·`---`만 있는 문서·명시적 `null`을 모두
  // null로 돌려준다. 선언한 진입점이 없다는 점에서 키가 없는 것과 같으므로 기본
  // 보수 정책으로 되돌린다. 내용이 있는데 mapping이 아닌 문서만 거부한다.
  if (document == null) return null;
  if (document is! YamlMap) {
    throw const FormatException('dartograph.yaml must be a YAML mapping');
  }
  final raw = document['entry_points'];
  if (raw == null) return null;
  if (raw is! YamlList || raw.isEmpty) {
    throw const FormatException(
      'entry_points must be a non-empty list of project-relative .dart paths',
    );
  }
  final sources = <String>{};
  for (final entry in raw) {
    if (entry is! String || entry.trim().isEmpty) {
      throw const FormatException(
        'entry_points entries must be non-empty strings',
      );
    }
    sources.add(_entryPointSourceId(root, entry));
  }
  return sources;
}

/// 사용자 설정 진입점을 검증하고 analyzer source ID와 일치하는 canonical
/// `project:` ID로 변환한다. symlink·대소문자 차이를 resolveSymbolicLinks로
/// 정규화해 보존 루트 매칭이 어긋나지 않게 한다.
String _entryPointSourceId(String root, String entry) {
  final lexical = p.posix.normalize(entry.replaceAll(r'\', p.posix.separator));
  if (p.posix.isAbsolute(lexical) ||
      lexical == '..' ||
      lexical.startsWith('../')) {
    throw FormatException(
      'entry_points must be project-relative paths: $entry',
    );
  }
  final file = File(p.join(root, lexical));
  if (!file.existsSync()) {
    throw FormatException('entry_points file does not exist: $entry');
  }
  final id = projectIdForPath(file.resolveSymbolicLinksSync(), root);
  if (!id.startsWith('project:')) {
    throw FormatException(
      'entry_points must resolve inside the package: $entry',
    );
  }
  final relative = id.substring('project:'.length);
  if (!_entryPointDirectories.contains(relative.split('/').first) ||
      !relative.endsWith('.dart')) {
    throw FormatException(
      'entry_points must be .dart files under lib/, bin/, or example/: $entry',
    );
  }
  return id;
}

RetentionReason? _retentionReason(
  Declaration node,
  Element element,
  String source,
  Set<String>? entryPoints,
  Set<String> mainEntrySources,
) {
  if (element is TopLevelFunctionElement &&
      element.displayName == 'main' &&
      const [
        'project:lib/',
        'project:bin/',
        'project:example/',
      ].any(source.startsWith)) {
    mainEntrySources.add(source);
    if (entryPoints == null || entryPoints.contains(source)) {
      return RetentionReason.mainEntryPoint;
    }
    // 설정된 진입점이 아닌 main은 강제 루트로 보존하지 않는다.
    // 다른 보존 근거(pragma·생성 코드 등)는 계속 검사한다.
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
    // 복합 대입(`a += b`)은 연산자도 호출한다. 단순 대입에서는 null이다.
    _addOperatorCall(node.element);
    _addCompoundIndexTargets(node);
    super.visitAssignmentExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    _addOperatorCall(node.element);
    super.visitBinaryExpression(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    _addOperatorCall(node.element);
    super.visitIndexExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _addOperatorCall(node.element);
    _addCompoundIndexTargets(node);
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _addOperatorCall(node.element);
    _addCompoundIndexTargets(node);
    super.visitPostfixExpression(node);
  }

  /// 복합 대입·증감(`m[i] += v`·`m[i]++`·`++m[i]`)의 인덱스 읽기·쓰기는
  /// `[]`·`[]=` 연산자를 거치는데 writeElement만 보면 읽기가 누락된다.
  /// 속성(getter·setter) 읽기·쓰기는 식별자 경로가 이미 잡으므로
  /// 연산자(MethodElement) 경우만 보탠다.
  void _addCompoundIndexTargets(CompoundAssignmentExpression node) {
    for (final element in [node.readElement, node.writeElement]) {
      if (element is MethodElement) {
        _addOperatorCall(element);
      }
    }
  }

  /// 연산자 호출은 식별자가 아니라 토큰이라 [visitSimpleIdentifier] 경로를
  /// 타지 않는다. dart:core 같은 내장 연산자는 그래프 노드가 없으므로
  /// [_add]의 양끝 존재 검사에서 걸러진다.
  void _addOperatorCall(MethodElement? element) {
    final owner = _owner;
    if (owner == null) return;
    final target = _graphTarget(element);
    if (target != null && _isGraphElement(target)) {
      _add(owner, _elementId(target, root), EdgeKind.call);
    }
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
