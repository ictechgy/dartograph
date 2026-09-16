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

import '../core/config_source.dart';
import '../core/code_graph.dart';
import '../core/fact_cache.dart';
import '../core/graph_edge.dart';
import '../core/graph_node.dart';
import '../core/retention_reason.dart';
import '../core/tool_info.dart';
import 'incremental_cache.dart';

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
    this.packageName,
    this.declaredDependencies = const [],
    this.declaredDevDependencies = const [],
    this.declaredDependencyOverrides = const [],
    this.packageImports = const {},
  });

  /// resolved unit에서 얻은 선언과 관계다.
  final CodeGraph graph;

  /// 결과 해석 시 항상 알려야 하는 analyzer 한계다.
  final List<AnalyzerLimitation> limitations;

  /// 프로젝트에서 실제로 센, 에이전트 응답용 분석 한계다.
  final List<String> limitationDetails;

  /// analyzer와 manifest에서 확인한 명시적 보존 루트다.
  final Map<String, RetentionReason> retentionRoots;

  /// pubspec의 패키지 이름이다. pubspec 부재·파싱 불가면 null이다.
  final String? packageName;

  /// pubspec `dependencies` 섹션의 선언 패키지 이름이다(정렬).
  final List<String> declaredDependencies;

  /// pubspec `dev_dependencies` 섹션의 선언 패키지 이름이다(정렬).
  final List<String> declaredDevDependencies;

  /// pubspec `dependency_overrides` 섹션의 선언 패키지 이름이다(정렬).
  final List<String> declaredDependencyOverrides;

  /// 분석 대상 소스가 import/export 지시문으로 참조한 `package:` 이름 → 그
  /// 이름을 참조하는 소스 ID(`project:…`) 목록(각 목록 정렬). 미해결 지시문도
  /// 선언된 URI 기준으로 센다 — 미해결을 건너뛰면 미선언 의존 신호가 사라진다.
  final Map<String, List<String>> packageImports;
}

/// analyzer 14.3.0 resolved unit을 안정적인 core 그래프로 바꾼다.
final class AnalyzerGraphIndex {
  /// 기본 프로젝트 캐시 또는 테스트가 주입한 [cache]를 사용한다.
  ///
  /// [incremental]이 주어지면 파일 단위 사실 캐시를 쓰는 증분 경로를 탄다. 이때는
  /// 전체 결과 캐시를 읽지도 쓰지도 않는다 — 입력 해시를 두 번 계산하지 않고,
  /// 사실 캐시가 같은 역할을 더 좁은 단위로 한다.
  AnalyzerGraphIndex({FactCache? cache, IncrementalCache? incremental})
    : _cache = cache,
      _incremental = incremental;

  final FactCache? _cache;
  final IncrementalCache? _incremental;

  /// [rootPath] 아래 분석 대상과 제외된 생성 파일을 함께 색인한다.
  Future<AnalyzerGraphResult> index(String rootPath) async {
    final root = Directory(rootPath).absolute.resolveSymbolicLinksSync();
    final sourcePackages = _readSourcePackages(root);
    final cache = _incremental != null
        ? null
        : _cache ?? _defaultFactCache(root);
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
    try {
      final result = await _analyze(root, collection, sourcePackages);
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

  /// 분석 대상 파일의 사실을 모아 그래프를 조립한다.
  ///
  /// 증분 캐시가 없으면 모든 대상을 해석한다(기존 경로). 있으면 파일 키를 비교해
  /// 바뀐 파일과 역방향 import 폐쇄만 다시 해석하고 나머지는 캐시된 사실을 쓴다.
  /// 두 경로가 같은 조립 함수를 지나므로 같은 사실에서 같은 산출물이 나온다.
  Future<AnalyzerGraphResult> _analyze(
    String root,
    AnalysisContextCollection collection,
    List<Directory> sourcePackages,
  ) async {
    final unitPaths = _dartFilesUnder(root, collection, sourcePackages);
    final entryPoints = _readEntryPoints(root);
    final pubspecContent = _readPubspec(root);
    // pubspec 이름 검증은 두 경로가 같은 시점에 실패하도록 해석 전에 한다
    // (잘못된 이름은 조립 단계의 FormatException, 종료 코드 2다).
    final entryLibraryPath = _entryLibraryPath(root, pubspecContent);
    final incremental = _incremental;
    if (incremental == null) {
      final facts = <String, _UnitFacts>{};
      final sources = <String>[];
      for (final path in unitPaths) {
        final extracted = await _resolveUnitFacts(
          root: root,
          collection: collection,
          path: path,
          entryPoints: entryPoints,
          entryLibraryPath: entryLibraryPath,
        );
        if (extracted == null) continue;
        facts[extracted.source] = extracted;
        sources.add(extracted.source);
      }
      return _assembleResult(
        root: root,
        sources: sources,
        facts: facts,
        entryPoints: entryPoints,
        pubspecContent: pubspecContent,
      );
    }
    return _analyzeIncrementally(
      root: root,
      collection: collection,
      unitPaths: unitPaths,
      entryPoints: entryPoints,
      pubspecContent: pubspecContent,
      entryLibraryPath: entryLibraryPath,
      incremental: incremental,
    );
  }

  /// 바뀐 파일과 그 역방향 import 폐쇄만 다시 해석하는 경로다.
  ///
  /// 캐시는 최적화지 계약이 아니다 — 손상·부재·스키마 불일치·쓰기 실패는 전체
  /// 해석으로 폴백하고 분석은 정상 수행한다(`doc/DECISION-incremental.md` 5절).
  Future<AnalyzerGraphResult> _analyzeIncrementally({
    required String root,
    required AnalysisContextCollection collection,
    required List<String> unitPaths,
    required Set<String>? entryPoints,
    required String? pubspecContent,
    required String? entryLibraryPath,
    required IncrementalCache incremental,
  }) async {
    final sourcesOf = <String, String>{
      for (final path in unitPaths) path: ?_relativeSourcePath(path, root),
    };
    final inputs = await _incrementalInputs(root, sourcesOf.values.toSet());
    final resolutionKey = IncrementalCache.resolutionKey(
      toolVersion: toolVersion,
      sdkVersion: Platform.version,
      configFingerprint: inputs.configFingerprint,
    );
    final currentKeys = <String, String>{
      for (final entry in inputs.unitHashes.entries)
        entry.key: IncrementalCache.keyFor(
          resolutionKey: resolutionKey,
          contentHash: entry.value,
        ),
    };
    final cached = await incremental.load();
    // 이전 실행의 의존 표로 역방향 폐쇄를 만든다. 캐시에만 있는 파일(삭제)도
    // 그 파일에 의존하던 라이브러리를 무효화해야 하므로 캐시 전체를 본다.
    // 사실 본문 파싱은 폐쇄가 정해진 뒤 재사용할 파일에만 한다 — 폐쇄에 걸려
    // 다시 해석될 파일의 사실을 미리 파싱하던 낭비를 없앤다.
    final reverseImports = <String, Set<String>>{};
    final cachedLibraries = <String, String>{};
    for (final entry in cached.entries) {
      final library = entry.value.facts['librarySource'];
      if (library is! String) continue;
      cachedLibraries[entry.key] = library;
      final dependencies = entry.value.facts['dependencies'];
      if (dependencies is! List) continue;
      for (final dependency in dependencies) {
        if (dependency is String) {
          reverseImports.putIfAbsent(dependency, () => <String>{}).add(library);
        }
      }
    }
    // 1단계 — 캐시 키가 어긋난 파일(변경·신규)을 고른다. 재사용 후보의 사실
    // 파싱은 폐쇄를 아는 3단계까지 미룬다.
    final facts = <String, _UnitFacts>{};
    final resolved = <String>{};
    final reusedCandidates = <String>{};
    for (final path in unitPaths) {
      final source = sourcesOf[path];
      if (source == null) continue;
      final entry = cached[source];
      if (entry == null || entry.key != currentKeys[source]) {
        resolved.add(source);
      } else {
        reusedCandidates.add(source);
      }
    }
    // 2단계 — 바뀐 파일을 해석한다. 신규 파일의 라이브러리 소스도 이때 확보된다.
    for (final path in unitPaths) {
      final source = sourcesOf[path];
      if (source == null || !resolved.contains(source)) continue;
      final extracted = await _resolveUnitFacts(
        root: root,
        collection: collection,
        path: path,
        entryPoints: entryPoints,
        entryLibraryPath: entryLibraryPath,
      );
      if (extracted != null) facts[extracted.source] = extracted;
    }
    final currentSources = sourcesOf.values.toSet();
    final seeds = <String>{
      for (final source in resolved) ?facts[source]?.librarySource,
    };
    final removed = <String>[
      for (final entry in cachedLibraries.entries)
        if (!currentSources.contains(entry.key)) entry.value,
    ];
    final staleLibraries = IncrementalCache.reverseClosure([
      ...seeds,
      // 캐시에만 있는 파일이 사라진 경우다. 그 파일의 라이브러리를 다시 해석해야
      // 한다 — part 하나가 지워지면 라이브러리 전체의 선언 집합이 바뀐다.
      ...removed,
    ], reverseImports);
    // 3단계 — 폐쇄에 걸린 후보는 다시 해석하고, 남은 후보만 캐시 사실을
    // 파싱한다. 파싱이 실패한 항목은 그 파일만 다시 해석한다(손상 복구).
    for (final path in unitPaths) {
      final source = sourcesOf[path];
      if (source == null || resolved.contains(source)) continue;
      final library = cachedLibraries[source];
      if (library != null && staleLibraries.contains(library)) {
        final extracted = await _resolveUnitFacts(
          root: root,
          collection: collection,
          path: path,
          entryPoints: entryPoints,
          entryLibraryPath: entryLibraryPath,
        );
        if (extracted == null) continue;
        facts[extracted.source] = extracted;
        resolved.add(source);
        continue;
      }
      final parsed = _UnitFacts.fromJson(cached[source]!.facts);
      if (parsed != null) {
        facts[source] = parsed;
        continue;
      }
      final extracted = await _resolveUnitFacts(
        root: root,
        collection: collection,
        path: path,
        entryPoints: entryPoints,
        entryLibraryPath: entryLibraryPath,
      );
      if (extracted != null) {
        facts[extracted.source] = extracted;
        resolved.add(source);
      }
    }
    final sources = <String>[
      for (final path in unitPaths) ?facts[sourcesOf[path]]?.source,
    ];
    var result = _assembleResult(
      root: root,
      sources: sources,
      facts: facts,
      entryPoints: entryPoints,
      pubspecContent: pubspecContent,
    );
    incremental.stats
      ..resolvedFiles = resolved.length
      ..reusedFiles = sources.length - resolved.length;
    // 캐시가 이미 현재 입력과 정확히 일치하면(전부 재사용, 추가·삭제 없음)
    // 다시 쓰지 않는다. 디스크의 캐시가 곧 이번 실행이 쓸 내용이다. 다시 쓰면
    // 3.5MB 인코딩·원자적 교체를 매 실행 지불한다(600파일 기준 41ms).
    final cacheIsCurrent =
        resolved.isEmpty &&
        cached.length == currentSources.length &&
        currentSources.every(cached.containsKey);
    if (cacheIsCurrent) return result;
    final inputsUnchanged = await _incrementalInputsUnchanged(
      root,
      resolved,
      inputs,
    );
    if (!inputsUnchanged) {
      // 해석 중 입력이 바뀌었으면 낡은 키로 사실을 저장하지 않는다(기존 전체
      // 결과 캐시가 쓰기 전에 키를 다시 확인하는 것과 같은 이유).
      incremental.stats.cacheNotUpdated = true;
      return result;
    }
    final written = await incremental.store({
      for (final source in sources)
        source: CachedFacts(
          key: currentKeys[source]!,
          facts: facts[source]!.toJson(),
        ),
    });
    if (!written) {
      incremental.stats.cacheNotUpdated = true;
      result = AnalyzerGraphResult(
        graph: result.graph,
        limitations: result.limitations,
        limitationDetails: [
          ...result.limitationDetails,
          _cacheWriteFailureDetail,
        ],
        retentionRoots: result.retentionRoots,
        packageName: result.packageName,
        declaredDependencies: result.declaredDependencies,
        declaredDevDependencies: result.declaredDevDependencies,
        declaredDependencyOverrides: result.declaredDependencyOverrides,
        packageImports: result.packageImports,
      );
    }
    return result;
  }
}

/// 사실 캐시를 갱신하지 못했다는 limitation 문구다.
///
/// 디렉터리 경로를 넣지 않는다 — 출력에 사용자 경로를 반향하지 않는다는 기존
/// 경계를 따른다. 분석 결과 자체는 완전하다.
const _cacheWriteFailureDetail =
    'incremental-cache-write-failed: analysis is complete but the fact cache '
    'was not updated';

/// [path]를 루트 기준 posix 상대 경로로 바꾼다. 루트 밖이면 null이다.
String? _relativeSourcePath(String path, String root) {
  final absolute = p.normalize(p.absolute(path));
  final base = p.normalize(p.absolute(root));
  if (!isPathWithinRoot(absolute, base)) return null;
  return p.posix.joinAll(p.relative(absolute, from: base).split(p.separator));
}

/// 루트의 pubspec 내용이다. 없으면 null이다(공개 API·플러그인 루트 없음).
String? _readPubspec(String root) {
  final file = File(p.join(root, 'pubspec.yaml'));
  return file.existsSync() ? readConfigurationSync(file) : null;
}

/// 대표 라이브러리(`lib/<패키지 이름>.dart`)의 루트 기준 상대 경로다.
///
/// pubspec이 없으면 null이다. 이름이 없거나 패키지 이름 규칙을 어기면
/// [FormatException]이다 — 기존 `_addPublicApiRoots`와 같은 계약(종료 코드 2)을
/// 유지해야 하고, 증분 경로도 해석 전에 같은 시점에 실패해야 캐시가 그 실패를
/// 가리지 않는다.
String? _entryLibraryPath(String root, String? pubspecContent) {
  if (pubspecContent == null) return null;
  final document = loadYaml(pubspecContent);
  final packageName = document is YamlMap ? document['name'] : null;
  if (packageName is! String ||
      !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(packageName)) {
    throw const FormatException('pubspec name must be a valid package name');
  }
  return _relativeSourcePath(p.join(root, 'lib', '$packageName.dart'), root);
}

/// resolved unit 하나에서 그 파일에 국한된 사실을 뽑는다.
///
/// 사실 하나하나가 그 파일의 내용과 그 파일이 의존하는 입력(import/export/part
/// 대상·SDK·설정·도구 버전)의 함수다. 그래서 키가 바뀐 파일과 그 파일을
/// import/export하는 폐쇄만 다시 해석하면 나머지는 재사용할 수 있다
/// (`doc/DECISION-incremental.md` 2·4절).
///
/// 해석되지 않은 대상은 null이다(기존 경로와 같이 그 파일을 그래프에서 뺀다).
Future<_UnitFacts?> _resolveUnitFacts({
  required String root,
  required AnalysisContextCollection collection,
  required String path,
  required Set<String>? entryPoints,
  required String? entryLibraryPath,
}) async {
  final resolved = await _contextIncluding(
    collection,
    path,
  ).currentSession.getResolvedUnit(path);
  if (resolved is! ResolvedUnitResult) return null;
  final source = _relativeSourcePath(path, root);
  if (source == null) return null;
  final library = resolved.libraryElement;
  final nodes = CodeGraph();
  final roots = <String, RetentionReason>{};
  final mainEntrySources = <String>{};
  resolved.unit.accept(
    _DeclarationCollector(nodes, root, roots, entryPoints, mainEntrySources),
  );
  final edges = <GraphEdge>[];
  resolved.unit.accept(_RelationshipCollector(edges, root));
  final routeTables = <String>{};
  final routeUses = <String>[];
  resolved.unit.accept(_RouteCollector(routeTables, routeUses));
  final unresolved = _UnresolvedInvocationVisitor();
  resolved.unit.accept(unresolved);
  return _UnitFacts(
    source: source,
    libraryId: _libraryId(library.uri, root),
    nodes: nodes.snapshot().nodes,
    edges: edges,
    roots: roots,
    mainEntry: mainEntrySources.isNotEmpty,
    hasErrors: resolved.diagnostics.any(
      (error) => error.diagnosticCode.severity.name == 'ERROR',
    ),
    hasUnresolvedInvocations: unresolved.found,
    conditionalDirectives: resolved.unit.directives
        .where(
          (directive) => switch (directive) {
            ImportDirective() => directive.configurations.isNotEmpty,
            ExportDirective() => directive.configurations.isNotEmpty,
            _ => false,
          },
        )
        .length,
    routeTables: routeTables.toList(),
    routeUses: routeUses,
    dependencies: _libraryDependencies(root, library, resolved).toList()
      ..sort(),
    packageReferences: _packageReferences(resolved.unit),
    libraryFacts: _libraryFacts(root, library, entryLibraryPath),
    librarySource: _relativeSourcePath(
      library.firstFragment.source.fullName,
      root,
    ),
  );
}

/// 라이브러리가 의존하는 라이브러리의 **소스 경로** 집합이다.
///
/// 노드 ID는 package URI일 수 있어(패키지 설정 아래 해석된 라이브러리) 무효화
/// 단위로 쓰기에 부적합하다. 여기서는 `lib/` 기준 상대 경로로 통일해, 파일이
/// 바뀌었다는 사실과 라이브러리 의존 관계를 같은 이름 공간에서 비교한다.
///
/// 해석에 성공한 import/export와, 파일이 **선언한** 상대 경로 지시문(미해결
/// 포함), 라이브러리의 part를 함께 센다. 미해결 지시문을 세지 않으면 대상이
/// 나중에 생기거나 고쳐질 때 그 파일을 참조하는 쪽이 낡은 사실을 재사용한다 —
/// 지시문 문자열을 같은 규칙으로 정규화해 두면 파일이 나타나는 순간 역방향
/// 폐쇄가 참조하는 쪽을 무효화한다.
///
/// 루트 밖 대상(의존 패키지)은 세지 않는다. 그 내용은 설정 지문이 덮는다.
Set<String> _libraryDependencies(
  String root,
  LibraryElement library,
  ResolvedUnitResult unit,
) {
  final dependencies = <String>{};
  void addSource(String? fullName) {
    if (fullName == null) return;
    final path = _relativeSourcePath(fullName, root);
    if (path != null) dependencies.add(path);
  }

  for (final import in library.firstFragment.libraryImports) {
    addSource(import.importedLibrary?.firstFragment.source.fullName);
  }
  for (final export in library.firstFragment.libraryExports) {
    addSource(export.exportedLibrary?.firstFragment.source.fullName);
  }
  final host = _relativeSourcePath(library.firstFragment.source.fullName, root);
  for (final directive in unit.unit.directives) {
    if (directive is! UriBasedDirective) continue;
    final declared = directive.uri.stringValue;
    if (declared == null || declared.isEmpty) continue;
    final uri = Uri.tryParse(declared);
    if (uri == null || uri.scheme.isNotEmpty || uri.path.isEmpty) continue;
    final source = _relativeSourcePath(
      p.joinAll([p.dirname(unit.path), ...uri.path.split('/')]),
      root,
    );
    if (source == null || source == host) continue;
    dependencies.add(source);
  }
  // part는 라이브러리 경계 안의 의존이다. part 하나가 바뀌면 라이브러리 전체
  // (호스트와 나머지 part)를 다시 해석해야 한다.
  for (final fragment in library.fragments) {
    addSource(fragment.source.fullName);
  }
  if (host != null) dependencies.add(host);
  return dependencies;
}

/// 유닛의 import/export 지시문이 선언한 `package:` 이름 집합이다(정렬).
///
/// 지시문 문자열(`uri.stringValue`)을 읽으므로 해석 성공 여부와 무관하게 잡힌다
/// — pubspec에 선언되지 않아 해석에 실패한 import도 deps 감사의 근거가 된다.
/// 조건부 지시문의 구성 URI도 센다(선택된 구성만 해석돼도 선언된 의존은 사실).
List<String> _packageReferences(CompilationUnit unit) {
  final names = <String>{};
  void addUri(String? declared) {
    if (declared == null || !declared.startsWith('package:')) return;
    final uri = Uri.tryParse(declared);
    if (uri == null || uri.pathSegments.isEmpty) return;
    names.add(uri.pathSegments.first);
  }

  for (final directive in unit.directives) {
    final List<Configuration> configurations;
    switch (directive) {
      case ImportDirective():
        addUri(directive.uri.stringValue);
        configurations = directive.configurations;
      case ExportDirective():
        addUri(directive.uri.stringValue);
        configurations = directive.configurations;
      default:
        continue;
    }
    for (final configuration in configurations) {
      addUri(configuration.uri.stringValue);
    }
  }
  return names.toList()..sort();
}

/// 라이브러리 수준 사실(간선 대상·공개 API 후보)을 뽑는다.
///
/// 같은 라이브러리의 모든 유닛이 같은 값을 얻는다 — 조립은 유닛 순서로 첫 항목을
/// 쓰므로 어느 유닛이 제공해도 결과가 같다(part만 있는 파일에서도 라이브러리
/// 간선을 잃지 않는다).
_LibraryFacts _libraryFacts(
  String root,
  LibraryElement library,
  String? entryLibraryPath,
) {
  final imports = <String>[];
  for (final import in library.firstFragment.libraryImports) {
    final target = _libraryId(import.importedLibrary?.uri, root);
    if (!imports.contains(target)) imports.add(target);
  }
  final exports = <String>[];
  for (final export in library.firstFragment.libraryExports) {
    final target = _libraryId(export.exportedLibrary?.uri, root);
    if (!exports.contains(target)) exports.add(target);
  }
  final publicApi = <String>[];
  final entry = entryLibraryPath;
  if (entry != null &&
      p.normalize(library.firstFragment.source.fullName) ==
          p.normalize(p.join(root, entry))) {
    final exported = library.exportNamespace.definedNames2.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final symbol in exported) {
      // 비공개 이름은 공개 API가 아니다. 정렬 순서(이름 사전순)를 그대로
      // 보존해 보존 루트 삽입 순서가 전체 해석과 같게 유지된다.
      if (symbol.key.startsWith('_')) continue;
      publicApi.add(
        _elementId(_graphTarget(symbol.value) ?? symbol.value, root),
      );
    }
  }
  return _LibraryFacts(
    imports: imports,
    exports: exports,
    publicApi: publicApi,
  );
}

/// 한 파일에서 뽑은 사실이다. 캐시에 저장되고 캐시에서 복원된다.
final class _UnitFacts {
  const _UnitFacts({
    required this.source,
    required this.librarySource,
    required this.libraryId,
    required this.nodes,
    required this.edges,
    required this.roots,
    required this.mainEntry,
    required this.hasErrors,
    required this.hasUnresolvedInvocations,
    required this.conditionalDirectives,
    required this.routeTables,
    required this.routeUses,
    required this.dependencies,
    required this.libraryFacts,
    required this.packageReferences,
  });

  /// 루트 기준 posix 상대 경로다(캐시 키).
  final String source;

  /// 이 유닛이 속한 라이브러리의 **소스 경로**다(part는 호스트 라이브러리).
  /// 루트 밖이면 null이고, 그때는 무효화 단위로 쓰지 않는다.
  final String? librarySource;

  /// 이 유닛이 속한 라이브러리 ID다(노드·간선 ID의 근거, package URI 가능).
  final String libraryId;

  /// 이 유닛이 선언한 정점이다(유닛 안에서 ID는 유일하다).
  final List<GraphNode> nodes;

  /// 이 유닛의 AST에서 나온 간선 후보다. 양끝 정점 존재 검사는 조립이 한다 —
  /// 전체 해석과 증분 해석이 같은 전역 정점 집합으로 같은 판정을 내린다.
  final List<GraphEdge> edges;

  /// 이 유닛이 정한 보존 사유다.
  final Map<String, RetentionReason> roots;

  /// 표준 디렉터리의 `main` 진입점을 이 유닛에서 관측했는지.
  final bool mainEntry;

  /// 분석 오류(ERROR 진단)가 있는지.
  final bool hasErrors;

  /// 미해석 호출이 있는지.
  final bool hasUnresolvedInvocations;

  /// 조건부 import/export 지시문 수.
  final int conditionalDirectives;

  /// 이 유닛이 관측한 route table 키와 named route 사용이다.
  final List<String> routeTables;
  final List<String> routeUses;

  /// 이 라이브러리가 의존하는 라이브러리의 소스 경로 집합이다.
  final List<String> dependencies;

  /// 라이브러리 수준 사실이다.
  final _LibraryFacts libraryFacts;

  /// 이 유닛의 import/export 지시문이 선언한 `package:` 이름이다(정렬).
  /// 지시문 문자열을 직접 읽으므로 미해결 import도 잡힌다 — 미선언 의존은
  /// 해석 결과가 아니라 선언 텍스트가 근거다.
  final List<String> packageReferences;

  /// `project:` source ID다.
  String get sourceId => 'project:$source';

  /// 캐시 저장 형식이다.
  Map<String, Object?> toJson() => {
    'conditional': conditionalDirectives,
    'dependencies': dependencies,
    'edges': [for (final edge in edges) _edgeJson(edge)],
    'errors': hasErrors,
    'library': libraryId,
    'libraryFacts': libraryFacts.toJson(),
    'librarySource': librarySource,
    'mainEntry': mainEntry,
    'nodes': [for (final node in nodes) _nodeJson(node)],
    'packageReferences': packageReferences,
    'roots': {for (final entry in roots.entries) entry.key: entry.value.name},
    'routes': routeTables,
    'routeUses': routeUses,
    'source': source,
    'unresolved': hasUnresolvedInvocations,
  };

  /// 캐시 항목을 복원한다. 형식이 어긋나면 null이고 호출자는 그 파일만 다시
  /// 해석한다 — 캐시 손상이 분석 실패가 되지 않는다.
  static _UnitFacts? fromJson(Object? value) {
    try {
      if (value is! Map) return null;
      final source = value['source'];
      final libraryId = value['library'];
      final nodes = value['nodes'];
      final edges = value['edges'];
      final roots = value['roots'];
      final libraryFacts = _LibraryFacts.fromJson(value['libraryFacts']);
      if (source is! String ||
          libraryId is! String ||
          nodes is! List ||
          edges is! List ||
          roots is! Map ||
          libraryFacts == null) {
        return null;
      }
      return _UnitFacts(
        source: source,
        librarySource: value['librarySource'] as String?,
        libraryId: libraryId,
        nodes: [
          for (final node in nodes) _nodeFromJson(node as Map<String, Object?>),
        ],
        edges: [
          for (final edge in edges) _edgeFromJson(edge as Map<String, Object?>),
        ],
        roots: {
          for (final entry in roots.entries)
            entry.key as String: RetentionReason.values.byName(
              entry.value as String,
            ),
        },
        mainEntry: value['mainEntry'] == true,
        hasErrors: value['errors'] == true,
        hasUnresolvedInvocations: value['unresolved'] == true,
        conditionalDirectives: value['conditional'] as int? ?? 0,
        routeTables: [
          for (final route in value['routes'] as List? ?? const [])
            route as String,
        ],
        routeUses: [
          for (final route in value['routeUses'] as List? ?? const [])
            route as String,
        ],
        dependencies: [
          for (final dependency in value['dependencies'] as List? ?? const [])
            dependency as String,
        ],
        packageReferences: [
          for (final name in value['packageReferences'] as List? ?? const [])
            name as String,
        ],
        libraryFacts: libraryFacts,
      );
    } on Object {
      return null;
    }
  }
}

/// 라이브러리 수준 사실이다. 같은 라이브러리의 모든 유닛이 같은 값을 가진다.
final class _LibraryFacts {
  const _LibraryFacts({
    required this.imports,
    required this.exports,
    required this.publicApi,
  });

  /// 라이브러리 ID로 정규화한 import 대상이다(선언 순서).
  final List<String> imports;

  /// 라이브러리 ID로 정규화한 export 대상이다(선언 순서).
  final List<String> exports;

  /// 대표 라이브러리가 공개하는 선언 ID다(이름 사전순, 비공개 제외).
  final List<String> publicApi;

  Map<String, Object?> toJson() => {
    'exports': exports,
    'imports': imports,
    'publicApi': publicApi,
  };

  static _LibraryFacts? fromJson(Object? value) {
    try {
      if (value is! Map) return null;
      final imports = value['imports'];
      final exports = value['exports'];
      final publicApi = value['publicApi'];
      if (imports is! List || exports is! List || publicApi is! List) {
        return null;
      }
      return _LibraryFacts(
        imports: [for (final item in imports) item as String],
        exports: [for (final item in exports) item as String],
        publicApi: [for (final item in publicApi) item as String],
      );
    } on Object {
      return null;
    }
  }
}

Map<String, Object?> _nodeJson(GraphNode node) => {
  'column': ?node.column,
  'id': node.id,
  'isAbstract': node.isAbstract,
  'isEnumConstant': node.isEnumConstant,
  'isLibrary': node.isLibrary,
  'isSealed': node.isSealed,
  'isTypeDeclaration': node.isTypeDeclaration,
  'line': ?node.line,
  'sourceUri': ?node.sourceUri,
  'synthesized': node.synthesized,
};

GraphNode _nodeFromJson(Map<String, Object?> node) => GraphNode(
  id: node['id']! as String,
  sourceUri: node['sourceUri'] as String?,
  line: node['line'] as int?,
  column: node['column'] as int?,
  synthesized: node['synthesized']! as bool,
  isLibrary: node['isLibrary']! as bool,
  isTypeDeclaration: node['isTypeDeclaration']! as bool,
  isAbstract: node['isAbstract']! as bool,
  isEnumConstant: node['isEnumConstant']! as bool,
  isSealed: node['isSealed']! as bool,
);

Map<String, Object?> _edgeJson(GraphEdge edge) => {
  'kind': edge.kind.name,
  'source': edge.sourceId,
  'target': edge.targetId,
};

GraphEdge _edgeFromJson(Map<String, Object?> edge) => GraphEdge(
  sourceId: edge['source']! as String,
  targetId: edge['target']! as String,
  kind: EdgeKind.values.byName(edge['kind']! as String),
);

/// 파일별 사실을 하나의 그래프로 조립한다.
///
/// 전체 해석과 증분 해석이 같은 함수를 지난다 — 사실이 같으면 산출물도 같다.
/// 순서가 의미를 갖는 지점(중복 정점의 첫 승리, 보존 사유의 마지막 승리,
/// 라이브러리·publicApi·plugin 루트의 putIfAbsent)은 원래 유닛 순서를 따른다.
AnalyzerGraphResult _assembleResult({
  required String root,
  required List<String> sources,
  required Map<String, _UnitFacts> facts,
  required Set<String>? entryPoints,
  required String? pubspecContent,
}) {
  final graph = CodeGraph();
  final retentionRoots = <String, RetentionReason>{};
  final mainEntrySources = <String>{};
  final libraries = <String, _LibraryFacts>{};
  for (final source in sources) {
    final unit = facts[source]!;
    if (!graph.containsNode(unit.libraryId)) {
      graph.addNode(GraphNode(id: unit.libraryId, isLibrary: true));
    }
    for (final node in unit.nodes) {
      if (!graph.containsNode(node.id)) graph.addNode(node);
    }
    retentionRoots.addAll(unit.roots);
    if (unit.mainEntry) mainEntrySources.add(unit.sourceId);
    libraries.putIfAbsent(unit.libraryId, () => unit.libraryFacts);
  }
  final libraryIds = libraries.keys.toList()..sort();
  for (final libraryId in libraryIds) {
    final library = libraries[libraryId]!;
    for (final target in library.imports) {
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
    for (final target in library.exports) {
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
  // 대표 라이브러리 판정은 소스 경로로 한다(노드 ID는 package URI일 수 있다).
  // 후보가 있는 라이브러리는 대표 라이브러리 하나뿐이라 순서는 유닛 순서를 따른다.
  for (final library in libraries.values) {
    _addPublicApiRoots(graph, retentionRoots, library.publicApi);
  }
  for (final source in sources) {
    for (final edge in facts[source]!.edges) {
      if (edge.sourceId != edge.targetId &&
          graph.containsNode(edge.sourceId) &&
          graph.containsNode(edge.targetId)) {
        graph.addEdge(edge);
      }
    }
  }
  final limitations = <AnalyzerLimitation>{
    ..._addPluginRoots(root, graph, retentionRoots, pubspecContent),
  };
  if (sources.any((source) => facts[source]!.conditionalDirectives > 0)) {
    limitations.add(AnalyzerLimitation.conditionalConfiguration);
  }
  if (retentionRoots.values.contains(RetentionReason.generatedCode)) {
    limitations.add(AnalyzerLimitation.generatedCodeRetention);
  }
  if (retentionRoots.values.contains(RetentionReason.visibleForTesting)) {
    limitations.add(AnalyzerLimitation.testCodeRetention);
  }
  final limitationDetails = _agentLimitations(root, sources, facts);
  // build.yaml이 선언한 builder factory는 build_runner가 이름으로 호출하는
  // 진입점이라 사용 간선이 없어도 보존한다(undead의 framework adapter와 같은
  // 계약). 파싱 실패는 한계로 남기고 분석 실패로 만들지 않는다.
  if (!_addBuildRunnerRoots(
    root,
    graph,
    retentionRoots,
    pubspecContent,
    limitationDetails,
  )) {
    limitationDetails.add(
      'build-yaml-unparsed: builder entry points could not be read',
    );
  }
  final manifest = _manifestFacts(pubspecContent);
  final packageImports = <String, List<String>>{};
  for (final source in sources) {
    final unit = facts[source]!;
    for (final name in unit.packageReferences) {
      packageImports.putIfAbsent(name, () => []).add(unit.sourceId);
    }
  }
  if (entryPoints != null) {
    // 설정이 보존 루트를 좁혔다는 사실 자체를 출력에 남긴다. 없으면 PR로
    // 추가된 dartograph.yaml이 죽은 코드를 조용히 숨겨도 클린 저장소와
    // 출력상 구별되지 않는다(감사 S5).
    limitationDetails.add(
      'entry-points: main retention roots narrowed to ${entryPoints.length} '
      'declared build target(s)',
    );
    final missing = entryPoints.difference(mainEntrySources).toList()..sort();
    for (final source in missing) {
      limitationDetails.add(
        'configured-entry-point-without-main: ${source.substring('project:'.length)}',
      );
    }
  }
  return AnalyzerGraphResult(
    graph: graph,
    limitations: limitations.toList()..sort((a, b) => a.index - b.index),
    limitationDetails: limitationDetails,
    retentionRoots: Map.unmodifiable(retentionRoots),
    packageName: manifest.name,
    declaredDependencies: manifest.dependencies,
    declaredDevDependencies: manifest.devDependencies,
    declaredDependencyOverrides: manifest.dependencyOverrides,
    packageImports: Map.unmodifiable(packageImports),
  );
}

/// pubspec에서 deps 감사가 쓰는 매니페스트 사실이다.
///
/// 이름·의존 섹션 키만 읽는다 — 버전 제약·sdk 조건은 선언 사실이 아니므로
/// 건드리지 않는다. 섹션 값이 map이 아니면 그 섹션을 비어 있는 것으로 둔다
/// (잘못된 형태의 pubspec은 analyzer가 이미 진단한다).
({
  String? name,
  List<String> dependencies,
  List<String> devDependencies,
  List<String> dependencyOverrides,
})
_manifestFacts(String? pubspecContent) {
  if (pubspecContent == null) {
    return (
      name: null,
      dependencies: const [],
      devDependencies: const [],
      dependencyOverrides: const [],
    );
  }
  final document = loadYaml(pubspecContent);
  List<String> keysOf(Object? section) {
    if (section is! YamlMap) return const [];
    return [for (final key in section.keys) '$key']..sort();
  }

  return (
    name: document is YamlMap && document['name'] is String
        ? document['name'] as String
        : null,
    dependencies: keysOf(document is YamlMap ? document['dependencies'] : null),
    devDependencies: keysOf(
      document is YamlMap ? document['dev_dependencies'] : null,
    ),
    dependencyOverrides: keysOf(
      document is YamlMap ? document['dependency_overrides'] : null,
    ),
  );
}

/// `build.yaml`의 builder factory를 보존 루트로 삼는다. 읽을 수 있으면 true다.
///
/// `builders.*.builder_factories`(목록)와 `post_process_builders.*.
/// builder_factory`(단수)의 이름을 `import:`가 가리키는 라이브러리의 선언으로
/// 해석한다. `package:` URI는 그대로 쓰고 상대 경로는 이 패키지의 `lib/`
/// 라이브러리로 해석한다 — 두 형태가 그래프 노드 ID와 일치해야 매치된다.
/// build.yaml이 없으면 아무것도 하지 않는다(플러그인이 아닌 패키지의 정상
/// 상태이며 한계가 아니다).
bool _addBuildRunnerRoots(
  String root,
  CodeGraph graph,
  Map<String, RetentionReason> roots,
  String? pubspecContent,
  List<String> limitationDetails,
) {
  final file = File(p.join(root, 'build.yaml'));
  if (!file.existsSync()) return true;
  final Object? document;
  try {
    document = loadYaml(readConfigurationSync(file));
  } on Object {
    return false;
  }
  if (document is! YamlMap) return true;
  final name = pubspecContent == null
      ? null
      : switch (loadYaml(pubspecContent)) {
          YamlMap map when map['name'] is String => map['name'] as String,
          _ => null,
        };
  void addFactory(String? libraryId, String factory) {
    if (libraryId == null || factory.isEmpty) return;
    final id = '$libraryId::$factory';
    if (graph.containsNode(id)) {
      roots.putIfAbsent(id, () => RetentionReason.buildRunner);
      return;
    }
    limitationDetails.add(
      'build-yaml-builder-unresolved: $id was declared but not found',
    );
  }

  String? libraryIdOf(Object? import) {
    if (import is! String || import.isEmpty) return null;
    if (import.startsWith('package:')) return import;
    // `lib/…` 상대 경로는 이 패키지의 라이브러리 ID로 해석한다.
    final normalized = import.startsWith('./') ? import.substring(2) : import;
    if (!normalized.startsWith('lib/') || name == null) return null;
    return 'package:$name/${normalized.substring('lib/'.length)}';
  }

  void addEntries(Object? section, {required bool listValue}) {
    if (section is! YamlMap) return;
    for (final entry in section.entries) {
      final value = entry.value;
      if (value is! YamlMap) continue;
      // 컬렉션 리터럴의 if-else는 else가 안쪽 if에 붙어 목록·단일 분기가
      // 어긋난다 — 명령형으로 분리한다.
      final rawFactories = listValue
          ? value['builder_factories']
          : value['builder_factory'];
      final factories = <String>[
        if (rawFactories is YamlList)
          ...rawFactories.whereType<String>()
        else if (rawFactories is String)
          rawFactories,
      ];
      if (factories.isEmpty) continue;
      final libraryId = libraryIdOf(value['import']);
      if (libraryId == null) {
        // import를 해석하지 못했는데 factory가 선언돼 있으면 조용히 넘기지
        // 않는다 — 실제로 보존되지 않은 빌더 루트는 한계로 남긴다.
        final rawImport = value['import'];
        limitationDetails.add(
          'build-yaml-import-unresolved: ${entry.key} declares builder '
          'factories but its import (${rawImport ?? 'missing'}) could not '
          'be interpreted',
        );
        continue;
      }
      for (final factory in factories) {
        addFactory(libraryId, factory);
      }
    }
  }

  addEntries(document['builders'], listValue: true);
  addEntries(document['post_process_builders'], listValue: false);
  return true;
}

/// 증분 실행이 쓰는 입력 해시를 한 번의 파일 순회로 모은다.
///
/// 단위 파일은 파일별 키의 내용 부분이 되고, 나머지 분석 입력(설정 파일·package
/// config·의존 패키지 `lib`·표준 디렉터리 밖 `.dart`)은 설정 지문이 된다. 단위
/// 파일을 지문에 넣으면 파일 하나만 바뀌어도 전체가 무효화되므로 뺀다.
Future<({Map<String, String> unitHashes, String configFingerprint})>
_incrementalInputs(String root, Set<String> unitSources) async {
  final unitHashes = <String, String>{};
  final inputs = <String>[];
  for (final file in await _analysisInputFiles(root)) {
    final relative = p.posix.joinAll(
      p.relative(file.path, from: root).split(p.separator),
    );
    final digest = fileContentHash(file);
    if (unitSources.contains(relative)) {
      unitHashes[relative] = digest;
      continue;
    }
    inputs.add('$relative\u0000$digest');
  }
  for (final source in unitSources) {
    if (unitHashes.containsKey(source)) continue;
    // 방어: 분석 입력 열거에 없는 분석 대상(경계 밖 링크 등)도 키를 갖는다.
    final file = File(p.join(root, source));
    if (!file.existsSync()) continue;
    unitHashes[source] = fileContentHash(file);
  }
  final fingerprint = sha256
      .convert(
        utf8.encode('$_cacheIdentity\u0000${inputs.join('\u0000')}\u0000'),
      )
      .toString();
  return (unitHashes: unitHashes, configFingerprint: fingerprint);
}

/// 해석한 파일의 내용이 해석 중에 바뀌지 않았는지 확인한다.
///
/// 바뀌었으면 이번 사실은 이미 낡은 키에 묶여 있으므로 캐시를 갱신하지 않는다
/// (전체 결과 캐시가 쓰기 전에 키를 다시 확인하는 것과 같은 경계다). 다시 읽는
/// 비용은 이번 실행이 이미 해석한 파일 수에 비례한다.
Future<bool> _incrementalInputsUnchanged(
  String root,
  Set<String> resolvedSources,
  ({Map<String, String> unitHashes, String configFingerprint}) inputs,
) async {
  for (final source in resolvedSources) {
    final before = inputs.unitHashes[source];
    if (before == null) return false;
    final file = File(p.join(root, source));
    if (!file.existsSync()) return false;
    if (fileContentHash(file) != before) return false;
  }
  return true;
}

/// [rootPath] 아래 표준 소스 디렉터리의 resolved unit을 결정적 순서로 돌려준다.
///
/// 그래프가 아닌 다른 analyzer 사실(예: 런타임 의존성)을 읽는 모듈이 쓴다. 같은
/// 파일 열거·SDK 탐색·컨텍스트 선택 규칙을 공유해, 그래프와 다른 사실이 서로
/// 다른 파일 집합을 보지 않게 한다. 그래프 캐시는 그래프 전용이므로 여기서는
/// 읽지도 쓰지도 않는다 — 캐시를 재사용하면 런타임 사실이 낡은 해석을 보게 된다.
Future<List<ResolvedUnitResult>> resolveProjectUnits(String rootPath) async {
  final root = Directory(rootPath).absolute.resolveSymbolicLinksSync();
  final sourcePackages = _readSourcePackages(root);
  final collection = AnalysisContextCollection(
    includedPaths: [root],
    sdkPath: _dartSdkPath(),
  );
  try {
    final units = <ResolvedUnitResult>[];
    for (final path in _dartFilesUnder(root, collection, sourcePackages)) {
      final result = await _contextIncluding(
        collection,
        path,
      ).currentSession.getResolvedUnit(path);
      if (result is ResolvedUnitResult) units.add(result);
    }
    return units;
  } finally {
    await collection.dispose();
  }
}

// 노드 직렬화에 isEnumConstant를 추가해 스키마를 v2로 올렸다. 옛 캐시는 decode에서
// schemaVersion 불일치로 거부되어 재분석됐으므로 그때는 identity를 올리지 않았다.
// 노드 직렬화에 isLibrary를 추가할 때도 같다(v3). isSealed와 deps 감사 필드
// (packageImports·manifest) 추가로 v4가 됐다 — 추출 의미 변화 없이 필드만 늘었다.
const _cacheSchemaVersion = 4;
// 연산자 호출 usage 간선(v4)과 dartograph:ignore 주석 보존 루트(v5) 추가로
// 추출 의미가 바뀌어 identity를 올렸다. 당시 직렬화 형식은 그대로라 schemaVersion은
// 올리지 않았다. packageReferences 지시문 수집(v7 — 미해결·조건부 URI까지
// deps 감사 입력으로 쓰는 새 추출)과 build.yaml·인터롭 annotation 보존 루트로
// 추출 의미가 바뀌어 다시 올린다. @anonymous 인식과 build.yaml 미해석 import
// 한계 기록(v8)으로 다시 올린다.
const _cacheIdentity =
    'dartograph-analysis-$toolVersion-cache-v8-anonymous-binding-import-gaps';

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
  // analyzer는 import 클로저로 표준 5디렉터리(_sourceDirectories) 밖의 루트 안
  // .dart(tool/·루트 스크립트 등)도 읽는다. 해석 오류·미해석 호출 limitation은
  // 표준 디렉터리 파일에 붙지만 그 원인이 밖의 파일일 수 있으므로, 키가 표준
  // 디렉터리만 열거하면 그 파일 변경 후 낡은 해석 결과가 재사용된다(stale hit
  // 실측 확인). 루트 전체를 열거해 해석 클로저를 보수적으로 커버한다.
  // 숨김 디렉터리는 가지치기한다: `.fvm`처럼 Flutter SDK 전체로 향하는 링크를
  // 따라가면 키 계산마다 수천 파일을 해싱한다. analyzer의 컨텍스트 루트도
  // 숨김 디렉터리는 분석 대상으로 열거하지 않으므로, 잔여 공백은 "숨김
  // 디렉터리 안 파일을 보이는 파일이 import하는" 병적 배치뿐이다. 루트 밖
  // 상대 경로 import(모노레포 공유 디렉터리)는 값싸고 안전하게 열거할 방법이
  // 없어 커버하지 않는다 — 루트 경계가 이 보수의 한계다.
  // 중첩 패키지 탐지도 이 순회 하나로 표준 디렉터리 밖(tool/pkg 등)까지 넓힌다.
  for (final file in _projectFiles(
    Directory(root),
    skipHiddenDirectories: true,
  )) {
    final base = p.basename(file.path);
    if (file.path.endsWith('.dart') || base == 'analysis_options.yaml') {
      addFile(file);
    } else if (base == 'pubspec.yaml') {
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
    'declaredDependencies': result.declaredDependencies,
    'declaredDependencyOverrides': result.declaredDependencyOverrides,
    'declaredDevDependencies': result.declaredDevDependencies,
    'edges': [for (final edge in snapshot.edges) _edgeJson(edge)],
    'limitationDetails': result.limitationDetails,
    'limitations': result.limitations.map((item) => item.name).toList(),
    'nodes': [for (final node in snapshot.nodes) _nodeJson(node)],
    'packageImports': result.packageImports,
    'packageName': ?result.packageName,
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
      graph.addNode(_nodeFromJson((value! as Map).cast<String, Object?>()));
    }
    for (final value in document['edges']! as List<Object?>) {
      graph.addEdge(_edgeFromJson((value! as Map).cast<String, Object?>()));
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
      packageName: document['packageName'] as String?,
      declaredDependencies: [
        for (final name in document['declaredDependencies']! as List<Object?>)
          name! as String,
      ],
      declaredDevDependencies: [
        for (final name
            in document['declaredDevDependencies']! as List<Object?>)
          name! as String,
      ],
      declaredDependencyOverrides: [
        for (final name
            in document['declaredDependencyOverrides']! as List<Object?>)
          name! as String,
      ],
      packageImports: {
        for (final entry
            in (document['packageImports']! as Map)
                .cast<String, Object?>()
                .entries)
          entry.key: [
            for (final source in entry.value! as List<Object?>)
              source! as String,
          ],
      },
    );
  } on Object {
    return null;
  }
}

List<String> _agentLimitations(
  String root,
  List<String> sources,
  Map<String, _UnitFacts> facts,
) {
  final sourceGaps = <String>{};
  var conditionalCount = 0;
  final routeTables = <String>{};
  final routeUses = <String>[];
  for (final source in sources) {
    final unit = facts[source]!;
    if (unit.hasErrors) {
      sourceGaps.add('source-analysis-errors: ${unit.sourceId}');
    }
    if (unit.hasUnresolvedInvocations) {
      sourceGaps.add('source-unresolved-invocations: ${unit.sourceId}');
    }
    if (unit.conditionalDirectives > 0) {
      sourceGaps.add('source-conditional-configuration: ${unit.sourceId}');
    }
    conditionalCount += unit.conditionalDirectives;
    routeTables.addAll(unit.routeTables);
    routeUses.addAll(unit.routeUses);
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
      final suffix = _generatedSiblingPattern.firstMatch(entity.path);
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

Iterable<File> _projectFiles(
  Directory directory, {
  bool skipHiddenDirectories = false,
}) => _projectFilesIn(
  directory,
  <String>{},
  skipHiddenDirectories: skipHiddenDirectories,
);

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
  Set<String> visitedLinkTargets, {
  bool skipHiddenDirectories = false,
}) sync* {
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is Directory) {
      if (_isSkippedDirectory(entity.path, skipHiddenDirectories)) {
        continue;
      }
      yield* _projectFilesIn(
        entity,
        visitedLinkTargets,
        skipHiddenDirectories: skipHiddenDirectories,
      );
    } else if (entity is File) {
      yield entity;
    } else if (entity is Link) {
      // typeSync는 링크를 따라가므로 끊어진 링크는 notFound가 되어 제외된다.
      final type = FileSystemEntity.typeSync(entity.path);
      if (type == FileSystemEntityType.file) {
        yield File(entity.path);
      } else if (type == FileSystemEntityType.directory &&
          !_isSkippedDirectory(entity.path, skipHiddenDirectories)) {
        final target = _resolvedLinkTarget(entity);
        if (target != null && visitedLinkTargets.add(target)) {
          yield* _projectFilesIn(
            Directory(entity.path),
            visitedLinkTargets,
            skipHiddenDirectories: skipHiddenDirectories,
          );
        }
      }
    }
  }
}

bool _isSkippedDirectory(String path, bool skipHiddenDirectories) {
  final name = p.basename(path);
  return _ignoredProjectDirectories.contains(name) ||
      (skipHiddenDirectories && name.startsWith('.'));
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
      // 같은 fullName·source 계산을 선언마다 두 번 하지 않는다(감사 P10).
      final fullName = element.firstFragment.libraryFragment!.source.fullName;
      final source = _sourcePathId(fullName, root);
      if (!graph.containsNode(id)) {
        graph.addNode(
          GraphNode(
            id: id,
            sourceUri: source,
            line: location.lineNumber,
            column: location.columnNumber,
            synthesized: _isGenerated(fullName),
            isTypeDeclaration: element is InterfaceElement,
            isAbstract:
                (element is ClassElement && element.isAbstract) ||
                element is MixinElement,
            isEnumConstant: element is FieldElement && element.isEnumConstant,
            isSealed: element is ClassElement && element.isSealed,
          ),
        );
      }
      final reason = _retentionReason(
        node,
        element,
        source,
        entryPoints,
        mainEntrySources,
      );
      if (reason != null) retentionRoots[id] = reason;
      // 사용자의 명시적 억제 지시(인라인 주석)가 다른 보존 이유를 덮는다.
      // _retentionReason은 항상 평가해 main 진입점 source 관측
      // (mainEntrySources)이 건너뛰어지지 않게 한다.
      if (_hasIgnoreClaim(node, _ignoreClaimsFor(unit))) {
        retentionRoots[id] = RetentionReason.inlineIgnore;
      }
    }
    super.visitDeclaration(node);
  }

  Set<int> _ignoreClaimsFor(CompilationUnit unit) =>
      _ignoreClaims.putIfAbsent(unit, () => _collectIgnoreClaims(unit));

  /// `// dartograph:ignore` 주석이 부착되는 선언 claim 토큰의 offset을 모은다.
  ///
  /// 주석은 다음 실 토큰의 precedingComments 사슬에 붙는다(14.3.0 실측 계약).
  /// 같은 줄 꼬리 주석은 다음 선언의 억제가 아니다 — 이전 실 토큰의 끝 줄보다
  /// 아래 줄에서 시작하는 주석만 지시문이다(`void a() {} // dartograph:ignore`가
  /// b를 억제하지 않는다). 선언 claim이 아닌 토큰(클래스 `{`·지시문·EOF 등)에
  /// 붙은 주석은 [_hasIgnoreClaim]의 offset 대조에서 자연스럽게 버려진다.
  static Set<int> _collectIgnoreClaims(CompilationUnit unit) {
    final lineInfo = unit.lineInfo;
    final claims = <int>{};
    Token? token = unit.beginToken;
    while (token != null && token.type != TokenType.EOF) {
      var comment = token.precedingComments;
      while (comment != null) {
        if (_isIgnoreDirective(comment.lexeme)) {
          // 파일 첫 토큰의 previous는 EOF 센티널(14.3.0 실측 offset -1)이라
          // 이전 토큰 없음과 같이 취급한다. isEof와 offset을 함께 본다.
          final previous = token.previous;
          final leading =
              previous == null ||
              previous.isEof ||
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

  /// 선언의 claim 토큰 offset들이 억제 주석과 매치되는지 확인한다.
  ///
  /// claim은 annotation `@`(metadata.first)·doc comment 뒤 키워드
  /// (firstTokenAfterCommentAndMetadata)·선언 시작(node.offset)이다. 변수·필드는
  /// fragment가 없어 VariableDeclaration이 노드를 만들고 마커는 감싸는
  /// FieldDeclaration·TopLevelVariableDeclaration의 타입 키워드에 붙으므로
  /// (14.3.0 실측) 감싼 선언의 claim도 대조한다 — `int a = 1, b = 2;`의 마커는
  /// 두 변수 모두에 적용된다.
  static bool _hasIgnoreClaim(Declaration node, Set<int> claims) {
    if (_declarationClaims(node, claims)) return true;
    if (node is VariableDeclaration) {
      final field = node.thisOrAncestorOfType<FieldDeclaration>();
      if (field != null && _declarationClaims(field, claims)) return true;
      final topLevel = node.thisOrAncestorOfType<TopLevelVariableDeclaration>();
      if (topLevel != null && _declarationClaims(topLevel, claims)) {
        return true;
      }
    }
    return false;
  }

  static bool _declarationClaims(Declaration node, Set<int> claims) =>
      claims.contains(node.offset) ||
      claims.contains(node.firstTokenAfterCommentAndMetadata.offset) ||
      (node.metadata.isNotEmpty && claims.contains(node.metadata.first.offset));
}

/// `dartograph:ignore`로 시작하는 줄 주석 지시문이다.
///
/// `//` 접두를 벗긴 본문이 마커로 **시작**해야 하므로 산문이 마커를 언급해도
/// 오해석되지 않는다. doc comment(`///`)와 블록 주석은 문서지 지시문이 아니다.
/// 마커 뒤에 단어 문자가 오면(`dartograph:ignorex`) 다른 토큰으로 본다.
final _ignoreDirective = RegExp(r'^dartograph:ignore(?![A-Za-z0-9_])');

/// 생성 파일의 sibling source를 짝짓는 접미 패턴이다. 파일마다 컴파일하지
/// 않게 상단에서 한 번 만든다.
final _generatedSiblingPattern = RegExp(r'\.(g|freezed|pb)\.dart$');

bool _isIgnoreDirective(String lexeme) {
  final text = lexeme.trim();
  if (!text.startsWith('//') || text.startsWith('///')) return false;
  return _ignoreDirective.hasMatch(text.substring(2).trim());
}

/// `entry_points`가 가리킬 수 있는 보존 루트 디렉터리다.
/// 이 밖의 `main`은 원래 mainEntryPoint 루트가 아니므로 설정으로 받지 않는다.
const _entryPointDirectories = {'bin', 'example', 'lib'};

/// 프로젝트 내부 local package의 `lib/`를 opt-in 분석 대상으로 검증한다.
/// 기본 분석 범위는 유지하며 명시한 package root만 연다. pubspec 없는 폴더나
/// symlink/cache 경계는 조용히 따라가지 않는다.
List<Directory> _readSourcePackages(String root) {
  final file = File(p.join(root, 'dartograph.yaml'));
  if (!file.existsSync()) return const [];
  final document = loadYaml(readConfigurationSync(file));
  if (document == null) return const [];
  if (document is! YamlMap) {
    throw const FormatException('dartograph.yaml must be a YAML mapping');
  }
  final raw = document['source_packages'];
  if (raw == null) return const [];
  if (raw is! YamlList || raw.isEmpty) {
    throw const FormatException(
      'source_packages must be a non-empty list of package roots',
    );
  }
  final packages = <Directory>[];
  final configuredPackages = _packageConfigRoots(root);
  final packageNames = <String>{};
  final packagePaths = <String>{};
  for (final value in raw) {
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException(
        'source_packages entries must be non-empty project-relative paths',
      );
    }
    final lexical = p.posix.normalize(
      value.replaceAll(r'\', p.posix.separator),
    );
    if (p.posix.isAbsolute(lexical) ||
        lexical == '..' ||
        lexical.startsWith('../')) {
      throw FormatException(
        'source_packages must be project-relative paths: $value',
      );
    }
    final segments = lexical.split('/');
    if (segments.any(
      (segment) =>
          segment.startsWith('.') ||
          _ignoredProjectDirectories.contains(segment),
    )) {
      throw FormatException(
        'source_packages cannot use generated or cache paths: $value',
      );
    }
    final directory = Directory(p.join(root, lexical));
    if (!directory.existsSync()) {
      throw FormatException('source_packages root does not exist: $value');
    }
    final absolute = p.normalize(directory.absolute.path);
    final canonical = p.normalize(directory.resolveSymbolicLinksSync());
    if (!isPathWithinRoot(canonical, root) || !p.equals(absolute, canonical)) {
      throw FormatException(
        'source_packages root must be a non-symlink path inside the project: $value',
      );
    }
    if (p.equals(absolute, p.normalize(root))) {
      throw FormatException(
        'source_packages root must be a nested package: $value',
      );
    }
    final pubspec = File(p.join(canonical, 'pubspec.yaml'));
    final lib = Directory(p.join(canonical, 'lib'));
    if (!pubspec.existsSync() || !lib.existsSync()) {
      throw FormatException(
        'source_packages root must contain pubspec.yaml and lib/: $value',
      );
    }
    final packageDocument = loadYaml(readConfigurationSync(pubspec));
    final name = packageDocument is YamlMap ? packageDocument['name'] : null;
    if (name is! String ||
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw FormatException('source_packages pubspec name is invalid: $value');
    }
    final configuredName = configuredPackages[canonical];
    if (configuredName != name) {
      throw FormatException(
        'source_packages root must be resolved in .dart_tool/package_config.json: $value',
      );
    }
    if (!packagePaths.add(canonical) || !packageNames.add(name)) {
      throw FormatException(
        'source_packages entries must identify unique packages: $value',
      );
    }
    packages.add(Directory(canonical));
  }
  return packages;
}

/// root package config가 제공하는 local package root와 package: 이름을 읽는다.
/// source_packages는 이 매핑이 있어야만 analyzer가 실제 package URI/element를
/// 보존할 수 있으므로, 해석되지 않은 path dependency를 파일로 가장하지 않는다.
Map<String, String> _packageConfigRoots(String root) {
  final file = File(p.join(root, '.dart_tool', 'package_config.json'));
  if (!file.existsSync()) {
    throw const FormatException(
      'source_packages requires .dart_tool/package_config.json',
    );
  }
  final document = jsonDecode(readConfigurationSync(file));
  if (document is! Map || document['packages'] is! List) {
    throw const FormatException('source_packages package config is invalid');
  }
  final result = <String, String>{};
  for (final value in document['packages'] as List) {
    if (value is! Map ||
        value['name'] is! String ||
        value['rootUri'] is! String) {
      throw const FormatException('source_packages package config is invalid');
    }
    final rootUri = file.parent.uri.resolve(value['rootUri'] as String);
    if (rootUri.scheme != 'file') continue;
    final packageRoot = Directory.fromUri(rootUri).resolveSymbolicLinksSync();
    result[p.normalize(packageRoot)] = value['name'] as String;
  }
  return result;
}

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
  final document = loadYaml(readConfigurationSync(file));
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
    if (_isExternalBinding(name, annotationLibrary)) {
      return RetentionReason.externalBinding;
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
  // @JS·@staticInterop 같은 binding annotation이 붙은 타입의 멤버는 외부
  // 런타임이 호출한다 — 멤버 자신의 metadata만 보면 놓친다. analyzer 14의
  // ClassBody는 Declaration이 아니라 선언 사이에 끼므로 Declaration만 검사하고
  // 계속 올라간다. extension 멤버는 on 절 타겟 타입의 annotation을 본다
  // (@staticInterop 타입에 API를 얹는 관용구).
  for (
    AstNode? ancestor = node.parent;
    ancestor != null && ancestor is! CompilationUnit;
    ancestor = ancestor.parent
  ) {
    if (ancestor is! Declaration) continue;
    final bound = ancestor.metadata.any(
      (annotation) => _isExternalBinding(
        annotation.name.name.split('.').last,
        annotation.element?.library?.uri.toString(),
      ),
    );
    if (bound) return RetentionReason.externalBinding;
    if (ancestor is ExtensionDeclaration) {
      final extended = ancestor.onClause?.extendedType.type?.element;
      if (extended is InterfaceElement &&
          extended.metadata.annotations.any(_isExternalBindingElement)) {
        return RetentionReason.externalBinding;
      }
    }
  }
  if (_overridesInheritedMember(element)) {
    return RetentionReason.overrideContract;
  }
  return null;
}

/// 외부 런타임이 이름으로 호출하는 binding annotation인지 판정한다.
///
/// package:js 계열(`JS`·`JSExport`·`JSAnonymous`·`staticInterop`)과 FFI 계열
/// (`Native`·`FfiNative`)은 annotation이 실제 그 라이브러리에서 와야 한다 —
/// 이름만 같은 사용자 선언이 호출 계약을 위장하지 못한다(visibleForTesting과
/// 같은 검증 규칙).
bool _isExternalBinding(String name, String? annotationLibrary) {
  if (annotationLibrary == null) return false;
  if (annotationLibrary == 'dart:js_interop' ||
      annotationLibrary.startsWith('package:js/')) {
    return _jsBindingAnnotations.contains(name);
  }
  if (annotationLibrary == 'dart:ffi' ||
      annotationLibrary.startsWith('package:ffi/')) {
    return _ffiBindingAnnotations.contains(name);
  }
  return false;
}

// `anonymous`는 `const _Anonymous anonymous`로 선언된 상수라 작성명·요소명 모두
// 'anonymous'다 — 클래스 이름(JSAnonymous·_Anonymous)이 아니라 적힌 이름을 본다.
const _jsBindingAnnotations = {
  'JS',
  'JSAnonymous',
  'JSExport',
  'anonymous',
  'staticInterop',
};

const _ffiBindingAnnotations = {'FfiNative', 'Native'};

/// 요소 수준 annotation(ElementAnnotation)이 외부 binding 계약인지 본다.
///
/// AST의 `Annotation.element`와 달리 생성자 호출은 `element.name`이 생성자
/// 이름(`new`·`JS.named`)이라 클래스 이름은 enclosingElement에서 가져온다.
bool _isExternalBindingElement(ElementAnnotation annotation) {
  final element = annotation.element;
  if (element == null) return false;
  final name = element is ConstructorElement
      ? element.enclosingElement.name
      : element.name;
  return name != null &&
      _isExternalBinding(name, element.library?.uri.toString());
}

/// 대표 라이브러리가 공개하는 선언과 그 멤버를 보존 루트로 삼는다.
///
/// 후보 ID는 라이브러리 해석에서 나온다(`_libraryFacts`). 여기서는 전역 정점
/// 집합으로 존재 여부만 판정한다 — 전체 해석과 증분 해석이 같은 정점 집합을
/// 보므로 같은 결정을 낸다.
void _addPublicApiRoots(
  CodeGraph graph,
  Map<String, RetentionReason> roots,
  Iterable<String> exportedIds,
) {
  // export 심볼마다 정렬 뷰를 다시 만들지 않는다 — 노드 ID 목록을 한 번만
  // 뽑아 재사용한다(감사 P2; CodeGraph 뷰 캐시와 별개의 루프 측 hoist).
  final allNodeIds = graph.nodes.keys.toList(growable: false);
  for (final id in exportedIds) {
    if (!graph.containsNode(id)) continue;
    roots.putIfAbsent(id, () => RetentionReason.publicApi);
    final memberPrefix = '$id.';
    for (final nodeId in allNodeIds.where(
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
  String? pubspecContent,
) {
  if (pubspecContent == null) return const {};
  final matches = RegExp(
    r'^\s*(?:pluginClass|dartPluginClass):\s*([A-Za-z_$][\w$]*)\s*$',
    multiLine: true,
  ).allMatches(pubspecContent);
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
      // 선언 수준 이유(inlineIgnore 등 사용자 지시 포함)가 이미 있으면 덮지
      // 않는다 — publicApi와 같은 putIfAbsent 규약이다.
      roots.putIfAbsent(candidate, () => RetentionReason.pluginEntryPoint);
      final registration = '$candidate.registerWith';
      if (graph.containsNode(registration)) {
        roots.putIfAbsent(registration, () => RetentionReason.pluginEntryPoint);
      }
    }
  }
  return limitations;
}

final class _RelationshipCollector extends GeneralizingAstVisitor<void> {
  _RelationshipCollector(this.edges, this.root);

  /// 이 유닛의 AST에서 나온 간선 후보다.
  ///
  /// 양끝 정점 존재 여부는 조립 단계가 전역 정점 집합으로 판정한다
  /// (`_assembleResult`) — 전체 해석과 증분 해석이 같은 판정을 내리고, 캐시된
  /// 사실이 다른 유닛의 정점 존재 여부에 좌우되지 않는다.
  final List<GraphEdge> edges;

  final String root;
  String? _owner;

  // element→ID 메모. 같은 선언을 가리키는 참조는 식별자 방문마다 반복되므로
  // (간선 시도 수 ≈ 식별자 수) _elementId의 경로 정규화·이름 체인 구성을
  // element당 1회로 줄인다(감사 P1). 순수 함수의 결과 캐시라 출력은 불변이고,
  // collector는 인덱싱 1회만 살아있으므로 Element 인스턴스 동일성이 안전하다.
  final Map<Element, String> _idMemo = {};

  String _idOf(Element element) =>
      _idMemo.putIfAbsent(element, () => _elementId(element, root));

  @override
  void visitDeclaration(Declaration node) {
    final previous = _owner;
    final element = node.declaredFragment?.element;
    if (element != null && _isGraphElement(element)) {
      _owner = _idOf(element);
      final enclosing = element.enclosingElement;
      if (enclosing != null && _isGraphElement(enclosing)) {
        _add(_idOf(enclosing), _owner!, EdgeKind.member);
      }
      if (element is InterfaceElement) {
        final supertype = element.supertype;
        if (supertype != null &&
            supertype.element.library.uri.scheme != 'dart') {
          _add(_owner!, _idOf(supertype.element), EdgeKind.inheritance);
        }
        for (final type in element.interfaces) {
          _add(_owner!, _idOf(type.element), EdgeKind.implements);
        }
        for (final type in element.mixins) {
          _add(_owner!, _idOf(type.element), EdgeKind.mixin);
        }
      }
      if (element is ExecutableElement && enclosing is InterfaceElement) {
        final name = element.name;
        if (name != null) {
          for (final overridden in enclosing.inheritedMembers.values.where(
            (candidate) => candidate.name == name,
          )) {
            _add(_owner!, _idOf(overridden.baseElement), EdgeKind.override);
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
          _idOf(target),
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
      _add(owner, _idOf(target), EdgeKind.call);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final owner = _owner;
    final target = _graphTarget(node.writeElement);
    if (owner != null && target != null && _isGraphElement(target)) {
      _add(owner, _idOf(target), EdgeKind.reference);
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
      _add(owner, _idOf(target), EdgeKind.call);
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
      _add(owner, _idOf(element), EdgeKind.reference);
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
    if (source != target) {
      edges.add(GraphEdge(sourceId: source, targetId: target, kind: kind));
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
  List<Directory> sourcePackages,
) {
  final paths = <String>{};
  bool inAnalysisScope(String path) {
    if (_isStandardSourcePath(path, root)) return true;
    final package = sourcePackages.where(
      (item) => isPathWithinRoot(path, p.join(item.path, 'lib')),
    );
    if (package.isEmpty) return false;
    try {
      // Analyzer may report a symlinked file even when filesystem traversal
      // uses followLinks:false. Keep the opt-in package scope lexical.
      return p.equals(
        p.normalize(path),
        p.normalize(File(path).resolveSymbolicLinksSync()),
      );
    } on FileSystemException {
      return false;
    }
  }

  for (final context in collection.contexts) {
    paths.addAll(
      context.contextRoot.analyzedFiles().where(
        (path) =>
            path.endsWith('.dart') &&
            isPathWithinRoot(path, root) &&
            inAnalysisScope(path),
      ),
    );
  }
  paths.addAll(
    Directory(root)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((file) => file.path)
        .where(_isGenerated)
        .where(inAnalysisScope)
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
