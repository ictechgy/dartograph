import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core/config_source.dart';
import 'analyzer_graph_index.dart';
import '../runtime/runtime_facts.dart';

/// analyzer 해석 결과에서 런타임 전용 의존성 사실을 모은다.
///
/// 리터럴과 호출 패턴만 본다. 문자열 보간·변수 키·리플렉션처럼 정적으로 확정할
/// 수 없는 대상은 [runtimeComputedName]과 [RuntimeFact.unverifiableReason]으로
/// 남겨, 판정하지 못한 사실도 보고서에 드러나게 한다.
final class RuntimeScanner {
  /// [rootPath] 패키지를 분석해 탐지 사실을 결정적 순서로 돌려준다.
  ///
  /// 파일 집합·해석 규칙은 그래프 인덱스와 같다([resolveProjectUnits]).
  Future<List<RuntimeFact>> scan(String rootPath) async {
    final root = Directory(rootPath).absolute.resolveSymbolicLinksSync();
    final units = await resolveProjectUnits(rootPath);
    final facts = <RuntimeFact>[];
    for (final unit in units) {
      unit.unit.accept(_RuntimeFactVisitor(root, facts, unit));
    }
    facts.addAll(_pubspecAssetFacts(root));
    return _dedupeSorted(facts);
  }
}

/// 사실을 중복 제거하고 정렬한다.
List<RuntimeFact> _dedupeSorted(List<RuntimeFact> facts) {
  final seen = <String>{};
  final unique = <RuntimeFact>[];
  for (final fact in facts) {
    final key =
        '${fact.id}\u0000${fact.detail}\u0000${fact.path}\u0000'
        '${fact.defaultValue}\u0000${fact.unverifiableReason}';
    if (seen.add(key)) unique.add(fact);
  }
  return unique..sort(compareRuntimeFacts);
}

/// `fromEnvironment`를 제공하는 타입 이름이다.
const _fromEnvironmentTypes = {'String', 'int', 'bool'};

/// 설정 파일로 취급하는 확장자다. 이 밖의 확장자는 경로 구분자가 있을 때만 본다.
const _configExtensions = {
  '.json',
  '.yaml',
  '.yml',
  '.toml',
  '.ini',
  '.cfg',
  '.conf',
  '.env',
  '.properties',
};

/// 리터럴 경로가 설정 의존성 후보인지 판정한다.
///
/// 설정 확장자이거나 경로 구분자를 포함하거나 `.env`류 이름이면 후보로 본다.
/// 그 밖의 단일 세그먼트 이름(`output.csv`)은 설정 의존성으로 단정하지 않는다 —
/// 확장자 없는 임시 파일·출력 파일을 설정으로 보고하면 오탐이 된다.
bool _looksLikeConfiguration(String value) {
  final normalized = value.replaceAll(r'\', '/');
  final base = normalized.split('/').last;
  final extension = p.posix.extension(base).toLowerCase();
  if (_configExtensions.contains(extension)) return true;
  if (base.startsWith('.env')) return true;
  return normalized.contains('/');
}

/// 한 컴파일 단위에서 사실을 모으는 방문자다.
final class _RuntimeFactVisitor extends RecursiveAstVisitor<void> {
  _RuntimeFactVisitor(this.root, this.facts, this.unit);

  final String root;
  final List<RuntimeFact> facts;
  final ResolvedUnitResult unit;

  void _report(
    AstNode node, {
    required RuntimeFactKind kind,
    required RuntimeFactChannel channel,
    required String name,
    required String detail,
    String? path,
    String? defaultValue,
    bool literal = true,
    String? unverifiableReason,
  }) {
    final location = unit.lineInfo.getLocation(node.offset);
    facts.add(
      RuntimeFact(
        kind: kind,
        channel: channel,
        name: name,
        source: projectIdForPath(unit.path, root),
        line: location.lineNumber,
        column: location.columnNumber,
        detail: detail,
        path: path,
        defaultValue: defaultValue,
        literal: literal,
        unverifiableReason: unverifiableReason,
      ),
    );
  }

  @override
  void visitImportDirective(ImportDirective node) {
    if (node.uri.stringValue == 'dart:mirrors') {
      _report(
        node,
        kind: RuntimeFactKind.dynamicLoad,
        channel: RuntimeFactChannel.reflection,
        name: 'dart:mirrors',
        detail: 'import "dart:mirrors"',
        unverifiableReason:
            'reflection-import: dart:mirrors can load and invoke code without '
            'a static reference',
      );
    }
    super.visitImportDirective(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _maybeFromEnvironment(node);
    _maybeProcessRun(node);
    _maybeIsolateSpawn(node);
    _maybeFunctionApply(node);
    _maybeDynamicLibraryOpen(node);
    _maybeUriParse(node);
    _maybeAssetRead(node);
    super.visitMethodInvocation(node);
  }

  /// `Platform.environment['X']`와 전체 맵 접근을 잡는다.
  @override
  void visitIndexExpression(IndexExpression node) {
    final target = node.target;
    if (target is PrefixedIdentifier &&
        target.identifier.name == 'environment' &&
        target.prefix.name == 'Platform' &&
        _matchesLibrary(target.prefix.element, 'dart:io')) {
      final index = node.index;
      if (index is SimpleStringLiteral) {
        _report(
          node,
          kind: RuntimeFactKind.env,
          channel: RuntimeFactChannel.processEnvironment,
          name: index.value,
          detail: 'Platform.environment["${index.value}"]',
        );
      } else {
        _report(
          node,
          kind: RuntimeFactKind.env,
          channel: RuntimeFactChannel.processEnvironment,
          name: runtimeComputedName,
          detail: 'Platform.environment[<computed>]',
          literal: false,
        );
      }
      return;
    }
    super.visitIndexExpression(node);
  }

  /// 인덱스 없이 환경 맵 전체를 읽는 경우다. 개별 키를 정적으로 알 수 없다.
  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.identifier.name == 'environment' &&
        node.prefix.name == 'Platform' &&
        _matchesLibrary(node.prefix.element, 'dart:io') &&
        node.parent is! IndexExpression) {
      _report(
        node,
        kind: RuntimeFactKind.env,
        channel: RuntimeFactChannel.processEnvironment,
        name: runtimeComputedName,
        detail: 'Platform.environment (whole map)',
        literal: false,
        unverifiableReason:
            'whole-environment-map: every key is read through the map, so no '
            'individual variable can be checked',
      );
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.name.lexeme;
    final element = node.constructorName.type.element;
    // `Image.asset(...)`·`DynamicLibrary.open(...)`은 정적 메서드가 아니라 명명
    // 생성자다. 해석이 끝난 코드에서는 analyzer가 이 형태로 돌려주므로, 이름이
    // 같은 정적 메서드만 보면 실제 Flutter 프로젝트·dart:ffi 호출을 통째로
    // 놓친다. 두 표현을 모두 같은 사실로 만든다.
    final constructor = node.constructorName.name?.name;
    if (constructor == null && (type == 'File' || type == 'Directory')) {
      _maybeFilePath(node, isDirectory: type == 'Directory', element: element);
    } else if (type == 'AssetImage') {
      _maybeAssetImage(node);
    } else if (type == 'Image' && constructor == 'asset') {
      _assetFact(node, 'Image.asset', _assetName(node));
    } else if (type == 'DynamicLibrary' && constructor == 'open') {
      _dynamicLibraryFact(node, node.argumentList.arguments);
    } else if (type == 'HttpClient' &&
        _matchesLibraries(element, _httpLibraries)) {
      _report(
        node,
        kind: RuntimeFactKind.external,
        channel: RuntimeFactChannel.externalUrl,
        name: 'HttpClient',
        detail: 'HttpClient()',
        unverifiableReason:
            'http-client: requests and endpoints are built at runtime, so '
            'verification cannot name a target',
      );
    } else if (_fromEnvironmentTypes.contains(type) &&
        constructor == 'fromEnvironment') {
      // 상수 문맥의 `int.fromEnvironment(...)`는 생성자 호출로 표현된다.
      _fromEnvironmentFact(node, type, node.argumentList.arguments);
    }
    super.visitInstanceCreationExpression(node);
  }

  /// 원격 목적지 자리에 놓인 http(s) 문자열 리터럴을 외부 자원으로 잡는다.
  ///
  /// 문자열이 http(s)로 시작하는지만 보면 `value.startsWith("https://")` 같은
  /// 비교·검증 코드와 상수 선언이 전부 외부 자원이 된다. 그래서 리터럴이
  /// 목적지를 받는 자리 — `Uri.parse(...)`의 인자이거나 알려진 네트워크 호출의
  /// 인자 — 에 있을 때만 보고한다. 런타임에 조립되거나 설정에서 읽는 목적지는
  /// 잡지 못하며, 그 공백은 `static-endpoints` limitation이 밝힌다.
  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    final value = node.value;
    if ((value.startsWith('http://') || value.startsWith('https://')) &&
        _isExternalDestination(node)) {
      _report(
        node,
        kind: RuntimeFactKind.external,
        channel: RuntimeFactChannel.externalUrl,
        name: value,
        detail: _literalDetail(node, value),
        unverifiableReason:
            'external-resource: verification performs no network access',
      );
    }
    super.visitSimpleStringLiteral(node);
  }

  /// 리터럴이 원격 목적지를 받는 인자 자리인지 확인한다.
  bool _isExternalDestination(SimpleStringLiteral node) {
    // `Isolate.spawnUri`의 대상은 로컬 프로그램 URI다(uri 채널이 따로 잡는다).
    if (_isIsolateSpawnUriArgument(node)) return false;
    final parent = node.parent;
    if (parent is! ArgumentList) return false;
    final owner = parent.parent;
    if (owner is! MethodInvocation) return false;
    return _isUriParse(owner) || _isNetworkCall(owner);
  }

  /// [node]가 `Uri.parse(...)` 호출인지 확인한다.
  bool _isUriParse(MethodInvocation node) {
    if (node.methodName.name != 'parse') return false;
    final target = node.target;
    return target is SimpleIdentifier &&
        target.name == 'Uri' &&
        _matchesLibrary(target.element, 'dart:core');
  }

  /// [node]가 원격 목적지를 인자로 받는 알려진 네트워크 API인지 확인한다.
  ///
  /// 해석된 코드는 라이브러리로 확인하고, 해석되지 않은 코드는 이름으로
  /// 확인한다([_matchesLibrary]와 같은 관용구).
  bool _isNetworkCall(MethodInvocation node) {
    final method = node.methodName.name;
    if (_httpClientRequestMethods.contains(method)) return true;
    final target = node.target;
    if (method == 'connect' &&
        target is SimpleIdentifier &&
        _connectTargets.contains(target.name)) {
      return true;
    }
    if (!_httpFunctions.contains(method)) return false;
    // `package:http`의 최상위 함수다(접두사 호출 `http.get(...)` 포함).
    if (target == null) return true;
    if (target is SimpleIdentifier && target.name == 'http') return true;
    final library = node.methodName.element?.library?.uri.toString();
    return library != null && library.startsWith('package:http/');
  }

  void _maybeFromEnvironment(MethodInvocation node) {
    if (node.methodName.name != 'fromEnvironment') return;
    final target = node.target;
    if (target is! SimpleIdentifier) return;
    if (!_fromEnvironmentTypes.contains(target.name)) return;
    _fromEnvironmentFact(node, target.name, node.argumentList.arguments);
  }

  /// `int.fromEnvironment` 계열을 하나의 사실로 만든다.
  ///
  /// 상수 문맥(`const port = int.fromEnvironment('PORT')`)에서 analyzer는 이
  /// 호출을 [MethodInvocation]이 아니라 [InstanceCreationExpression]
  /// (`int.fromEnvironment` 생성자 이름)으로 표현한다. 두 형태를 모두 받아
  /// 같은 사실로 만든다 — 한쪽만 보면 const 선언의 탐지가 통째로 빠진다.
  void _fromEnvironmentFact(
    AstNode node,
    String typeName,
    NodeList<Argument> arguments,
  ) {
    final key = arguments.isEmpty ? null : arguments.first;
    final String name;
    var literal = true;
    if (key is SimpleStringLiteral) {
      name = key.value;
    } else {
      name = runtimeComputedName;
      literal = false;
    }
    _report(
      node,
      kind: RuntimeFactKind.env,
      channel: RuntimeFactChannel.dartDefine,
      name: name,
      detail:
          'const $typeName.fromEnvironment('
          '${name == runtimeComputedName ? '<computed>' : '"$name"'})',
      defaultValue: _defaultValueOf(arguments),
      literal: literal,
    );
  }

  /// `defaultValue:` 명명 인자의 리터럴 값을 읽는다. 리터럴이 아니면 존재만 표시한다.
  String? _defaultValueOf(NodeList<Argument> arguments) {
    for (final argument in arguments) {
      if (argument is! NamedArgument) continue;
      if (argument.name.lexeme != 'defaultValue') continue;
      final value = argument.argumentExpression;
      if (value is SimpleStringLiteral) return value.value;
      if (value is IntegerLiteral) return value.value?.toString();
      if (value is BooleanLiteral) return value.value.toString();
      return '<computed>';
    }
    return null;
  }

  void _maybeProcessRun(MethodInvocation node) {
    // runSync는 같은 프로세스 실행 의존성이다(동기 변형만 빠지면 CLI가 외부
    // 도구를 부르는 흔한 경로가 통째로 보고에서 사라진다).
    if (node.methodName.name != 'run' &&
        node.methodName.name != 'runSync' &&
        node.methodName.name != 'start') {
      return;
    }
    final target = node.target;
    if (target is! SimpleIdentifier || target.name != 'Process') return;
    if (!_matchesLibrary(target.element, 'dart:io')) return;
    final arguments = node.argumentList.arguments;
    final executable = arguments.isEmpty ? null : arguments.first;
    if (executable is SimpleStringLiteral) {
      _report(
        node,
        kind: RuntimeFactKind.dynamicLoad,
        channel: RuntimeFactChannel.executable,
        name: executable.value,
        detail: 'Process.${node.methodName.name}("${executable.value}")',
        path: executable.value,
      );
      return;
    }
    _report(
      node,
      kind: RuntimeFactKind.dynamicLoad,
      channel: RuntimeFactChannel.executable,
      name: runtimeComputedName,
      detail: 'Process.${node.methodName.name}(<computed>)',
      literal: false,
    );
  }

  void _maybeIsolateSpawn(MethodInvocation node) {
    final target = node.target;
    if (target is! SimpleIdentifier || target.name != 'Isolate') return;
    if (!_matchesLibrary(target.element, 'dart:isolate')) return;
    final method = node.methodName.name;
    final arguments = node.argumentList.arguments;
    final entry = arguments.isEmpty ? null : arguments.first;
    if (method == 'spawnUri') {
      final uri = _stringLiteralOf(entry);
      if (uri == null) {
        _report(
          node,
          kind: RuntimeFactKind.dynamicLoad,
          channel: RuntimeFactChannel.uri,
          name: runtimeComputedName,
          detail: 'Isolate.spawnUri(<computed>)',
          literal: false,
        );
        return;
      }
      _report(
        node,
        kind: RuntimeFactKind.dynamicLoad,
        channel: RuntimeFactChannel.uri,
        name: uri,
        detail: 'Isolate.spawnUri(${_describeUriExpression(entry)})',
        path: uri,
      );
      return;
    }
    if (method == 'spawn') {
      final name = entry is SimpleIdentifier ? entry.name : runtimeComputedName;
      _report(
        node,
        kind: RuntimeFactKind.dynamicLoad,
        channel: RuntimeFactChannel.reflection,
        name: name,
        detail: 'Isolate.spawn($name)',
        literal: entry is SimpleIdentifier,
        unverifiableReason:
            'isolate-entry-point: the spawned isolate runs in-process code, so '
            'there is no external input to check',
      );
    }
  }

  void _maybeFunctionApply(MethodInvocation node) {
    if (node.methodName.name != 'apply') return;
    final target = node.target;
    if (target is! SimpleIdentifier || target.name != 'Function') return;
    if (!_matchesLibrary(target.element, 'dart:core')) return;
    final arguments = node.argumentList.arguments;
    final callee = arguments.isEmpty ? null : arguments.first;
    final name = callee is SimpleIdentifier ? callee.name : runtimeComputedName;
    _report(
      node,
      kind: RuntimeFactKind.dynamicLoad,
      channel: RuntimeFactChannel.reflection,
      name: name,
      detail: 'Function.apply($name, ...)',
      literal: callee is SimpleIdentifier,
      unverifiableReason:
          'dynamic-invocation: the callee is invoked through a function value, '
          'so no static reference names it',
    );
  }

  /// 정적 메서드 형태로 남은 `DynamicLibrary.open`을 잡는다(생성자 형태는
  /// [visitInstanceCreationExpression]이 같은 헬퍼로 보낸다).
  void _maybeDynamicLibraryOpen(MethodInvocation node) {
    if (node.methodName.name != 'open') return;
    final target = node.target;
    if (target is! SimpleIdentifier || target.name != 'DynamicLibrary') return;
    if (!_matchesLibrary(target.element, 'dart:ffi')) return;
    _dynamicLibraryFact(node, node.argumentList.arguments);
  }

  /// `DynamicLibrary.open` 인자 하나를 네이티브 라이브러리 사실로 만든다.
  ///
  /// 두 호출 형태(정적 메서드·factory 생성자)가 같은 관측을 내도록 본문을
  /// 한곳에 둔다.
  void _dynamicLibraryFact(AstNode node, NodeList<Argument> arguments) {
    final library = arguments.isEmpty ? null : arguments.first;
    if (library is! SimpleStringLiteral) {
      _report(
        node,
        kind: RuntimeFactKind.dynamicLoad,
        channel: RuntimeFactChannel.nativeLibrary,
        name: runtimeComputedName,
        detail: 'DynamicLibrary.open(<computed>)',
        literal: false,
      );
      return;
    }
    final value = library.value;
    final isPath =
        p.isAbsolute(value) || value.contains('/') || value.contains(r'\');
    _report(
      node,
      kind: RuntimeFactKind.dynamicLoad,
      channel: RuntimeFactChannel.nativeLibrary,
      name: value,
      detail: 'DynamicLibrary.open("$value")',
      path: isPath ? value : null,
      unverifiableReason: isPath
          ? null
          : 'bare-library-name: the dynamic loader resolves "$value" outside '
                'the package root',
    );
  }

  void _maybeUriParse(MethodInvocation node) {
    if (node.methodName.name != 'parse') return;
    final target = node.target;
    if (target is! SimpleIdentifier || target.name != 'Uri') return;
    if (!_matchesLibrary(target.element, 'dart:core')) return;
    final arguments = node.argumentList.arguments;
    if (arguments.isEmpty) return;
    // 리터럴 URL은 문자열 리터럴 규칙이 잡는다. 여기서는 정적으로 확정되지 않는
    // 대상만 남긴다(리터럴 로컬 경로까지 중복 보고하지 않는다).
    if (arguments.first is SimpleStringLiteral) return;
    _report(
      node,
      kind: RuntimeFactKind.dynamicLoad,
      channel: RuntimeFactChannel.uri,
      name: runtimeComputedName,
      detail: 'Uri.parse(<computed>)',
      literal: false,
    );
  }

  void _maybeAssetRead(MethodInvocation node) {
    final target = node.target;
    final method = node.methodName.name;
    // Flutter SDK를 해석하지 못하면 `AssetImage('...')`는 생성자 호출이 아니라
    // 이름 호출(target 없음)로 표현된다. 해석되는 프로젝트에서는
    // visitInstanceCreationExpression이 같은 사실을 만든다.
    if (target == null && method == 'AssetImage') {
      _assetFact(node, 'AssetImage', _assetName(node));
      return;
    }
    if (target is! SimpleIdentifier) return;
    if (target.name == 'rootBundle' &&
        (method == 'load' || method == 'loadString')) {
      _assetFact(node, 'rootBundle.$method', _assetName(node));
      return;
    }
    if (target.name == 'Image' && method == 'asset') {
      _assetFact(node, 'Image.asset', _assetName(node));
    }
  }

  /// 해석된 `AssetImage(...)` 생성자 호출을 에셋 사실로 만든다.
  void _maybeAssetImage(InstanceCreationExpression node) {
    _assetFact(node, 'AssetImage', _assetName(node));
  }

  /// 위치 인자에서 에셋 이름과 `package:` 한정 여부를 읽는다.
  ({String name, bool literal, String? package}) _assetName(AstNode node) {
    final arguments = switch (node) {
      MethodInvocation(:final argumentList) => argumentList.arguments,
      InstanceCreationExpression(:final argumentList) => argumentList.arguments,
      _ => const <Argument>[],
    };
    String? package;
    Argument? first;
    for (final argument in arguments) {
      if (argument is NamedArgument) {
        if (argument.name.lexeme == 'package' &&
            argument.argumentExpression is SimpleStringLiteral) {
          package = (argument.argumentExpression as SimpleStringLiteral).value;
        }
        continue;
      }
      first ??= argument;
    }
    if (first is SimpleStringLiteral) {
      return (name: first.value, literal: true, package: package);
    }
    return (name: runtimeComputedName, literal: false, package: package);
  }

  void _assetFact(
    AstNode node,
    String api,
    ({String name, bool literal, String? package}) asset,
  ) {
    _report(
      node,
      kind: RuntimeFactKind.asset,
      channel: RuntimeFactChannel.assetBundle,
      name: asset.name,
      detail: asset.package == null
          ? '$api("${asset.name}")'
          : '$api("${asset.name}", package: "${asset.package}")',
      path: asset.literal && asset.package == null ? asset.name : null,
      literal: asset.literal,
      unverifiableReason: asset.package == null
          ? null
          : 'package-asset: assets of another package are resolved by the '
                'Flutter tool, not by this package root',
    );
  }

  void _maybeFilePath(
    InstanceCreationExpression node, {
    required bool isDirectory,
    required Element? element,
  }) {
    if (!_matchesLibrary(element, 'dart:io')) return;
    final arguments = node.argumentList.arguments;
    final type = isDirectory ? 'Directory' : 'File';
    final value = arguments.isEmpty ? null : arguments.first;
    if (value is! SimpleStringLiteral) {
      _report(
        node,
        kind: RuntimeFactKind.config,
        channel: isDirectory
            ? RuntimeFactChannel.directoryPath
            : RuntimeFactChannel.filePath,
        name: runtimeComputedName,
        detail: '$type(<computed>)',
        literal: false,
      );
      return;
    }
    if (!_looksLikeConfiguration(value.value)) return;
    _report(
      node,
      kind: RuntimeFactKind.config,
      channel: isDirectory
          ? RuntimeFactChannel.directoryPath
          : RuntimeFactChannel.filePath,
      name: value.value,
      detail: '$type("${value.value}")',
      path: value.value,
    );
  }

  /// `Uri.parse('...')`·`Isolate.spawnUri(...)` 인자의 문자열 리터럴을 꺼낸다.
  String? _stringLiteralOf(Argument? expression) {
    if (expression is SimpleStringLiteral) return expression.value;
    if (expression is MethodInvocation &&
        expression.methodName.name == 'parse' &&
        expression.argumentList.arguments.firstOrNull is SimpleStringLiteral) {
      return (expression.argumentList.arguments.first as SimpleStringLiteral)
          .value;
    }
    return null;
  }

  String _describeUriExpression(Argument? expression) {
    final value = _stringLiteralOf(expression);
    if (expression is MethodInvocation) return 'Uri.parse("$value")';
    return '"$value"';
  }

  /// 리터럴이 `Isolate.spawnUri`의 대상인지 확인한다(외부 자원 중복 보고 방지).
  bool _isIsolateSpawnUriArgument(SimpleStringLiteral node) {
    final parent = node.parent;
    if (parent is ArgumentList) {
      final owner = parent.parent;
      if (owner is MethodInvocation &&
          owner.methodName.name == 'spawnUri' &&
          owner.target is SimpleIdentifier &&
          (owner.target! as SimpleIdentifier).name == 'Isolate') {
        return true;
      }
    }
    // Uri.parse(...)의 인자이면서 그 호출이 spawnUri 인자인 경우도 같다.
    if (parent is ArgumentList) {
      final owner = parent.parent;
      if (owner is MethodInvocation && owner.methodName.name == 'parse') {
        final grandparent = owner.parent;
        if (grandparent is ArgumentList) {
          final caller = grandparent.parent;
          if (caller is MethodInvocation &&
              caller.methodName.name == 'spawnUri' &&
              caller.target is SimpleIdentifier &&
              (caller.target! as SimpleIdentifier).name == 'Isolate') {
            return true;
          }
        }
      }
    }
    return false;
  }

  /// 리터럴이 놓인 즉시 문맥을 사람이 읽는 문구로 만든다.
  String _literalDetail(SimpleStringLiteral node, String value) {
    final parent = node.parent;
    if (parent is ArgumentList) {
      final owner = parent.parent;
      if (owner is MethodInvocation) {
        final target = owner.target;
        final prefix = target is SimpleIdentifier ? '${target.name}.' : '';
        return '$prefix${owner.methodName.name}("$value")';
      }
      if (owner is InstanceCreationExpression) {
        return '${owner.constructorName.type.name.lexeme}("$value")';
      }
    }
    return 'string literal "$value"';
  }
}

/// 해석된 element가 [uri] 라이브러리인지 확인한다.
///
/// 해석되지 않은 코드(element 없음)는 이름만으로 판단한다 — Flutter SDK 없이
/// 분석할 때 `rootBundle`·`Image.asset` 같은 이름 기반 탐지를 유지하기 위해서다.
/// 해석된 element가 다른 라이브러리면 사용자 정의 동명 클래스이므로 건너뛴다.
bool _matchesLibrary(Element? element, String uri) {
  final library = element?.library?.uri.toString();
  if (library == null) return true;
  return library == uri;
}

/// [element]의 라이브러리가 [uris] 중 하나인지 확인한다.
///
/// `HttpClient`처럼 SDK가 다른 라이브러리에 정의하고 재수출하는 선언은 판정
/// 대상 라이브러리가 하나가 아니다(dart:io로만 비교하면 영원히 걸리지 않는다).
bool _matchesLibraries(Element? element, Set<String> uris) {
  final library = element?.library?.uri.toString();
  if (library == null) return true;
  return uris.contains(library);
}

/// `HttpClient`가 정의된 SDK 라이브러리다. dart:io는 dart:_http를 재수출한다.
const _httpLibraries = {'dart:io', 'dart:_http'};

/// `HttpClient`에서 요청을 시작하며 목적지 URI를 인자로 받는 메서드다.
const _httpClientRequestMethods = {'getUrl', 'postUrl', 'openUrl'};

/// `package:http`가 노출하는 요청 함수다(목적지 URL이 인자다).
const _httpFunctions = {'get', 'post', 'put', 'delete', 'patch', 'head'};

/// 목적지를 인자로 받는 소켓·웹소켓 연결 대상이다.
const _connectTargets = {'WebSocket', 'Socket', 'RawSocket', 'SecureSocket'};

/// `pubspec.yaml`의 `flutter.assets` 선언을 에셋 사실로 바꾼다.
///
/// 선언 자체가 번들 대상 목록이므로, 코드에서 참조하지 않는 에셋도 검증 대상이다.
List<RuntimeFact> _pubspecAssetFacts(String root) {
  final file = File(p.join(root, 'pubspec.yaml'));
  if (!file.existsSync()) return const [];
  final YamlNode document;
  try {
    document = loadYamlNode(readConfigurationSync(file));
  } on YamlException {
    return const [];
  }
  if (document is! YamlMap) return const [];
  final flutter = document['flutter'];
  if (flutter is! YamlMap) return const [];
  final assets = flutter['assets'];
  if (assets is! YamlList) return const [];
  final facts = <RuntimeFact>[];
  for (final node in assets.nodes) {
    if (node is! YamlScalar || node.value is! String) continue;
    final value = (node.value as String).trim();
    if (value.isEmpty) continue;
    final isDirectory = value.endsWith('/');
    facts.add(
      RuntimeFact(
        kind: RuntimeFactKind.asset,
        channel: isDirectory
            ? RuntimeFactChannel.directoryPath
            : RuntimeFactChannel.assetBundle,
        name: value,
        source: 'project:pubspec.yaml',
        line: node.span.start.line + 1,
        column: node.span.start.column + 1,
        detail: 'pubspec.yaml flutter.assets declaration',
        path: value,
      ),
    );
  }
  return facts;
}
