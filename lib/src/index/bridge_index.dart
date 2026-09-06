import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

/// Flutter 플랫폼 채널 구문 사실과 실제 동적 이름 개수다.
final class BridgeIndexResult {
  /// 결정적으로 정렬된 교환 사실을 만든다.
  const BridgeIndexResult(this.facts, this.limitations);

  /// GRAPH-EXCHANGE fact 객체다.
  final List<Map<String, Object?>> facts;

  /// 추출 중 조인할 수 없었던 사실의 계수다.
  final List<String> limitations;
}

/// [rootPath]의 Dart 파일에서 Flutter MethodChannel 사실을 추출한다.
BridgeIndexResult indexBridges(String rootPath) {
  final root = Directory(
    Directory(rootPath).absolute.resolveSymbolicLinksSync(),
  );
  final facts = <Map<String, Object?>>[];
  var dynamicMethodNames = 0;
  var unresolvedReceiverInvocations = 0;
  var invalidMethodInvocations = 0;
  var patternVariableScopes = 0;
  var unscannedEventChannels = 0;
  var unscannedBasicMessageChannels = 0;
  var conditionalFlutterImports = 0;
  var flutterServicesReexports = 0;
  var parseErrorFiles = 0;
  for (final entity in _dartFiles(root)) {
    final relative = p.posix.joinAll(
      p.relative(entity.path, from: root.path).split(p.separator),
    );
    _rejectControlCharacters(relative);
    final source = entity.readAsStringSync();
    final parsed = parseString(
      content: source,
      path: entity.path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) parseErrorFiles++;
    if (_hasFlutterServicesReexport(parsed.unit)) {
      flutterServicesReexports++;
    }
    if (_hasConditionalFlutterServicesImport(parsed.unit)) {
      conditionalFlutterImports++;
      continue;
    }
    final flutterPrefixes = {
      for (final type in _flutterChannelTypes)
        type: _flutterServicesPrefixes(parsed.unit, type),
    };
    if (flutterPrefixes.values.every((prefixes) => prefixes.isEmpty)) continue;

    final constants = _topLevelStringConstants(parsed.unit);
    final rootDeclaredNames = _topLevelDeclaredNames(parsed.unit);
    final rootChannels = _topLevelChannels(
      parsed.unit,
      constants,
      flutterPrefixes,
      rootDeclaredNames,
    );
    final visitor = _BridgeVisitor(
      relative,
      source,
      parsed.lineInfo,
      flutterPrefixes,
      rootDeclaredNames,
      constants,
      rootChannels,
    );
    parsed.unit.accept(visitor);
    facts.addAll(visitor.facts);
    dynamicMethodNames += visitor.dynamicMethodNames;
    unresolvedReceiverInvocations += visitor.unresolvedReceiverInvocations;
    invalidMethodInvocations += visitor.invalidMethodInvocations;
    patternVariableScopes += visitor.patternVariableScopes;
    unscannedEventChannels += visitor.unscannedEventChannels;
    unscannedBasicMessageChannels += visitor.unscannedBasicMessageChannels;
  }
  facts.sort(_compareFacts);
  final dynamicChannels = facts
      .where((fact) => fact['kind'] == 'channel-create')
      .where((fact) => fact['dynamic'] == true)
      .length;
  return BridgeIndexResult(facts, [
    if (facts.any(
      (fact) => fact['kind'] == 'method-invoke' && !fact.containsKey('symbol'),
    ))
      'missing-caller-symbols: some invocations have source locations but no supported enclosing declaration name',
    if (dynamicChannels > 0)
      'dynamic-channel-names: $dynamicChannels channel constructors use a non-literal name',
    if (dynamicMethodNames > 0)
      'dynamic-method-names: $dynamicMethodNames method invocations use a non-literal name',
    if (unresolvedReceiverInvocations > 0)
      'unresolved-receiver-invocations: $unresolvedReceiverInvocations '
          '${unresolvedReceiverInvocations == 1 ? 'invokeMethod call has' : 'invokeMethod calls have'} '
          'an unresolved receiver',
    if (invalidMethodInvocations > 0)
      'invalid-method-invocations: $invalidMethodInvocations '
          '${invalidMethodInvocations == 1 ? 'invocation has' : 'invocations have'} '
          'no method name',
    if (patternVariableScopes > 0)
      'pattern-variable-scopes: $patternVariableScopes '
          '${patternVariableScopes == 1 ? 'pattern binding was' : 'pattern bindings were'} '
          'resolved conservatively',
    if (unscannedEventChannels > 0)
      'unscanned-event-channels: $unscannedEventChannels EventChannel constructor',
    if (unscannedBasicMessageChannels > 0)
      'unscanned-basic-message-channels: $unscannedBasicMessageChannels BasicMessageChannel constructor',
    if (conditionalFlutterImports > 0)
      'conditional-flutter-services-imports: $conditionalFlutterImports Dart source '
          '${conditionalFlutterImports == 1 ? 'file has' : 'files have'} '
          'configuration-dependent provenance',
    if (flutterServicesReexports > 0)
      'flutter-services-reexports: $flutterServicesReexports Dart source '
          '${flutterServicesReexports == 1 ? 'file re-exports' : 'files re-export'} '
          'Flutter services',
    if (parseErrorFiles > 0)
      'parse-errors: $parseErrorFiles Dart source file(s) could not be parsed completely',
  ]);
}

int _compareFacts(Map<String, Object?> a, Map<String, Object?> b) {
  final al = a['location']! as Map<String, Object?>;
  final bl = b['location']! as Map<String, Object?>;
  final pathOrder = (al['path']! as String).compareTo(bl['path']! as String);
  if (pathOrder != 0) return pathOrder;
  final lineOrder = (al['line']! as int).compareTo(bl['line']! as int);
  if (lineOrder != 0) return lineOrder;
  final columnOrder = (al['column']! as int).compareTo(bl['column']! as int);
  if (columnOrder != 0) return columnOrder;
  final kindOrder = (a['kind']! as String).compareTo(b['kind']! as String);
  if (kindOrder != 0) return kindOrder;
  return '${a['channel']}:${a['method']}'.compareTo(
    '${b['channel']}:${b['method']}',
  );
}

Iterable<File> _dartFiles(Directory directory) =>
    _dartFilesIn(directory, <String>{});

/// [directory] 아래의 Dart 소스를 심볼릭 링크까지 따라가며 돌려준다.
///
/// `followLinks: false` 목록에서 심볼릭 링크는 `Link`로 나와 `File`·`Directory`
/// 분기에 걸리지 않는다. 링크된 소스도 analyzer가 분석하는 실제 입력이라
/// 빠뜨리면 그 파일의 채널 사실이 통째로 누락된다.
///
/// [visitedLinkTargets]는 이미 따라간 디렉터리 링크의 실제 경로이며 링크 순환에서
/// 무한 재귀하지 않게 한다.
Iterable<File> _dartFilesIn(
  Directory directory,
  Set<String> visitedLinkTargets,
) sync* {
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is Directory) {
      if (_excludedDirectories.contains(p.basename(entity.path))) continue;
      yield* _dartFilesIn(entity, visitedLinkTargets);
    } else if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    } else if (entity is Link) {
      // typeSync는 링크를 따라가므로 끊어진 링크는 notFound가 되어 제외된다.
      final type = FileSystemEntity.typeSync(entity.path);
      if (type == FileSystemEntityType.file && entity.path.endsWith('.dart')) {
        yield File(entity.path);
      } else if (type == FileSystemEntityType.directory &&
          !_excludedDirectories.contains(p.basename(entity.path)) &&
          visitedLinkTargets.add(entity.resolveSymbolicLinksSync())) {
        yield* _dartFilesIn(Directory(entity.path), visitedLinkTargets);
      }
    }
  }
}

final class _BridgeVisitor extends RecursiveAstVisitor<void> {
  _BridgeVisitor(
    this.path,
    this.source,
    this.lineInfo,
    this.flutterPrefixes,
    Set<String> rootDeclaredNames,
    Map<String, String> rootConstants,
    Map<String, _BridgeName> rootChannels,
  ) : _declaredNameScopes = [rootDeclaredNames],
      _stringConstantScopes = [rootConstants],
      _channelScopes = [rootChannels];

  final String path;
  final String source;
  final LineInfo lineInfo;
  final Map<String, Set<String?>> flutterPrefixes;
  final List<Map<String, _BridgeName>> _channelScopes;
  final List<Map<String, String>> _stringConstantScopes;
  final List<Set<String>> _declaredNameScopes;
  final facts = <Map<String, Object?>>[];
  var dynamicMethodNames = 0;
  var unresolvedReceiverInvocations = 0;
  var invalidMethodInvocations = 0;
  var patternVariableScopes = 0;
  var unscannedEventChannels = 0;
  var unscannedBasicMessageChannels = 0;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _pushScope();
    try {
      super.visitClassDeclaration(node);
    } finally {
      _popScope();
    }
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    _visitDeclarationScope(() => super.visitMixinDeclaration(node));
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    _visitDeclarationScope(() => super.visitEnumDeclaration(node));
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    _visitDeclarationScope(() => super.visitExtensionDeclaration(node));
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    _visitDeclarationScope(() => super.visitExtensionTypeDeclaration(node));
  }

  void _visitDeclarationScope(void Function() visitChildren) {
    _pushScope();
    try {
      visitChildren();
    } finally {
      _popScope();
    }
  }

  @override
  void visitBlock(Block node) {
    _pushScope();
    try {
      for (final statement in node.statements) {
        if (statement is FunctionDeclarationStatement) {
          _declare(statement.functionDeclaration.name.lexeme);
        }
      }
      super.visitBlock(node);
    } finally {
      _popScope();
    }
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _declare(node.name.lexeme);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitCatchClause(CatchClause node) {
    _pushScope();
    try {
      final exceptionName = node.exceptionParameter?.name.lexeme;
      final stackTraceName = node.stackTraceParameter?.name.lexeme;
      if (exceptionName != null) _declare(exceptionName);
      if (stackTraceName != null) _declare(stackTraceName);
      super.visitCatchClause(node);
    } finally {
      _popScope();
    }
  }

  @override
  void visitForStatement(ForStatement node) {
    _pushScope();
    try {
      final parts = node.forLoopParts;
      if (parts is ForEachPartsWithDeclaration) {
        _declare(parts.loopVariable.name.lexeme);
      }
      super.visitForStatement(node);
    } finally {
      _popScope();
    }
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    _declare(node.name.lexeme);
    patternVariableScopes++;
    super.visitDeclaredVariablePattern(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _visitParameterScope(
      node.parameters,
      () => super.visitMethodDeclaration(node),
    );
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    _visitParameterScope(
      node.parameters,
      () => super.visitConstructorDeclaration(node),
    );
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    _visitParameterScope(
      node.parameters,
      () => super.visitFunctionExpression(node),
    );
  }

  void _visitParameterScope(
    FormalParameterList? parameters,
    void Function() visitChildren,
  ) {
    _pushScope();
    try {
      for (final parameter in parameters?.parameters ?? const []) {
        final name = parameter.name?.lexeme;
        if (name != null) _declare(name);
      }
      visitChildren();
    } finally {
      _popScope();
    }
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _declare(node.name.lexeme);
    _recordStringConstant(node);
    final channel = _channelCreatedBy(node.initializer);
    if (channel != null) _channelScopes.last[node.name.lexeme] = channel;
    super.visitVariableDeclaration(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final left = node.leftHandSide;
    if (node.operator.lexeme == '=' && left is SimpleIdentifier) {
      _assignChannel(left.name, _channelCreatedBy(node.rightHandSide));
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final type = node.methodName.name;
    if (_isUnresolvedFlutterConstructor(node, type)) {
      _recordChannelConstruction(node, type, node.argumentList);
    } else if (_methodInvocationNames.contains(type)) {
      _recordMethodInvocation(node);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.name.lexeme;
    if (_isFlutterConstructor(node, type)) {
      _recordChannelConstruction(node, type, node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  void _recordStringConstant(VariableDeclaration declaration) {
    final initializer = declaration.initializer;
    if (!declaration.isConst || initializer is! SimpleStringLiteral) return;
    _stringConstantScopes.last[declaration.name.lexeme] = initializer.value;
  }

  void _recordChannelConstruction(
    AstNode node,
    String type,
    ArgumentList arguments,
  ) {
    if (type == 'EventChannel') {
      unscannedEventChannels++;
      return;
    }
    if (type == 'BasicMessageChannel') {
      unscannedBasicMessageChannels++;
      return;
    }
    if (type != 'MethodChannel' || arguments.arguments.isEmpty) return;
    final channel = _bridgeName(arguments.arguments.first);
    facts.add(
      _fact(
        node,
        node.offset,
        'channel-create',
        channel.value,
        dynamic: channel.dynamic,
      ),
    );
  }

  void _recordMethodInvocation(MethodInvocation node) {
    final target = node.realTarget;
    final arguments = node.argumentList.arguments;
    if (arguments.isEmpty) {
      invalidMethodInvocations++;
      return;
    }
    if (target == null) {
      unresolvedReceiverInvocations++;
      return;
    }
    final channel = target is SimpleIdentifier
        ? _channel(named: target.name)
        : _channelCreatedBy(target);
    if (channel == null) {
      unresolvedReceiverInvocations++;
      return;
    }
    final method = _bridgeName(arguments.first);
    if (method.dynamic) dynamicMethodNames++;
    facts.add(
      _fact(
        node,
        node.methodName.offset,
        'method-invoke',
        channel.value,
        method: method.value,
        dynamic: channel.dynamic || method.dynamic,
      ),
    );
  }

  _BridgeName? _channelCreatedBy(AstNode? expression) {
    if (expression is MethodInvocation &&
        _isUnresolvedFlutterConstructor(
          expression,
          expression.methodName.name,
        ) &&
        expression.methodName.name == 'MethodChannel') {
      return _firstBridgeName(expression.argumentList);
    }
    if (expression is InstanceCreationExpression &&
        expression.constructorName.type.name.lexeme == 'MethodChannel' &&
        _isFlutterConstructor(expression, 'MethodChannel')) {
      return _firstBridgeName(expression.argumentList);
    }
    return null;
  }

  _BridgeName? _firstBridgeName(ArgumentList arguments) =>
      arguments.arguments.isEmpty
      ? null
      : _bridgeName(arguments.arguments.first);

  bool _isFlutterConstructor(InstanceCreationExpression node, String type) =>
      _isFlutterPrefix(
        type,
        node.constructorName.type.importPrefix?.name.lexeme,
      );

  bool _isUnresolvedFlutterConstructor(MethodInvocation node, String type) =>
      node.target == null && _isFlutterPrefix(type, null) ||
      node.target is SimpleIdentifier &&
          _isFlutterPrefix(type, (node.target! as SimpleIdentifier).name);

  bool _isFlutterPrefix(String type, String? prefix) =>
      flutterPrefixes[type]?.contains(prefix) == true &&
      (prefix == null ? !_isDeclared(type) : !_isDeclared(prefix));

  _BridgeName _bridgeName(AstNode node) {
    if (node is SimpleStringLiteral) {
      return (value: node.value, dynamic: false);
    }
    if (node is SimpleIdentifier) {
      final value = _stringConstant(named: node.name);
      if (value != null) return (value: value, dynamic: false);
    }
    return (value: node.toSource(), dynamic: true);
  }

  Map<String, Object?> _fact(
    AstNode node,
    int offset,
    String kind,
    String channel, {
    String? method,
    required bool dynamic,
  }) {
    _rejectControlCharacters(path);
    _rejectControlCharacters(channel);
    if (method != null) _rejectControlCharacters(method);
    final location = lineInfo.getLocation(offset);
    final lineOffset = lineInfo.getOffsetOfLine(location.lineNumber - 1);
    final utf8Column =
        utf8.encode(source.substring(lineOffset, offset)).length + 1;
    final symbol = _enclosingSymbol(node);
    return {
      'symbol': ?symbol,
      'kind': kind,
      'channel': channel,
      'method': ?method,
      'dynamic': dynamic,
      'location': {
        'path': path,
        'line': location.lineNumber,
        'column': utf8Column,
      },
    };
  }

  void _pushScope() {
    _channelScopes.add({});
    _stringConstantScopes.add({});
    _declaredNameScopes.add({});
  }

  void _popScope() {
    _channelScopes.removeLast();
    _stringConstantScopes.removeLast();
    _declaredNameScopes.removeLast();
  }

  void _declare(String name) => _declaredNameScopes.last.add(name);

  bool _isDeclared(String name) =>
      _declaredNameScopes.reversed.any((scope) => scope.contains(name));

  void _assignChannel(String name, _BridgeName? channel) {
    for (var index = _channelScopes.length - 1; index >= 0; index--) {
      if (!_declaredNameScopes[index].contains(name)) continue;
      if (channel == null) {
        _channelScopes[index].remove(name);
      } else {
        _channelScopes[index][name] = channel;
      }
      return;
    }
  }

  _BridgeName? _channel({required String named}) {
    for (var index = _channelScopes.length - 1; index >= 0; index--) {
      final value = _channelScopes[index][named];
      if (value != null) return value;
      if (_declaredNameScopes[index].contains(named)) return null;
    }
    return null;
  }

  String? _stringConstant({required String named}) {
    for (var index = _stringConstantScopes.length - 1; index >= 0; index--) {
      final value = _stringConstantScopes[index][named];
      if (value != null) return value;
      if (_declaredNameScopes[index].contains(named)) return null;
    }
    return null;
  }
}

Map<String, Object?>? _enclosingSymbol(AstNode node) {
  final names = <String>[];
  for (
    AstNode? current = node.parent;
    current != null;
    current = current.parent
  ) {
    final name = switch (current) {
      MethodDeclaration() => current.name.lexeme,
      FunctionDeclaration() => current.name.lexeme,
      ClassDeclaration() => current.namePart.typeName.lexeme,
      MixinDeclaration() => current.name.lexeme,
      EnumDeclaration() => current.namePart.typeName.lexeme,
      _ => null,
    };
    if (name != null) names.add(name);
    if (current is ExtensionDeclaration ||
        current is ExtensionTypeDeclaration ||
        current is ConstructorDeclaration) {
      return null;
    }
  }
  if (names.isEmpty) return null;
  return {'qualifiedName': names.reversed.join('.')};
}

Map<String, _BridgeName> _topLevelChannels(
  CompilationUnit unit,
  Map<String, String> strings,
  Map<String, Set<String?>> flutterPrefixes,
  Set<String> declaredNames,
) {
  final channels = <String, _BridgeName>{};
  for (final declaration
      in unit.declarations.whereType<TopLevelVariableDeclaration>()) {
    for (final variable in declaration.variables.variables) {
      final initializer = variable.initializer;
      final ArgumentList? arguments;
      if (initializer is MethodInvocation &&
          initializer.methodName.name == 'MethodChannel' &&
          _matchesPrefix(
            initializer.target,
            'MethodChannel',
            flutterPrefixes,
            declaredNames,
          )) {
        arguments = initializer.argumentList;
      } else if (initializer is InstanceCreationExpression &&
          initializer.constructorName.type.name.lexeme == 'MethodChannel' &&
          _matchesPrefix(
            initializer.constructorName.type.importPrefix,
            'MethodChannel',
            flutterPrefixes,
            declaredNames,
          )) {
        arguments = initializer.argumentList;
      } else {
        arguments = null;
      }
      final first = arguments?.arguments.firstOrNull;
      if (first != null) {
        channels[variable.name.lexeme] = _bridgeName(first, strings);
      }
    }
  }
  return channels;
}

bool _matchesPrefix(
  AstNode? target,
  String type,
  Map<String, Set<String?>> flutterPrefixes,
  Set<String> declaredNames,
) {
  final prefix = target is SimpleIdentifier ? target.name : null;
  return flutterPrefixes[type]?.contains(prefix) == true &&
      (prefix == null
          ? !declaredNames.contains(type)
          : !declaredNames.contains(prefix));
}

_BridgeName _bridgeName(AstNode node, Map<String, String> strings) {
  if (node is SimpleStringLiteral) return (value: node.value, dynamic: false);
  if (node is SimpleIdentifier && strings[node.name] != null) {
    return (value: strings[node.name]!, dynamic: false);
  }
  return (value: node.toSource(), dynamic: true);
}

Set<String> _topLevelDeclaredNames(CompilationUnit unit) {
  final names = <String>{};
  for (final declaration in unit.declarations) {
    if (declaration is FunctionDeclaration) {
      names.add(declaration.name.lexeme);
    } else if (declaration is ClassDeclaration) {
      names.add(declaration.namePart.typeName.lexeme);
    } else if (declaration is MixinDeclaration) {
      names.add(declaration.name.lexeme);
    } else if (declaration is EnumDeclaration) {
      names.add(declaration.namePart.typeName.lexeme);
    } else if (declaration is ExtensionDeclaration) {
      final name = declaration.name?.lexeme;
      if (name != null) names.add(name);
    } else if (declaration is ExtensionTypeDeclaration) {
      names.add(declaration.namePart.typeName.lexeme);
    } else if (declaration is TypeAlias) {
      names.add(declaration.name.lexeme);
    } else if (declaration is TopLevelVariableDeclaration) {
      names.addAll(
        declaration.variables.variables.map((variable) => variable.name.lexeme),
      );
    }
  }
  return names;
}

Map<String, String> _topLevelStringConstants(CompilationUnit unit) {
  final strings = <String, String>{};
  for (final declaration
      in unit.declarations.whereType<TopLevelVariableDeclaration>()) {
    for (final variable in declaration.variables.variables) {
      final value = variable.initializer;
      if (variable.isConst && value is SimpleStringLiteral) {
        strings[variable.name.lexeme] = value.value;
      }
    }
  }
  return strings;
}

Set<String?> _flutterServicesPrefixes(CompilationUnit unit, String type) => unit
    .directives
    .whereType<ImportDirective>()
    .where(
      (directive) =>
          directive.uri.stringValue == 'package:flutter/services.dart' &&
          _exposesName(directive.combinators, type),
    )
    .map((directive) => directive.prefix?.name)
    .toSet();

bool _exposesName(NodeList<Combinator> combinators, String name) {
  final hidden = combinators.whereType<HideCombinator>().any(
    (combinator) =>
        combinator.hiddenNames.any((hiddenName) => hiddenName.name == name),
  );
  if (hidden) return false;
  final shown = combinators.whereType<ShowCombinator>();
  return shown.isEmpty ||
      shown.any(
        (combinator) =>
            combinator.shownNames.any((shownName) => shownName.name == name),
      );
}

bool _hasConditionalFlutterServicesImport(CompilationUnit unit) =>
    unit.directives.whereType<ImportDirective>().any(
      (directive) =>
          directive.configurations.isNotEmpty &&
          (directive.uri.stringValue == _flutterServicesUri ||
              directive.configurations.any(
                (configuration) =>
                    configuration.uri.stringValue == _flutterServicesUri,
              )),
    );

bool _hasFlutterServicesReexport(CompilationUnit unit) =>
    unit.directives.whereType<ExportDirective>().any(
      (directive) =>
          directive.uri.stringValue == _flutterServicesUri ||
          directive.configurations.any(
            (configuration) =>
                configuration.uri.stringValue == _flutterServicesUri,
          ),
    );

const _flutterChannelTypes = {
  'MethodChannel',
  'EventChannel',
  'BasicMessageChannel',
};
const _methodInvocationNames = {
  'invokeMethod',
  'invokeListMethod',
  'invokeMapMethod',
};
const _flutterServicesUri = 'package:flutter/services.dart';
const _excludedDirectories = {'.dart_tool', '.git', 'build'};

void _rejectControlCharacters(String value) {
  if (value.trim().isEmpty ||
      RegExp(r'[\x00-\x1F\x7F-\x9F\u2028\u2029]').hasMatch(value)) {
    throw const FormatException(
      'bridge facts cannot contain empty values or control characters',
    );
  }
}

typedef _BridgeName = ({String value, bool dynamic});
