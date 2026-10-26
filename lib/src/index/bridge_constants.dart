part of 'bridge_index.dart';

/// 구문 bridge용 문자열 상수 해석이다. 대상 코드를 import하거나 실행하지 않고
/// 스캔 목록 안의 선언 신원만 따라간다. AST는 보관하지 않아 일반 스캔의 유닛별
/// 메모리 수명을 유지한다. 외부 패키지 namespace의 미검증은 limitation으로 남긴다.
final class _SourceStringConstants {
  _SourceStringConstants(this.root, Iterable<File> files)
    : _sources = {for (final file in files) p.normalize(file.absolute.path)};

  final Directory root;
  final Set<String> _sources;
  final _libraries = <String, _ConstantLibrary?>{};
  final _values = <(String, String), String?>{};
  final _unresolved = <(String, String)>{};
  final _parts = <String>{};
  final _parseErrors = <String>{};
  final _nameConflicts = <(String, String)>{};
  var _operations = 0;
  var _declarations = 0;
  var _literalCodeUnits = 0;
  var _limited = false;
  bool _readPackageName = false;
  String? _packageName;

  // 같은 입력·순회 순서에서 고정된 예산이다. 한도를 넘긴 이름은 dynamic으로
  // 남기고, 이미 얻은 결과나 다른 이름의 안전성을 완전성 증거로 쓰지 않는다.
  static const _maxLibraries = 4096;
  static const _maxDeclarations = 100000;
  static const _maxOperations = 250000;
  static const _maxDepth = 64;
  static const _maxValueLength = 65536;
  static const _maxLiteralCodeUnits = 4194304;

  List<String> get limitations => [
    if (_nameConflicts.isNotEmpty)
      'constant-name-conflicts: ${_nameConflicts.length} top-level name(s) '
          'have incompatible duplicate declarations; affected names remain unresolved',
    if (_unresolved.isNotEmpty)
      'constant-imports-unresolved: ${_unresolved.length} import/export '
          'namespace(s) were not inspected; static names use scanned-source '
          'declaration identities only, not a compiler-verified namespace',
    if (_parts.isNotEmpty)
      'constant-library-parts-unsupported: ${_parts.length} library file(s) '
          'with part directives were not used for cross-file constants',
    if (_parseErrors.isNotEmpty)
      'constant-source-parse-errors: ${_parseErrors.length} imported source '
          'file(s) were not used for static constants',
    if (_limited)
      'constant-resolution-limit: unresolved names remain dynamic after '
          '4096 libraries, 100000 declarations/directives, 250000 resolution steps, '
          '64 reference/expression levels, 65536 string code units or '
          '4194304 retained literal code units',
  ];

  void register(String path, CompilationUnit unit, {required bool hasErrors}) {
    path = p.normalize(p.absolute(path));
    if (_libraries.containsKey(path)) return;
    if (_libraries.length >= _maxLibraries) {
      _limited = true;
      return;
    }
    if (hasErrors) {
      _parseErrors.add(path);
      _libraries[path] = null;
      return;
    }
    if (unit.directives.any(
      (d) => d is PartDirective || d is PartOfDirective,
    )) {
      // part를 합치지 않으면 같은 라이브러리의 선언 가림·모호함을 놓칠 수 있다.
      _parts.add(path);
      _libraries[path] = null;
      return;
    }
    final summary = _topLevelNameSummary(unit);
    final names = summary.names;
    final entries = summary.declarations + unit.directives.length;
    if (_declarations + entries > _maxDeclarations) {
      _limited = true;
      _libraries[path] = null;
      return;
    }
    _declarations += entries;
    _nameConflicts.addAll(summary.conflicts.map((name) => (path, name)));
    final constants = <String, _ConstantExpression>{};
    for (final declaration
        in unit.declarations.whereType<TopLevelVariableDeclaration>()) {
      for (final variable in declaration.variables.variables) {
        if (!variable.isConst ||
            summary.conflicts.contains(variable.name.lexeme)) {
          continue;
        }
        final expression = _expression(variable.initializer, 0);
        if (expression != null) constants[variable.name.lexeme] = expression;
      }
    }
    _libraries[path] = _ConstantLibrary(
      names,
      summary.conflicts,
      constants,
      [
        for (final directive in unit.directives.whereType<ImportDirective>())
          _namespace(
            path,
            directive.uri.stringValue,
            directive.combinators,
            prefix: directive.prefix?.name,
            unavailable:
                directive.configurations.isNotEmpty ||
                directive.deferredKeyword != null,
          ),
      ],
      [
        for (final directive in unit.directives.whereType<ExportDirective>())
          _namespace(
            path,
            directive.uri.stringValue,
            directive.combinators,
            unavailable: directive.configurations.isNotEmpty,
          ),
      ],
    );
  }

  String? resolve(String path, String name) =>
      _value(p.normalize(p.absolute(path)), name, {}, 0);

  _ConstantLibrary? _library(String path) {
    if (_libraries.containsKey(path)) return _libraries[path];
    if (!_sources.contains(path) || _libraries.length >= _maxLibraries) {
      if (_libraries.length >= _maxLibraries) _limited = true;
      return null;
    }
    final source = readAnalysisInputSync(File(path));
    final parsed = parseString(
      content: source,
      path: path,
      throwIfDiagnostics: false,
    );
    register(path, parsed.unit, hasErrors: parsed.errors.isNotEmpty);
    return _libraries[path];
  }

  bool _step(int depth) {
    if (depth > _maxDepth || ++_operations > _maxOperations) {
      _limited = true;
      return false;
    }
    return true;
  }

  String? _value(
    String path,
    String name,
    Set<(String, String)> visiting,
    int depth,
  ) {
    final key = (path, name);
    if (_values.containsKey(key)) return _values[key];
    if (!_step(depth) || !visiting.add(key)) return null;
    try {
      final candidates = _scope(path, name, depth + 1);
      if (candidates.blocked || candidates.symbols.length != 1) return null;
      final symbol = candidates.symbols.single;
      final expression = _library(symbol.$1)?.constants[symbol.$2];
      if (expression == null) return null;
      final value = _evaluate(expression, symbol.$1, visiting, depth + 1);
      // 사이클의 중간 null을 캐시하면 경로에 따라 다른 이름의 결과가 달라질 수
      // 있다. 성공 값만 캐시하고 실패는 정해진 전역 예산 안에서 다시 관측한다.
      if (value != null) _values[key] = value;
      return value;
    } finally {
      visiting.remove(key);
    }
  }

  _ConstantCandidates _scope(String path, String name, int depth) {
    final library = _library(path);
    if (library == null || !_step(depth)) {
      return _ConstantCandidates(blocked: true);
    }
    final segments = name.split('.');
    if (segments.length > 2) return _ConstantCandidates(blocked: true);
    final prefix = segments.length == 2 ? segments.first : null;
    final bare = segments.last;
    if (prefix == null && library.names.contains(bare)) {
      if (library.conflicts.contains(bare)) {
        return _ConstantCandidates(blocked: true);
      }
      return _ConstantCandidates()..symbols.add((path, bare));
    }
    if (bare.startsWith('_') ||
        (prefix != null && library.names.contains(prefix))) {
      return _ConstantCandidates(blocked: true);
    }
    final result = _ConstantCandidates();
    for (final imported in library.imports) {
      if (imported.prefix != prefix || !imported.exposes(bare)) continue;
      if (imported.target == null) _unresolved.add((path, imported.uri));
      if (imported.unavailable) {
        result.blocked = true;
      } else if (imported.target != null) {
        result.add(_exported(imported.target!, bare, {}, depth + 1));
      } else if (!imported.external ||
          prefix != null ||
          imported.shown.isNotEmpty) {
        // 미존재 상대 경로·명시 prefix/show의 미검증 namespace는 선택할 수 없다.
        result.blocked = true;
      }
      // 광범위 외부 package/dart import는 이 구문 스캐너가 namespace를 확정하지
      // 않는다. 이를 소스 내 중복 선언과 혼동하지 않고 전역 limitation으로 알린다.
    }
    return result;
  }

  _ConstantCandidates _exported(
    String path,
    String name,
    Set<String> visiting,
    int depth,
  ) {
    if (!_step(depth)) return _ConstantCandidates(blocked: true);
    if (!visiting.add(path)) return _ConstantCandidates();
    try {
      final library = _library(path);
      if (library == null) return _ConstantCandidates(blocked: true);
      if (library.names.contains(name)) {
        if (library.conflicts.contains(name)) {
          return _ConstantCandidates(blocked: true);
        }
        return _ConstantCandidates()..symbols.add((path, name));
      }
      final result = _ConstantCandidates();
      for (final exported in library.exports) {
        if (!exported.exposes(name)) continue;
        final target = exported.target;
        if (target == null) _unresolved.add((path, exported.uri));
        if (exported.unavailable || target == null) {
          result.blocked = true;
        } else {
          result.add(_exported(target, name, visiting, depth + 1));
        }
      }
      return result;
    } finally {
      visiting.remove(path);
    }
  }

  _ConstantNamespace _namespace(
    String path,
    String? uri,
    NodeList<Combinator> combinators, {
    String? prefix,
    bool unavailable = false,
  }) {
    final parsed = uri == null ? null : Uri.tryParse(uri);
    String? target;
    final external = parsed?.scheme == 'package' || parsed?.scheme == 'dart';
    if (parsed != null && !parsed.hasQuery && !parsed.hasFragment) {
      if (!parsed.hasScheme &&
          !parsed.hasAuthority &&
          !p.isAbsolute(parsed.path)) {
        target = p.normalize(p.fromUri(File(path).uri.resolveUri(parsed)));
      } else if (parsed.scheme == 'package') {
        final segments = parsed.pathSegments;
        if (segments.length >= 2 && segments.first == _rootPackageName) {
          final packagePath = p.join(root.path, 'lib');
          final candidate = p.normalize(
            p.joinAll([packagePath, ...segments.skip(1)]),
          );
          if (p.isWithin(packagePath, candidate)) target = candidate;
        }
      }
    }
    if (!_sources.contains(target)) target = null;
    return _ConstantNamespace(
      uri ?? '<invalid-uri>',
      target,
      prefix,
      {
        for (final combinator in combinators.whereType<HideCombinator>())
          ...combinator.hiddenNames.map((name) => name.name),
      },
      [
        for (final combinator in combinators.whereType<ShowCombinator>())
          combinator.shownNames.map((name) => name.name).toSet(),
      ],
      unavailable: unavailable,
      external: external,
    );
  }

  String? get _rootPackageName {
    if (_readPackageName) return _packageName;
    _readPackageName = true;
    final pubspec = File(p.join(root.path, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return null;
    try {
      final document = loadYaml(readAnalysisInputSync(pubspec));
      if (document is YamlMap && document['name'] is String) {
        _packageName = document['name'] as String;
      }
    } on YamlException {
      // package 이름을 입증하지 못하면 package: 경로를 추측하지 않는다.
    }
    return _packageName;
  }

  _ConstantExpression? _expression(AstNode? node, int depth) {
    if (!_step(depth)) return null;
    if (node is ParenthesizedExpression) {
      return _expression(node.expression, depth + 1);
    }
    if (node is SimpleStringLiteral) {
      if (node.value.length > _maxValueLength ||
          _literalCodeUnits + node.value.length > _maxLiteralCodeUnits) {
        _limited = true;
        return null;
      }
      _literalCodeUnits += node.value.length;
      return _ConstantExpression.literal(node.value);
    }
    final name = node == null ? null : _constantReference(node);
    if (name != null) return _ConstantExpression.reference(name);
    final Iterable<AstNode> parts;
    if (node is AdjacentStrings) {
      parts = node.strings;
    } else if (node is BinaryExpression && node.operator.lexeme == '+') {
      parts = [node.leftOperand, node.rightOperand];
    } else {
      return null;
    }
    final expressions = <_ConstantExpression>[];
    for (final part in parts) {
      final expression = _expression(part, depth + 1);
      if (expression == null) return null;
      expressions.add(expression);
    }
    return _ConstantExpression.join(expressions);
  }

  String? _evaluate(
    _ConstantExpression expression,
    String path,
    Set<(String, String)> visiting,
    int depth,
  ) {
    if (!_step(depth)) return null;
    if (expression.literal != null) return expression.literal;
    if (expression.reference != null) {
      return _value(path, expression.reference!, visiting, depth + 1);
    }
    final value = StringBuffer();
    for (final part in expression.parts) {
      final string = _evaluate(part, path, visiting, depth + 1);
      if (string == null) return null;
      if (value.length + string.length > _maxValueLength) {
        _limited = true;
        return null;
      }
      value.write(string);
    }
    return value.toString();
  }
}

String? _constantReference(AstNode node) => switch (node) {
  SimpleIdentifier() => node.name,
  PrefixedIdentifier() => '${node.prefix.name}.${node.identifier.name}',
  _ => null,
};

final class _ConstantLibrary {
  _ConstantLibrary(
    this.names,
    this.conflicts,
    this.constants,
    this.imports,
    this.exports,
  );
  final Set<String> names;
  final Set<String> conflicts;
  final Map<String, _ConstantExpression> constants;
  final List<_ConstantNamespace> imports;
  final List<_ConstantNamespace> exports;
}

final class _ConstantNamespace {
  _ConstantNamespace(
    this.uri,
    this.target,
    this.prefix,
    this.hidden,
    this.shown, {
    required this.unavailable,
    required this.external,
  });
  final String uri;
  final String? target;
  final String? prefix;
  final Set<String> hidden;
  final List<Set<String>> shown;
  final bool unavailable;
  final bool external;
  bool exposes(String name) =>
      !hidden.contains(name) && shown.every((names) => names.contains(name));
}

final class _ConstantCandidates {
  _ConstantCandidates({this.blocked = false});
  final symbols = <(String, String)>{};
  bool blocked;
  void add(_ConstantCandidates other) {
    symbols.addAll(other.symbols);
    blocked = blocked || other.blocked;
  }
}

final class _ConstantExpression {
  _ConstantExpression.literal(this.literal)
    : reference = null,
      parts = const [];
  _ConstantExpression.reference(this.reference)
    : literal = null,
      parts = const [];
  _ConstantExpression.join(this.parts) : literal = null, reference = null;
  final String? literal;
  final String? reference;
  final List<_ConstantExpression> parts;
}
