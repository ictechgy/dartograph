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

/// [rootPath]의 Dart 파일에서 Flutter 채널 사실을 추출한다.
BridgeIndexResult indexBridges(String rootPath) {
  final root = Directory(
    Directory(rootPath).absolute.resolveSymbolicLinksSync(),
  );
  final facts = <Map<String, Object?>>[];
  var dynamicMethodNames = 0;
  var unattributedMethods = 0;
  var parseErrorFiles = 0;
  for (final entity in _dartFiles(root)) {
    final relative = p.posix.joinAll(
      p.relative(entity.path, from: root.path).split(p.separator),
    );
    _rejectControlCharacters(relative);
    final parsed = parseString(
      content: entity.readAsStringSync(),
      path: entity.path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) parseErrorFiles++;
    final constants = _StringConstantVisitor();
    parsed.unit.accept(constants);
    final declarations = _ChannelDeclarationVisitor(constants.strings);
    parsed.unit.accept(declarations);
    final visitor = _BridgeVisitor(
      relative,
      parsed.lineInfo,
      constants.strings,
      declarations.channels,
    );
    parsed.unit.accept(visitor);
    facts.addAll(visitor.facts);
    dynamicMethodNames += visitor.dynamicMethodNames;
    unattributedMethods += visitor.unattributedMethods;
  }
  facts.sort((a, b) {
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
  });
  final channels = facts
      .where((f) => f['kind'] == 'channel-create' && f['dynamic'] == true)
      .length;
  return BridgeIndexResult(facts, [
    if (channels > 0)
      'dynamic-channel-names: $channels channel constructors use a non-literal name',
    if (dynamicMethodNames > 0)
      'dynamic-method-names: $dynamicMethodNames method invocations use a non-literal name',
    if (unattributedMethods > 0)
      'unattributed-method-invocations: $unattributedMethods invocation(s) could not be assigned to a channel',
    if (parseErrorFiles > 0)
      'parse-errors: $parseErrorFiles Dart source file(s) could not be parsed completely',
  ]);
}

Iterable<File> _dartFiles(Directory directory) sync* {
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is Directory) {
      if (_excludedDirectories.contains(p.basename(entity.path))) continue;
      yield* _dartFiles(entity);
    } else if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    }
  }
}

final class _StringConstantVisitor extends RecursiveAstVisitor<void> {
  final strings = <String, String>{};

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final value = node.initializer;
    if (node.isConst && value is SimpleStringLiteral) {
      strings[node.name.lexeme] = value.value;
    }
    super.visitVariableDeclaration(node);
  }
}

final class _ChannelDeclarationVisitor extends RecursiveAstVisitor<void> {
  _ChannelDeclarationVisitor(this.strings);

  final Map<String, String> strings;
  final channels = <String, ({String value, bool dynamic})>{};

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final value = node.initializer;
    if (value is MethodInvocation &&
        _channelTypes.contains(value.methodName.name)) {
      final name = _bridgeName(
        value.argumentList.arguments.firstOrNull,
        strings,
      );
      channels[node.name.lexeme] = name;
    } else if (value is InstanceCreationExpression &&
        _channelTypes.contains(value.constructorName.type.name.lexeme)) {
      final name = _bridgeName(
        value.argumentList.arguments.firstOrNull,
        strings,
      );
      channels[node.name.lexeme] = name;
    }
    super.visitVariableDeclaration(node);
  }
}

final class _BridgeVisitor extends RecursiveAstVisitor<void> {
  _BridgeVisitor(this.path, this.lineInfo, this.strings, this.channels);

  final String path;
  final LineInfo lineInfo;
  final Map<String, String> strings;
  final Map<String, ({String value, bool dynamic})> channels;
  final facts = <Map<String, Object?>>[];
  var dynamicMethodNames = 0;
  var unattributedMethods = 0;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_channelTypes.contains(node.methodName.name) && node.target == null) {
      final name = _bridgeName(
        node.argumentList.arguments.firstOrNull,
        strings,
      );
      facts.add(
        _fact(node.offset, 'channel-create', name.value, dynamic: name.dynamic),
      );
    } else if (node.methodName.name == 'invokeMethod' &&
        node.argumentList.arguments.isNotEmpty) {
      final target = node.target;
      final channel = target is SimpleIdentifier ? channels[target.name] : null;
      final method = _bridgeName(node.argumentList.arguments.first, strings);
      if (method.dynamic) dynamicMethodNames++;
      if (channel == null) unattributedMethods++;
      facts.add(
        _fact(
          node.methodName.offset,
          'method-invoke',
          channel?.value,
          method: method.value,
          dynamic: channel == null || channel.dynamic || method.dynamic,
        ),
      );
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (_channelTypes.contains(node.constructorName.type.name.lexeme)) {
      final name = _bridgeName(
        node.argumentList.arguments.firstOrNull,
        strings,
      );
      facts.add(
        _fact(node.offset, 'channel-create', name.value, dynamic: name.dynamic),
      );
    }
    super.visitInstanceCreationExpression(node);
  }

  Map<String, Object?> _fact(
    int offset,
    String kind,
    String? channel, {
    String? method,
    required bool dynamic,
  }) {
    _rejectControlCharacters(path);
    if (channel != null) _rejectControlCharacters(channel);
    if (method != null) _rejectControlCharacters(method);
    final location = lineInfo.getLocation(offset);
    return {
      'kind': kind,
      'channel': channel,
      'method': ?method,
      'dynamic': dynamic,
      'location': {
        'path': path,
        'line': location.lineNumber,
        'column': location.columnNumber,
      },
    };
  }
}

const _channelTypes = {'MethodChannel', 'EventChannel', 'BasicMessageChannel'};
const _excludedDirectories = {'.dart_tool', '.git', 'build'};

void _rejectControlCharacters(String value) {
  if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(value)) {
    throw const FormatException(
      'bridge facts cannot contain control characters',
    );
  }
}

({String value, bool dynamic}) _bridgeName(
  AstNode? node,
  Map<String, String> strings,
) {
  if (node is SimpleStringLiteral) return (value: node.value, dynamic: false);
  if (node is SimpleIdentifier && strings[node.name] != null) {
    return (value: strings[node.name]!, dynamic: false);
  }
  return (value: node?.toSource() ?? '', dynamic: true);
}
