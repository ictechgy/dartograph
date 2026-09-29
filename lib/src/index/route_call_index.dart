/// isthmus http 도메인의 `route-call` 생산자다(GRAPH-EXCHANGE "HTTP 경계").
///
/// analyzer가 해석한 프로젝트 유닛에서 package:http·dio·retrofit.dart·chopper
/// 호출과 사용자가 선언한 래퍼(`http-wrappers` v1) 호출을 찾아 (method, 정규
/// 경로 템플릿) 사실로 낸다. 라이브러리 신원은 element의 라이브러리 URI로만
/// 판정하고, 조립 규칙은 [composeRoute](url-compose 벡터)를 쓴다. 증명하지
/// 못한 경로·동사·신원은 dynamic 사실과 호출 측 limitation으로 남긴다 —
/// 추측한 사실은 거짓 `route-call-without-decl` error가 되기 때문이다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import 'analyzer_graph_index.dart';
import 'bridge_index.dart'
    show enclosingFactSymbol, rejectFactControlCharacters;
import 'http_wrappers.dart';
import 'route_client_models.dart';
import 'route_url_rules.dart';
import 'route_value_resolver.dart';

/// `route-call` 사실과 추출 한계다.
final class RouteCallIndexResult {
  /// 결정적으로 정렬된 사실과 한계를 담는다.
  const RouteCallIndexResult(this.facts, this.limitations);

  /// GRAPH-EXCHANGE `route-call` fact 객체다.
  final List<Map<String, Object?>> facts;

  /// 사실로 만들지 못한 근거의 계수와 유형이다(호출 측·체인 전용 접두사).
  final List<String> limitations;
}

/// [rootPath] 패키지의 HTTP 클라이언트 호출을 `route-call` 사실로 만든다.
///
/// `symbol.usr`는 `dartograph impact [rootPath]`와 같은 그래프 선언 ID다.
/// [projectRootPath]는 교환 문서의 `project`(위치 경로의 기준)이며 `bridges`와
/// 같은 규칙으로 [rootPath]를 포함해야 한다. [wrappers] 중 `dart` 선언만
/// 적용한다. [includeTests]가 거짓이면 `test/`·`integration_test/`의 호출을 내지
/// 않는다.
Future<RouteCallIndexResult> indexRouteCalls(
  String rootPath, {
  String? projectRootPath,
  List<HttpWrapperDeclaration> wrappers = const [],
  bool includeTests = false,
}) async {
  final root = Directory(rootPath).absolute.resolveSymbolicLinksSync();
  final pathBase = projectRootPath == null
      ? root
      : Directory(projectRootPath).absolute.resolveSymbolicLinksSync();
  if (!p.equals(pathBase, root) && !p.isWithin(pathBase, root)) {
    throw ArgumentError.value(
      projectRootPath,
      'projectRootPath',
      'must contain the package root',
    );
  }
  final units = await resolveProjectUnits(root);
  final scan = _RouteScan(
    root: root,
    pathBase: pathBase,
    wrappers: [
      for (final wrapper in wrappers)
        if (wrapper.language == 'dart') wrapper,
    ],
    includeTests: includeTests,
  );
  scan.prepare(units);
  for (final unit in units) {
    scan.scanUnit(unit);
  }
  return scan.result();
}

/// 생성 파일로 보는 접미사다. 그래프의 생성 파일 목록에 chopper 생성기의
/// `.chopper.dart`를 더한다(route 사실 전용 — 그래프 의미는 바꾸지 않는다).
const _generatedSuffixes = {
  '.g.dart',
  '.freezed.dart',
  '.chopper.dart',
  '.pb.dart',
  '.pbenum.dart',
  '.pbgrpc.dart',
  '.pbjson.dart',
  '.pbserver.dart',
};

/// 패키지 해석 실패를 세는 HTTP 클라이언트 패키지다.
const _clientPackages = {'http', 'dio', 'retrofit', 'chopper'};

/// dio 요청을 바꾸는 쓰기 대상 속성이다.
const _rewrittenProperties = {'path', 'baseUrl', 'method'};

/// 한 번의 스캔 상태다.
final class _RouteScan {
  _RouteScan({
    required this.root,
    required this.pathBase,
    required this.wrappers,
    required this.includeTests,
  }) : wrapperHits = List.filled(wrappers.length, 0);

  final String root;
  final String pathBase;
  final List<HttpWrapperDeclaration> wrappers;
  final bool includeTests;
  final List<int> wrapperHits;

  final declarations = ValueDeclarations();
  late final resolver = RouteValueResolver(declarations);
  final facts = <Map<String, Object?>>[];

  /// base·동사 설정이 다시 쓰인 dio·BaseOptions 변수다.
  final dioMutated = <Element>{};

  /// 누구의 것인지 모르는 dio 설정 쓰기가 있었다 — 모든 리터럴 base를 버린다.
  var dioGlobalUnknown = false;

  /// dio RequestOptions의 path·baseUrl·method를 바꾸는 위치 수다.
  final rewrites = <String, int>{};

  /// 생성자 호출이 `baseUrl`을 넘기는 retrofit.dart 서비스 타입이다.
  final retrofitOverridden = <Element>{};

  final coverage = <String, int>{};
  final unresolvedImports = <String, int>{};
  var ambiguousJoins = 0;
  var undeclaredSinks = 0;
  var generatedUnscanned = 0;

  /// 전역 사전 조사: 값 선언, dio 설정 쓰기, 요청 재작성, retrofit base 재정의.
  void prepare(List<ResolvedUnitResult> units) {
    for (final unit in units) {
      declarations.collect(unit.unit);
    }
    for (final unit in units) {
      if (_isGenerated(unit.path)) continue;
      unit.unit.accept(_Prepass(this));
    }
  }

  /// 유닛 하나에서 사실을 모은다.
  void scanUnit(ResolvedUnitResult unit) {
    final rootRelative = p.posix.joinAll(
      p.split(p.relative(unit.path, from: root)),
    );
    final test =
        rootRelative.startsWith('test/') ||
        rootRelative.startsWith('integration_test/');
    if (test && !includeTests) return;
    _countUnresolvedImports(unit.unit);
    if (_isGenerated(unit.path)) {
      _checkGenerated(unit);
      return;
    }
    final location = p.posix.joinAll(
      p.split(p.relative(unit.path, from: pathBase)),
    );
    rejectFactControlCharacters(location);
    unit.unit.accept(_CallVisitor(this, unit, location, test));
  }

  void _countUnresolvedImports(CompilationUnit unit) {
    for (final directive in unit.directives.whereType<ImportDirective>()) {
      final uri = directive.uri.stringValue;
      if (uri == null || !uri.startsWith('package:')) continue;
      final package = uri.substring('package:'.length).split('/').first;
      if (!_clientPackages.contains(package)) continue;
      if (directive.libraryImport?.importedLibrary == null) {
        unresolvedImports.update(package, (n) => n + 1, ifAbsent: () => 1);
      }
    }
  }

  /// 생성 파일은 사실을 내지 않는다. 서비스 선언(retrofit.dart·chopper)이 없는
  /// 라이브러리의 생성 파일이 HTTP 호출을 담으면 `generated-client-unscanned:`다.
  void _checkGenerated(ResolvedUnitResult unit) {
    final probe = _ClientCallProbe();
    unit.unit.accept(probe);
    if (!probe.found) return;
    final library = unit.libraryElement;
    final modelled = library.classes.any(
      (type) => _serviceAnnotation(type) != null,
    );
    if (!modelled) generatedUnscanned++;
  }

  /// 사실 하나를 추가한다.
  void emit({
    required ResolvedUnitResult unit,
    required String location,
    required AstNode at,
    required ComposedRoute composed,
    required String? method,
    required bool test,
    String? service,
    String? baseRef,
  }) {
    if (composed.limitation == ambiguousBaseJoinPrefix) ambiguousJoins++;
    final usr = enclosingGraphDeclarationId(at, root);
    final symbol = usr == null
        ? enclosingFactSymbol(at)
        : {'qualifiedName': usr.substring(usr.indexOf('::') + 2), 'usr': usr};
    facts.add({
      'kind': 'route-call',
      'method': ?method,
      if (method == null) 'methodDynamic': true,
      'channel': composed.dynamic ? null : composed.template,
      'dynamic': composed.dynamic,
      'pathAnchor': composed.pathAnchor ?? 'base',
      'authority': ?composed.authority,
      'baseRef': ?baseRef,
      'service': ?service,
      if (composed.dynamic) 'channelPrefix': ?composed.channelPrefix,
      if (composed.queryTailStripped) 'queryTailStripped': true,
      if (composed.maskedSegments > 0)
        'maskedSegments': composed.maskedSegments,
      if (test) 'testSource': true,
      'location': _location(unit, location, at.offset),
      'symbol': ?symbol,
    });
  }

  Map<String, Object?> _location(
    ResolvedUnitResult unit,
    String path,
    int offset,
  ) {
    final line = unit.lineInfo.getLocation(offset).lineNumber;
    final start = unit.lineInfo.getOffsetOfLine(line - 1);
    return {
      'path': path,
      'line': line,
      'column': utf8.encode(unit.content.substring(start, offset)).length + 1,
    };
  }

  /// 결정적으로 정렬한 결과다.
  RouteCallIndexResult result() {
    facts.sort(_compareFacts);
    return RouteCallIndexResult(facts, _limitations());
  }

  List<String> _limitations() {
    final missing = facts.where(_withoutUsr).length;
    final unresolvedWrappers = [
      for (var index = 0; index < wrappers.length; index++)
        if (wrapperHits[index] == 0) 'wrappers[${wrappers[index].position}]',
    ];
    final rewriteSites = rewrites.values.fold(0, (sum, n) => sum + n);
    return [
      if (coverage.isNotEmpty)
        'route-call-coverage: ${_sum(coverage)} call site(s) use HTTP client '
            'APIs this producer does not model (${_breakdown(coverage)}); their '
            'requests are not facts',
      if (unresolvedImports.isNotEmpty)
        'route-call-coverage: ${_sum(unresolvedImports)} import(s) of HTTP '
            'client packages could not be resolved '
            '(${_breakdown(unresolvedImports)}); run dart pub get so their '
            'calls can be identified',
      if (ambiguousJoins > 0)
        'ambiguous-base-join: $ambiguousJoins call(s) join a path without a '
            'leading slash to an unknown dio base URL (simple concatenation); '
            'they are dynamic facts',
      if (rewriteSites > 0)
        'url-rewrite-interceptors: $rewriteSites site(s) rewrite dio '
            'RequestOptions ${_breakdown(rewrites)}; dio and retrofit.dart '
            'calls lose literal bases, rewritten paths become dynamic and '
            'rewritten methods become methodDynamic',
      if (unresolvedWrappers.isNotEmpty)
        'http-wrapper-unresolved: ${unresolvedWrappers.length} declared dart '
            'wrapper(s) matched no call (${unresolvedWrappers.join(', ')}); '
            'check owner and name against dartograph declaration ids',
      if (undeclaredSinks > 0)
        'http-wrapper-undeclared: $undeclaredSinks HTTP call(s) build their URL '
            'from a parameter of the enclosing function; declare that function '
            'in an http-wrappers file so its callers become facts',
      if (generatedUnscanned > 0)
        'generated-client-unscanned: $generatedUnscanned generated Dart '
            'file(s) contain HTTP client calls without a modelled retrofit.dart '
            'or chopper service declaration; their requests are not facts',
      if (missing > 0)
        'missing-route-usrs: $missing route-call fact(s) have no dartograph '
            'declaration identity (the enclosing declaration did not resolve); '
            'trace cannot continue from them',
    ];
  }

  bool _withoutUsr(Map<String, Object?> fact) {
    final symbol = fact['symbol'] as Map<String, Object?>?;
    return symbol?['usr'] == null;
  }

  /// 선언된 래퍼 [element]이면 그 선언 순번이다.
  int? wrapperFor(Element? element) {
    final key = _wrapperKey(element);
    if (key == null) return null;
    for (var index = 0; index < wrappers.length; index++) {
      final wrapper = wrappers[index];
      if (wrapper.kind == key.kind &&
          wrapper.owner == key.owner &&
          wrapper.name == key.name) {
        return index;
      }
    }
    return null;
  }

  ({String kind, String owner, String name})? _wrapperKey(Element? element) {
    if (element is TopLevelFunctionElement) {
      final name = element.name;
      if (name == null) return null;
      final owner = graphLibraryId(element.library.uri, root);
      return (kind: 'function', owner: owner, name: name);
    }
    final owner = element?.enclosingElement;
    final ownerId = owner == null ? null : graphElementId(owner, root);
    if (ownerId == null) return null;
    if (element is MethodElement && element.name != null) {
      return (kind: 'function', owner: ownerId, name: element.name!);
    }
    if (element is ConstructorElement) {
      final name = element.name;
      return (
        kind: 'constructor',
        owner: ownerId,
        name: name == null || name.isEmpty ? 'new' : name,
      );
    }
    return null;
  }

  /// [node]를 감싸는 실행 선언이 선언된 래퍼인지다. 래퍼 본문의 dynamic 호출은
  /// 래퍼 호출 사실이 대신하므로 내지 않는다.
  bool insideDeclaredWrapper(AstNode node) {
    for (AstNode? current = node; current != null; current = current.parent) {
      final element = switch (current) {
        MethodDeclaration() => current.declaredFragment?.element,
        FunctionDeclaration() => current.declaredFragment?.element,
        ConstructorDeclaration() => current.declaredFragment?.element,
        _ => null,
      };
      if (element != null && wrapperFor(element) != null) return true;
    }
    return false;
  }
}

bool _isGenerated(String path) => _generatedSuffixes.any(path.endsWith);

int _sum(Map<String, int> counts) => counts.values.fold(0, (a, b) => a + b);

String _breakdown(Map<String, int> counts) => (counts.keys.toList()..sort())
    .map((key) => '$key ${counts[key]}')
    .join(', ');

int _compareFacts(Map<String, Object?> a, Map<String, Object?> b) {
  final al = a['location']! as Map<String, Object?>;
  final bl = b['location']! as Map<String, Object?>;
  final byPath = (al['path']! as String).compareTo(bl['path']! as String);
  if (byPath != 0) return byPath;
  final byLine = (al['line']! as int).compareTo(bl['line']! as int);
  if (byLine != 0) return byLine;
  final byColumn = (al['column']! as int).compareTo(bl['column']! as int);
  if (byColumn != 0) return byColumn;
  return '${a['channel']}\u0000${a['method']}'.compareTo(
    '${b['channel']}\u0000${b['method']}',
  );
}

/// 클래스의 retrofit.dart `@RestApi`·chopper `@ChopperApi` 상수다.
({String library, DartObject? value})? _serviceAnnotation(Element type) {
  for (final annotation in type.metadata.annotations) {
    final value = annotation.computeConstantValue();
    if (isPackageConstant(value, 'retrofit', 'RestApi')) {
      return (library: 'retrofit', value: value);
    }
    if (isPackageConstant(value, 'chopper', 'ChopperApi')) {
      return (library: 'chopper', value: value);
    }
  }
  return null;
}

/// 전역 사전 조사 방문자다.
final class _Prepass extends RecursiveAstVisitor<void> {
  _Prepass(this.scan);

  final _RouteScan scan;

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final left = node.leftHandSide;
    final (target, name) = switch (left) {
      PropertyAccess() => (left.realTarget, left.propertyName.name),
      PrefixedIdentifier() => (left.prefix, left.identifier.name),
      _ => (null, null),
    };
    if (target != null && name != null) {
      _propertyWrite(node, target, name);
    } else {
      _variableWrite(node);
    }
    super.visitAssignmentExpression(node);
  }

  void _propertyWrite(AstNode node, Expression target, String name) {
    final type = target.staticType?.element;
    if (_rewrittenProperties.contains(name) &&
        type is InterfaceElement &&
        hasPackageSupertype(type, 'dio', const {'RequestOptions'})) {
      scan.rewrites.update(name, (n) => n + 1, ifAbsent: () => 1);
      return;
    }
    final isBase = hasPackageSupertype(
      type is InterfaceElement ? type : null,
      'dio',
      const {'BaseOptions'},
    );
    if ((name == 'baseUrl' || name == 'method') && isBase) {
      _markOwner(node, target);
    } else if (name == 'options' &&
        hasPackageSupertype(
          type is InterfaceElement ? type : null,
          'dio',
          const {'Dio'},
        )) {
      _mark(node, target);
    }
  }

  /// `x.options.baseUrl =`은 dio 변수 x를, `options.baseUrl =`(BaseOptions
  /// 변수)은 그 변수를 표시한다.
  void _markOwner(AstNode node, Expression target) {
    final options = target.unParenthesized;
    final owner = switch (options) {
      PropertyAccess(:final propertyName) when propertyName.name == 'options' =>
        options.realTarget,
      PrefixedIdentifier(:final identifier) when identifier.name == 'options' =>
        options.prefix,
      _ => options,
    };
    _mark(node, owner);
  }

  void _mark(AstNode node, Expression target) {
    if (_insideFreshCascade(node)) return;
    final variable = referencedVariable(target);
    // Dio 하위 타입 안의 `options` 필드처럼 라이브러리 필드면 어느 인스턴스인지
    // 모른다.
    if (variable == null || isFromPackage(variable, 'dio')) {
      scan.dioGlobalUnknown = true;
    } else {
      scan.dioMutated.add(variable);
    }
  }

  /// `Dio()..options.baseUrl = …`처럼 새 객체의 초기 설정인지다.
  bool _insideFreshCascade(AstNode node) {
    final cascade = node.thisOrAncestorOfType<CascadeExpression>();
    return cascade != null &&
        cascade.target.unParenthesized is InstanceCreationExpression;
  }

  void _variableWrite(AssignmentExpression node) {
    final written = node.writeElement?.baseElement;
    final variable = written is SetterElement ? written.variable : written;
    if (variable is! VariableElement) return;
    final type = variable.type.element;
    if (type is InterfaceElement &&
        hasPackageSupertype(type, 'dio', const {'Dio', 'BaseOptions'})) {
      scan.dioMutated.add(variable);
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.realTarget?.staticType?.element;
    if (node.methodName.name == 'copyWith' &&
        target is InterfaceElement &&
        hasPackageSupertype(target, 'dio', const {'RequestOptions'})) {
      for (final argument
          in node.argumentList.arguments.whereType<NamedArgument>()) {
        final name = argument.name.lexeme;
        if (_rewrittenProperties.contains(name)) {
          scan.rewrites.update(name, (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    // baseUrl 인자가 있는 생성만 서비스 여부를 계산한다(어노테이션 상수 평가 비용).
    final passesBase = node.argumentList.arguments
        .whereType<NamedArgument>()
        .any(
          (argument) =>
              argument.name.lexeme == 'baseUrl' &&
              argument.argumentExpression is! NullLiteral,
        );
    final type = node.constructorName.element?.enclosingElement;
    final service = passesBase && type != null ? _retrofitService(type) : null;
    if (service != null) scan.retrofitOverridden.add(service);
    super.visitInstanceCreationExpression(node);
  }
}

/// [type]이나 상위 타입 중 `@RestApi` 서비스 타입이다(생성된 `_ApiClient`도
/// 원래 서비스로 돌려준다).
Element? _retrofitService(InterfaceElement type) {
  if (_serviceAnnotation(type)?.library == 'retrofit') return type;
  for (final supertype in type.allSupertypes) {
    if (_serviceAnnotation(supertype.element)?.library == 'retrofit') {
      return supertype.element;
    }
  }
  return null;
}

/// 생성 파일에 HTTP 클라이언트 호출이 있는지 본다.
final class _ClientCallProbe extends RecursiveAstVisitor<void> {
  var found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final element = node.methodName.element;
    if (httpTopLevelVerb(element) != null ||
        httpClientMethodVerb(element) != null ||
        dioMethodName(element) != null ||
        isChopperClientRequest(element) ||
        isIoHttpClientRequest(element)) {
      found = true;
    }
    super.visitMethodInvocation(node);
  }
}

/// 유닛 하나의 호출 방문자다.
final class _CallVisitor extends RecursiveAstVisitor<void> {
  _CallVisitor(this.scan, this.unit, this.location, this.test);

  final _RouteScan scan;
  final ResolvedUnitResult unit;
  final String location;
  final bool test;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final element = node.methodName.element;
    final wrapper = scan.wrapperFor(element);
    if (wrapper != null) {
      _wrapperCall(node, node.argumentList, wrapper);
    } else {
      _libraryCall(node, element);
    }
    super.visitMethodInvocation(node);
  }

  void _libraryCall(MethodInvocation node, Element? element) {
    final verb = httpTopLevelVerb(element) ?? httpClientMethodVerb(element);
    if (verb != null) {
      _httpCall(node, verb, _positional(node.argumentList, 0));
      return;
    }
    final dio = dioMethodName(element);
    if (dio != null) {
      _dioCall(node, dio);
    } else if (isIoHttpClientRequest(element)) {
      _count('dart:io HttpClient');
    } else if (isChopperClientRequest(element)) {
      _count('chopper ChopperClient');
    }
  }

  void _count(String reason) =>
      scan.coverage.update(reason, (n) => n + 1, ifAbsent: () => 1);

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final element = node.constructorName.element;
    final wrapper = scan.wrapperFor(element);
    if (wrapper != null) {
      _wrapperCall(node, node.argumentList, wrapper);
    } else if (isHttpRequestConstructor(element)) {
      final method = _positional(node.argumentList, 0);
      final literal = method == null
          ? null
          : scan.resolver.resolve(method).literal;
      _httpCall(
        node,
        routeCallVerbs.contains(literal) ? literal : null,
        _positional(node.argumentList, 1),
      );
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final element = node.declaredFragment?.element;
    final service = element == null ? null : _serviceAnnotation(element);
    if (service != null && element != null) {
      final members = node.body is BlockClassBody
          ? (node.body as BlockClassBody).members
          : const <ClassMember>[];
      for (final method in members.whereType<MethodDeclaration>()) {
        if (service.library == 'retrofit') {
          _retrofitMethod(method, element, service.value);
        } else {
          _chopperMethod(method, service.value);
        }
      }
    }
    super.visitClassDeclaration(node);
  }

  // package:http ---------------------------------------------------------

  void _httpCall(AstNode node, String? verb, Expression? url) {
    final resolved = url == null ? null : _uriRoute(url);
    final composed = resolved?.$1 ?? const ComposedRoute.dynamicRoute();
    if (composed.dynamic && scan.insideDeclaredWrapper(node)) return;
    if (composed.dynamic && (resolved?.$2 ?? false)) scan.undeclaredSinks++;
    _emit(node, composed, verb);
  }

  /// `Uri` 식을 조립한다. 두 번째 값은 매개변수에서 온 값이 섞였는지다.
  (ComposedRoute, bool)? _uriRoute(Expression expression) {
    final node = _followUri(expression.unParenthesized, 0);
    if (node is MethodInvocation && _isUriStatic(node, {'parse', 'tryParse'})) {
      final source = _positional(node.argumentList, 0);
      if (source == null) return null;
      final resolved = scan.resolver.resolve(source);
      return (
        composeRoute(resolved.parts, const UriStringJoin()),
        resolved.leadingParameter,
      );
    }
    if (node is InstanceCreationExpression && _isUriFactory(node)) {
      return _uriComponents(node);
    }
    return (
      const ComposedRoute.dynamicRoute(),
      referencedVariable(node) is FormalParameterElement,
    );
  }

  /// `Uri` 값을 담은 증명된 변수를 초기식으로 따라간다.
  Expression _followUri(Expression expression, int depth) {
    final node = expression is PostfixExpression
        ? expression.operand.unParenthesized
        : expression;
    if (depth > 4) return node;
    final variable = referencedVariable(node);
    if (variable == null) return node;
    final initializer = scan.resolver.initializerOf(node, variable);
    return initializer == null
        ? node
        : _followUri(initializer.unParenthesized, depth + 1);
  }

  bool _isUriStatic(MethodInvocation node, Set<String> names) {
    final element = node.methodName.element;
    final owner = element?.enclosingElement;
    return names.contains(node.methodName.name) &&
        owner is InterfaceElement &&
        owner.name == 'Uri' &&
        element?.library?.uri.toString() == 'dart:core';
  }

  bool _isUriFactory(InstanceCreationExpression node) {
    final element = node.constructorName.element;
    final owner = element?.enclosingElement;
    return owner is InterfaceElement &&
        owner.name == 'Uri' &&
        element?.library.uri.toString() == 'dart:core' &&
        (element?.name == 'https' || element?.name == 'http');
  }

  /// `Uri.https(authority, unencodedPath, query)`다. authority는 경로를 담을 수
  /// 없어(`/`가 있으면 `FormatException`) host가 동적이어도 경로는 root다.
  (ComposedRoute, bool) _uriComponents(InstanceCreationExpression node) {
    final authority = _positional(node.argumentList, 0);
    final path = _positional(node.argumentList, 1);
    final host = authority == null
        ? null
        : scan.resolver.resolve(authority).literal?.toLowerCase();
    final resolved = path == null
        ? const ResolvedUrl([LiteralUrlPart('/')])
        : scan.resolver.resolve(path);
    final encoded = [
      for (final part in resolved.parts)
        part is LiteralUrlPart
            ? LiteralUrlPart(encodeUnencodedPath(part.text))
            : part is QueryTailUrlPart
            ? const ValueUrlPart()
            : part,
    ];
    final first = mergeUrlLiterals(encoded).firstOrNull;
    // 경로 인자 전체가 값이면 여러 세그먼트일 수 있어 `/{}`로 보지 않는다.
    if (first != null && first is! LiteralUrlPart) {
      return (
        const ComposedRoute.dynamicRoute(pathAnchor: 'root'),
        resolved.leadingParameter,
      );
    }
    final rooted = first is LiteralUrlPart && first.text.startsWith('/')
        ? encoded
        : [const LiteralUrlPart('/'), ...encoded];
    final composed = composeRoute(rooted, const UriPathJoin());
    return (
      _withAuthority(
        composed,
        host != null && isRouteAuthority(host) ? host : null,
      ),
      resolved.leadingParameter,
    );
  }

  ComposedRoute _withAuthority(ComposedRoute route, String? authority) =>
      authority == null
      ? route
      : ComposedRoute(
          template: route.template,
          dynamic: route.dynamic,
          channelPrefix: route.channelPrefix,
          pathAnchor: route.pathAnchor,
          authority: authority,
          queryTailStripped: route.queryTailStripped,
          maskedSegments: route.template == null
              ? 0
              : maskRouteTemplate(route.template!, authority).$2,
          limitation: route.limitation,
        );

  // dio ------------------------------------------------------------------

  void _dioCall(MethodInvocation node, String name) {
    if (dioUnmodelledMethods.contains(name)) {
      _count('dio fetch/download');
      return;
    }
    final fixed = dioFixedVerbs[name];
    if (fixed == null && !dioRequestMethods.contains(name)) return;
    final receiver = _dioReceiver(node);
    final argument = _positional(node.argumentList, 0);
    final resolved = argument == null ? null : _dioPath(argument, name);
    final composed = _dioCompose(resolved?.parts, receiver.base);
    if (composed.dynamic && scan.insideDeclaredWrapper(node)) return;
    if (composed.dynamic && (resolved?.leadingParameter ?? false)) {
      scan.undeclaredSinks++;
    }
    final method = fixed ?? _dioRequestVerb(node, receiver);
    _emit(
      node,
      composed,
      scan.rewrites.containsKey('method') ? null : method,
      baseRef: receiver.baseRef,
    );
  }

  /// `*Uri` 변형은 `uri.toString()`을 경로로 쓴다(dio `requestUri`).
  ResolvedUrl? _dioPath(Expression argument, String name) {
    if (!name.endsWith('Uri')) return scan.resolver.resolve(argument);
    final node = _followUri(argument.unParenthesized, 0);
    if (node is MethodInvocation && _isUriStatic(node, {'parse', 'tryParse'})) {
      final source = _positional(node.argumentList, 0);
      return source == null ? null : scan.resolver.resolve(source);
    }
    return null;
  }

  ComposedRoute _dioCompose(List<UrlPart>? parts, DioBase? base) {
    if (parts == null) return const ComposedRoute.dynamicRoute();
    final effective = scan.rewrites.containsKey('baseUrl') ? null : base;
    final composed = composeRoute(parts, DioJoin(effective));
    if (!scan.rewrites.containsKey('path') || composed.dynamic) return composed;
    return ComposedRoute.dynamicRoute(
      channelPrefix: composed.template,
      pathAnchor: composed.pathAnchor,
      authority: composed.authority,
    );
  }

  /// `request`의 동사다. `Options(method:)` 리터럴을 대문자로 바꾼 값(dio
  /// `Options.compose`)이나, 없으면 알려진 dio의 base 동사(기본 GET)다.
  String? _dioRequestVerb(MethodInvocation node, _DioReceiver receiver) {
    final options = _named(node.argumentList, 'options')?.unParenthesized;
    if (options == null) return receiver.method;
    if (options is! InstanceCreationExpression) return null;
    final method = _named(options.argumentList, 'method');
    if (method == null) return receiver.method;
    final literal = scan.resolver.resolve(method).literal?.toUpperCase();
    return routeCallVerbs.contains(literal) ? literal : null;
  }

  /// dio 수신 객체의 base·동사·신원이다. 증명하지 못하면 미상이다.
  _DioReceiver _dioReceiver(MethodInvocation node) {
    final target = node.realTarget?.unParenthesized;
    if (target == null) return const _DioReceiver();
    final variable = referencedVariable(target);
    final baseRef = variable == null
        ? null
        : graphElementId(variable, scan.root);
    final creation = _dioCreation(target, variable);
    if (creation == null) return _DioReceiver(baseRef: baseRef);
    final config = _dioConfig(creation);
    return _DioReceiver(
      base: config.base,
      method: config.method,
      baseRef: baseRef,
    );
  }

  /// 수신 식이 가리키는 `Dio(…)` 생성식(또는 그 cascade)이다.
  Expression? _dioCreation(Expression target, VariableElement? variable) {
    if (scan.dioGlobalUnknown) return null;
    if (variable == null) {
      final fresh =
          target is InstanceCreationExpression || target is CascadeExpression;
      return fresh ? target : null;
    }
    if (scan.dioMutated.contains(variable)) return null;
    return scan.resolver.initializerOf(target, variable)?.unParenthesized;
  }

  /// `Dio(BaseOptions(baseUrl:, method:))`와 `Dio()..options.baseUrl = …`를
  /// 읽는다.
  ({DioBase? base, String? method}) _dioConfig(Expression creation) {
    var core = creation;
    final cascade = creation is CascadeExpression ? creation : null;
    if (cascade != null) core = cascade.target.unParenthesized;
    if (core is! InstanceCreationExpression ||
        !hasPackageSupertype(
          core.constructorName.element?.enclosingElement,
          'dio',
          const {'Dio'},
        )) {
      return (base: null, method: null);
    }
    var options = _baseOptions(_positional(core.argumentList, 0));
    if (options == _OptionsValue.unknown) return (base: null, method: null);
    for (final section in cascade?.cascadeSections ?? const <Expression>[]) {
      options = _applyCascade(options, section);
      if (options == _OptionsValue.unknown) return (base: null, method: null);
    }
    return (
      base: options.baseUrl == null
          ? null
          : DioBase.parseLiteral(options.baseUrl!),
      method: options.method,
    );
  }

  _OptionsValue _applyCascade(_OptionsValue options, Expression section) {
    if (section is! AssignmentExpression) return options;
    final left = section.leftHandSide;
    if (left is! PropertyAccess) return options;
    final name = left.propertyName.name;
    final target = left.target;
    final onOptions =
        target is PropertyAccess && target.propertyName.name == 'options';
    if (name == 'options') return _baseOptions(section.rightHandSide);
    if (!onOptions || (name != 'baseUrl' && name != 'method')) return options;
    final literal = scan.resolver.resolve(section.rightHandSide).literal;
    if (literal == null) return _OptionsValue.unknown;
    return name == 'baseUrl'
        ? _OptionsValue(literal, options.method)
        : _OptionsValue(options.baseUrl, _verb(literal));
  }

  /// `BaseOptions(…)` 인자를 읽는다. 없으면 dio 기본값(`''`, GET)이다.
  _OptionsValue _baseOptions(Expression? argument) {
    if (argument == null) return const _OptionsValue(null, 'GET');
    var node = argument.unParenthesized;
    final variable = referencedVariable(node);
    if (variable != null) {
      if (scan.dioMutated.contains(variable)) return _OptionsValue.unknown;
      final initializer = scan.resolver.initializerOf(node, variable);
      if (initializer == null) return _OptionsValue.unknown;
      node = initializer.unParenthesized;
    }
    if (node is! InstanceCreationExpression) return _OptionsValue.unknown;
    final base = _named(node.argumentList, 'baseUrl');
    final method = _named(node.argumentList, 'method');
    final methodLiteral = method == null
        ? 'GET'
        : scan.resolver.resolve(method).literal;
    return _OptionsValue(
      base == null ? null : scan.resolver.resolve(base).literal,
      methodLiteral == null ? null : _verb(methodLiteral),
    );
  }

  String? _verb(String literal) {
    final upper = literal.toUpperCase();
    return routeCallVerbs.contains(upper) ? upper : null;
  }

  // retrofit.dart --------------------------------------------------------

  /// `@GET('/path')` 같은 메서드 하나다. 경로는 retrofit_generator의 `@Path`
  /// 치환(`replaceAll`) 후 dio 연결을 거친다 — base 결합은 두 단계다(아래
  /// [_retrofitBase]).
  void _retrofitMethod(
    MethodDeclaration method,
    ClassElement service,
    DartObject? serviceValue,
  ) {
    for (final annotation in method.metadata) {
      final value = annotation.elementAnnotation?.computeConstantValue();
      if (!isPackageConstant(value, 'retrofit', 'Method')) continue;
      final verb = constantField(value, 'method')?.toStringValue();
      final path = constantField(value, 'path')?.toStringValue();
      final names = _pathParameters(method, 'retrofit', 'value');
      final base = _retrofitBase(service, serviceValue);
      final composed = path == null || base == null
          ? const ComposedRoute.dynamicRoute()
          : _dioCompose(
              _placeholderParts(path, names, replaceAll: true),
              base.base,
            );
      // dio `Options.compose`가 동사를 대문자로 바꾼다.
      final upper = verb?.toUpperCase();
      final verbValue =
          scan.rewrites.containsKey('method') || !routeCallVerbs.contains(upper)
          ? null
          : upper;
      _emit(annotation, composed, verbValue);
    }
  }

  /// retrofit.dart의 첫 단계: `_combineBaseUrls(dio.options.baseUrl,
  /// baseUrl)`이다(retrofit_generator 10.2.11). 절대 URL이면 그대로, 상대면 dio
  /// base에 RFC 3986으로 해석하고, 비었으면 dio base다. 생성자 호출이 baseUrl을
  /// 넘기면 어노테이션 값을 믿지 않는다. null은 어노테이션을 읽지 못한 것이다.
  ({DioBase? base})? _retrofitBase(ClassElement service, DartObject? value) {
    if (value == null) return null;
    if (scan.retrofitOverridden.contains(service)) return (base: null);
    final raw = constantField(value, 'baseUrl')?.toStringValue();
    if (raw == null || raw.trim().isEmpty) return (base: null);
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.isAbsolute) return (base: DioBase.parseLiteral(uri.toString()));
    if (raw.startsWith('/')) {
      final path = Uri.parse('http://base.invalid').resolveUri(uri).path;
      return (base: DioBase(path: path, anchor: 'root'));
    }
    final merged = removeDotSegments('/${uri.path}', 'base');
    if (merged == null) return null;
    return (base: DioBase(path: merged, anchor: 'base'));
  }

  // chopper --------------------------------------------------------------

  /// `@Get(path: …)` 같은 메서드 하나다. chopper_generator 8.7.0이 생성 시점에
  /// `@ChopperApi(baseUrl)`과 경로를 문자열로 합치고(`@Path`는 `replaceFirst`),
  /// 실행 시 `Request.buildUri`가 `ChopperClient.baseUrl`과 슬래시 결합한다.
  void _chopperMethod(MethodDeclaration method, DartObject? serviceValue) {
    for (final annotation in method.metadata) {
      final value = annotation.elementAnnotation?.computeConstantValue();
      if (!isPackageConstant(value, 'chopper', 'Method')) continue;
      final verb = constantField(value, 'method')?.toStringValue();
      final path = constantField(value, 'path')?.toStringValue();
      final base = serviceValue == null
          ? null
          : constantField(serviceValue, 'baseUrl')?.toStringValue() ?? '';
      final names = _pathParameters(method, 'chopper', 'name');
      final composed = path == null || base == null
          ? const ComposedRoute.dynamicRoute()
          : _chopperCompose(base, _substitute(path, names, replaceAll: false));
      _emit(annotation, composed, routeCallVerbs.contains(verb) ? verb : null);
    }
  }

  ComposedRoute _chopperCompose(String base, String path) {
    final combined = chopperGeneratedUrl(base, path);
    if (RegExp('^https?://', caseSensitive: false).hasMatch(combined)) {
      return composeRoute(_markerParts(combined), const UriStringJoin());
    }
    final relative = combined.split(RegExp('[?#]')).first;
    final stripped = relative.trimLeft().startsWith('/')
        ? relative.trimLeft().substring(1)
        : relative.trimLeft();
    final dots = stripped.split('/').any((s) => s == '.' || s == '..');
    if (dots || stripped.startsWith('/')) {
      return const ComposedRoute.dynamicRoute(pathAnchor: 'base');
    }
    return composeRoute(
      _markerParts('/$stripped${combined.substring(relative.length)}'),
      const SlashJoin(),
    );
  }

  // 래퍼 --------------------------------------------------------------------

  void _wrapperCall(AstNode node, ArgumentList arguments, int index) {
    final wrapper = scan.wrappers[index];
    scan.wrapperHits[index]++;
    final values = <WrapperCallArgument>[
      for (final argument in arguments.arguments)
        (
          label: argument is NamedArgument ? argument.name.lexeme : null,
          value: _argumentValue(argument.argumentExpression, wrapper),
        ),
    ];
    final method = bindWrapperMethod(
      wrapper.methodArg,
      wrapper.defaultMethod,
      wrapper.methodEnum,
      values,
    );
    final pathIndex = findWrapperArgument(wrapper.pathArg, [
      for (final value in values) value.label,
    ]);
    final path = pathIndex == null
        ? null
        : arguments.arguments[pathIndex].argumentExpression;
    final composed = path == null
        ? const ComposedRoute.dynamicRoute()
        : composeRoute(
            scan.resolver.resolve(path).parts,
            DeclaredJoin(wrapper.pathAnchor),
          );
    _emit(node, composed, method, service: wrapper.service);
  }

  /// 동사 인자 값의 모양이다. enum 상수는 case 이름, 선언의 methodEnum에 이름이
  /// 있는 static 상수도 이름, 그 밖의 상수 문자열은 값이다.
  WrapperArgumentValue _argumentValue(
    Expression expression,
    HttpWrapperDeclaration wrapper,
  ) {
    final element = _referencedElement(expression);
    if (element is FieldElement && element.isEnumConstant) {
      return EnumCaseArgumentValue(element.name ?? '');
    }
    if (element is FieldElement &&
        element.isStatic &&
        wrapper.methodEnum.containsKey(element.name)) {
      return EnumCaseArgumentValue(element.name!);
    }
    final literal = scan.resolver.resolve(expression).literal;
    return literal == null
        ? const OpaqueArgumentValue()
        : LiteralArgumentValue(literal);
  }

  Element? _referencedElement(Expression expression) {
    final node = expression.unParenthesized;
    if (node is DotShorthandPropertyAccess) {
      final base = node.propertyName.element?.baseElement;
      return base is GetterElement ? base.variable : base;
    }
    return referencedVariable(node);
  }

  // 공통 ---------------------------------------------------------------------

  void _emit(
    AstNode node,
    ComposedRoute composed,
    String? method, {
    String? service,
    String? baseRef,
  }) => scan.emit(
    unit: unit,
    location: location,
    at: node,
    composed: composed,
    method: method,
    test: test,
    service: service,
    baseRef: baseRef,
  );

  /// `@Path` 어노테이션이 붙은 매개변수의 자리표시자 이름이다.
  List<String> _pathParameters(
    MethodDeclaration method,
    String package,
    String field,
  ) {
    final names = <String>[];
    for (final parameter in method.parameters?.parameters ?? const []) {
      for (final annotation in parameter.metadata) {
        final value = annotation.elementAnnotation?.computeConstantValue();
        if (!isPackageConstant(value, package, 'Path')) continue;
        final declared = constantField(value, field)?.toStringValue();
        final name = declared ?? parameter.name?.lexeme;
        if (name != null) names.add(name);
      }
    }
    return names;
  }

  List<UrlPart> _placeholderParts(
    String path,
    List<String> names, {
    required bool replaceAll,
  }) => _markerParts(_substitute(path, names, replaceAll: replaceAll));
}

/// dio 수신 객체에서 증명한 값이다.
final class _DioReceiver {
  const _DioReceiver({this.base, this.method, this.baseRef});

  final DioBase? base;
  final String? method;
  final String? baseRef;
}

/// `BaseOptions`에서 읽은 값이다. [unknown]은 증명하지 못한 설정이다.
final class _OptionsValue {
  const _OptionsValue(this.baseUrl, this.method);

  static const unknown = _OptionsValue('\u0000unknown', null);

  final String? baseUrl;
  final String? method;
}

Expression? _positional(ArgumentList arguments, int index) {
  final positional = arguments.arguments
      .where((argument) => argument is! NamedArgument)
      .toList();
  return index < positional.length
      ? positional[index].argumentExpression
      : null;
}

Expression? _named(ArgumentList arguments, String name) {
  for (final argument in arguments.arguments.whereType<NamedArgument>()) {
    if (argument.name.lexeme == name) return argument.argumentExpression;
  }
  return null;
}

/// 자리표시자 표식이다. 경로 문법 문자(`/`·`.`·`:`·`?`)를 담지 않아 생성기의
/// 문자열 처리 결과를 바꾸지 않는다.
const _markerStart = '\u{E000}';
const _markerEnd = '\u{E001}';

/// `{name}` 자리를 표식으로 바꾼다. retrofit_generator는 `replaceAll`,
/// chopper_generator는 `replaceFirst`다.
String _substitute(
  String path,
  List<String> names, {
  required bool replaceAll,
}) {
  var result = path;
  for (var index = 0; index < names.length; index++) {
    final marker = '$_markerStart$index$_markerEnd';
    result = replaceAll
        ? result.replaceAll('{${names[index]}}', marker)
        : result.replaceFirst('{${names[index]}}', marker);
  }
  return result;
}

List<UrlPart> _markerParts(String text) {
  final parts = <UrlPart>[];
  final pattern = RegExp('$_markerStart[0-9]+$_markerEnd');
  var cursor = 0;
  for (final match in pattern.allMatches(text)) {
    parts.add(LiteralUrlPart(text.substring(cursor, match.start)));
    parts.add(const ValueUrlPart());
    cursor = match.end;
  }
  parts.add(LiteralUrlPart(text.substring(cursor)));
  return parts;
}

/// chopper_generator 8.7.0 `_generateUrl`의 base·경로 문자열 결합이다.
String chopperGeneratedUrl(String baseUrl, String path) {
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  if (path.isEmpty && baseUrl.isEmpty) return '';
  if (path.isNotEmpty && baseUrl.isNotEmpty) {
    final pathSlash = path.startsWith('/');
    final baseSlash = baseUrl.endsWith('/');
    if (!baseSlash && !pathSlash) return '$baseUrl/$path';
    if (baseSlash && pathSlash) return '$baseUrl${path.replaceFirst('/', '')}';
  }
  if (baseUrl.startsWith('http://') || baseUrl.startsWith('https://')) {
    final uri = Uri.tryParse(baseUrl);
    if (uri != null) {
      final rest = '${uri.authority}${uri.path}$path'.replaceAll('//', '/');
      return '${uri.scheme}://$rest';
    }
  }
  return '$baseUrl$path'.replaceAll('//', '/');
}
