import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'bridge_index.dart'
    show enclosingFactSymbol, rejectFactControlCharacters;
import 'project_files.dart';
import 'sql_relations.dart';

/// persistence 도메인 `relation-use` 사실과 추출 한계다.
final class SchemaIndexResult {
  /// 결정적으로 정렬된 교환 사실과 한계를 담는다.
  const SchemaIndexResult(this.facts, this.limitations);

  /// GRAPH-EXCHANGE `relation-use` fact 객체다.
  final List<Map<String, Object?>> facts;

  /// 사실로 만들지 못한 근거의 계수와 유형이다.
  final List<String> limitations;
}

/// [rootPath]의 Dart·`.drift` 소스에서 DB 관계 참조를 읽어 `relation-use`
/// 사실을 만든다.
///
/// isthmus persistence 조인의 호출 측 생산자다 — 선언(`relation-decl`)은
/// schemagraph가 낸다. 증거가 있는 표면만 읽는다: sqflite의 SQL·테이블 인자,
/// sqlite3·postgres의 SQL 인자, drift `Table` 클래스·custom 쿼리·`.drift` 파일,
/// floor `@Entity`·`@DatabaseView`·`@Query`, 그리고 게이트 없는 대문자 SQL
/// 리터럴. Isar·Hive 같은 비관계 저장소와 지원 표면 밖 SQL 패키지는 관측
/// 개수로만 남긴다 — 관계가 아닌 이름을 사실로 만들면 없는 선언을 찾는 거짓
/// 진단이 된다.
///
/// [projectRootPath]의 의미와 검증은 `indexBridges`와 같다.
SchemaIndexResult indexSchema(String rootPath, {String? projectRootPath}) {
  final root = Directory(
    Directory(rootPath).absolute.resolveSymbolicLinksSync(),
  );
  final pathBase = projectRootPath == null
      ? root.path
      : Directory(projectRootPath).absolute.resolveSymbolicLinksSync();
  if (!p.equals(pathBase, root.path) && !p.isWithin(pathBase, root.path)) {
    throw ArgumentError.value(
      projectRootPath,
      'projectRootPath',
      'must contain the package root',
    );
  }
  final context = _ProjectContext.read(root.path);
  final counts = _SchemaCounts();
  final facts = <Map<String, Object?>>[];
  final linkEscapes = <String>{};
  final files = indexProjectFiles(
    root,
    boundary: root.path,
    linkEscapes: linkEscapes,
  ).where((file) => _isSchemaSource(file.path));
  for (final file in files) {
    final relative = p.posix.joinAll(
      p.relative(file.path, from: pathBase).split(p.separator),
    );
    rejectFactControlCharacters(relative);
    final String source;
    try {
      source = file.readAsStringSync();
    } on FileSystemException {
      counts.unreadableFiles++;
      continue;
    } on FormatException {
      counts.unreadableFiles++;
      continue;
    }
    final scanner = _SchemaFileScanner(relative, source, context, counts);
    if (file.path.endsWith('.drift')) {
      scanner.scanDriftFile();
    } else {
      scanner.scanDartFile(file.path);
    }
    facts.addAll(scanner.facts);
  }
  facts.sort(_compareFacts);
  return SchemaIndexResult(
    facts,
    _limitations(facts, counts, context, linkEscapes),
  );
}

bool _isSchemaSource(String path) =>
    path.endsWith('.dart') || path.endsWith('.drift');

/// 사실로 만들지 못한 근거를 한계 문장으로 바꾼다. 접두사는 계약이다.
List<String> _limitations(
  List<Map<String, Object?>> facts,
  _SchemaCounts counts,
  _ProjectContext context,
  Set<String> linkEscapes,
) {
  final missingSymbols = facts.where((f) => !f.containsKey('symbol')).length;
  return [
    for (final escape in linkEscapes.toList()..sort())
      'symlink-escape: $escape resolves outside the scanned root; its '
          'contents contribute relation facts',
    if (counts.dynamicRelations > 0)
      'dynamic-relation-names: ${counts.dynamicRelations} SQL argument(s) or '
          'relation operand(s) were not statically readable; they are emitted '
          'as dynamic facts',
    if (counts.skippedSqlLiterals > 0)
      'skipped-sql-literals: ${counts.skippedSqlLiterals} ungated literal(s) '
          'contained SQL verbs but not the uppercase form required for '
          'heuristic scanning; not counted',
    if (counts.driftUnverifiedNames > 0)
      'drift-name-derivation-unverified: ${counts.driftUnverifiedNames} drift '
          'table/column name(s) were not derived '
          '(${context.driftNamingReason ?? 'name shape outside the verified snake_case subset'}); '
          'tables are emitted as dynamic facts, columns are omitted',
    if (counts.invalidNames > 0)
      'invalid-relation-names: ${counts.invalidNames} relation or column '
          'name(s) contained control characters and were skipped',
    if (counts.nonRelationalFiles.isNotEmpty)
      'non-relational-stores: ${counts.nonRelationalFileCount} Dart source '
          'file(s) import non-SQL persistence packages outside the relation '
          'join: ${_breakdown(counts.nonRelationalFiles)}',
    if (counts.unsupportedFiles.isNotEmpty)
      'unsupported-db-packages: ${counts.unsupportedFileCount} Dart source '
          'file(s) import SQL packages outside the supported surface: '
          '${_breakdown(counts.unsupportedFiles)}',
    if (missingSymbols > 0)
      'missing-relation-symbols: $missingSymbols relation-use fact(s) have '
          'source locations but no supported enclosing declaration name',
    if (counts.unreadableFiles > 0)
      'unreadable-sources: ${counts.unreadableFiles} file(s) could not be read '
          'and were skipped',
    if (counts.parseErrorFiles > 0)
      'parse-errors: ${counts.parseErrorFiles} Dart source file(s) could not '
          'be parsed completely',
  ];
}

String _breakdown(Map<String, int> files) => (files.keys.toList()..sort())
    .map((name) => '$name (${files[name]})')
    .join(', ');

int _compareFacts(Map<String, Object?> a, Map<String, Object?> b) {
  final al = a['location']! as Map<String, Object?>;
  final bl = b['location']! as Map<String, Object?>;
  final pathOrder = (al['path']! as String).compareTo(bl['path']! as String);
  if (pathOrder != 0) return pathOrder;
  final lineOrder = (al['line']! as int).compareTo(bl['line']! as int);
  if (lineOrder != 0) return lineOrder;
  final columnOrder = (al['column']! as int).compareTo(bl['column']! as int);
  if (columnOrder != 0) return columnOrder;
  return '${a['channel']}\u0000${a['method']}'.compareTo(
    '${b['channel']}\u0000${b['method']}',
  );
}

/// 스캔 전체에서 누적하는 계수다 — "없다"와 "못 봤다"를 구분하는 장부다.
final class _SchemaCounts {
  var dynamicRelations = 0;
  var skippedSqlLiterals = 0;
  var driftUnverifiedNames = 0;
  var invalidNames = 0;
  var unreadableFiles = 0;
  var parseErrorFiles = 0;
  var nonRelationalFileCount = 0;
  var unsupportedFileCount = 0;

  /// 비관계 저장소 패키지별 import 파일 수다.
  final nonRelationalFiles = <String, int>{};

  /// 지원 표면 밖 SQL 패키지별 import 파일 수다.
  final unsupportedFiles = <String, int>{};
}

/// 파일 밖에서 한 번 읽는 프로젝트 설정 — pubspec 의존성과 drift 명명 규칙이다.
final class _ProjectContext {
  _ProjectContext(this.dependencies, this.driftNamingReason);

  /// pubspec이 선언한 의존성 이름 — 구별되는 API 이름의 프로젝트 수준 게이트다.
  final Set<String> dependencies;

  /// drift의 기본 snake_case 파생을 믿을 수 없는 이유다. null이면 믿는다.
  final String? driftNamingReason;

  static _ProjectContext read(String root) => _ProjectContext(
    _pubspecDependencies(p.join(root, 'pubspec.yaml')),
    _driftNamingReason(p.join(root, 'build.yaml')),
  );
}

Set<String> _pubspecDependencies(String path) {
  final file = File(path);
  if (!file.existsSync()) return const {};
  try {
    final document = loadYaml(file.readAsStringSync());
    if (document is! YamlMap) return const {};
    return {
      for (final key in const ['dependencies', 'dev_dependencies'])
        if (document[key] case final YamlMap section)
          ...section.keys.whereType<String>(),
    };
  } on YamlException {
    // 의존성 게이트는 import 게이트의 보조다 — 못 읽으면 import만 믿는다.
    return const {};
  }
}

/// drift는 `case_from_dart_to_sql` 옵션으로 이름 변환을 바꿀 수 있다
/// (기본 snake_case). 다른 값이거나 설정을 읽지 못하면 파생 이름을 싣지 않는다.
String? _driftNamingReason(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    final value = _findYamlKey(
      loadYaml(file.readAsStringSync()),
      'case_from_dart_to_sql',
    );
    if (value == null || value == 'snake_case') return null;
    return 'build.yaml sets case_from_dart_to_sql to $value';
  } on YamlException {
    return 'build.yaml could not be parsed';
  }
}

Object? _findYamlKey(Object? node, String key) {
  if (node is YamlMap) {
    if (node.containsKey(key)) return node[key];
    for (final value in node.values) {
      final found = _findYamlKey(value, key);
      if (found != null) return found;
    }
  } else if (node is YamlList) {
    for (final value in node) {
      final found = _findYamlKey(value, key);
      if (found != null) return found;
    }
  }
  return null;
}

/// 파일 하나가 import한 persistence 패키지 — 이름이 흔한 API의 파일 수준 게이트다.
final class _Surfaces {
  _Surfaces(this.imported, this.dependencies);

  /// 이 파일이 import한 `package:` 이름들이다.
  final Set<String> imported;
  final Set<String> dependencies;

  bool _has(Set<String> packages) => packages.any(imported.contains);
  bool _declared(Set<String> packages) => packages.any(dependencies.contains);

  bool get sqflite => _has(_sqflitePackages);
  bool get sqfliteProject => sqflite || _declared(_sqflitePackages);
  bool get sqlite3 => imported.contains('sqlite3');
  bool get drift => imported.contains('drift');
  bool get driftProject => drift || dependencies.contains('drift');
  bool get floor => _has(_floorPackages);
  bool get postgres => imported.contains('postgres');
}

const _sqflitePackages = {
  'sqflite',
  'sqflite_common',
  'sqflite_common_ffi',
  'sqflite_common_ffi_web',
  'sqflite_sqlcipher',
};
const _floorPackages = {'floor', 'floor_annotation', 'floor_common'};
const _nonRelationalPackages = {
  'isar',
  'hive',
  'hive_ce',
  'hive_flutter',
  'objectbox',
  'realm',
  'sembast',
  'cloud_firestore',
  'firebase_database',
};
const _unsupportedSqlPackages = {
  'mysql1',
  'mysql_client',
  'sqlite_async',
  'powersync',
  'supabase',
  'supabase_flutter',
  'postgrest',
};

/// sqflite에서 첫 번째 위치 인자가 SQL인 구별되는 이름이다 — pubspec 게이트도 인정한다.
const _sqfliteRawMethods = {
  'rawQuery',
  'rawInsert',
  'rawUpdate',
  'rawDelete',
  'rawQueryCursor',
};

/// sqflite에서 첫 번째 위치 인자가 테이블 이름인 흔한 이름이다 — import 게이트만 인정한다.
const _sqfliteTableMethods = {
  'query',
  'queryCursor',
  'insert',
  'update',
  'delete',
};

/// drift 데이터베이스의 SQL 텍스트를 받는 메서드다.
const _driftCustomMethods = {
  'customSelect',
  'customStatement',
  'customUpdate',
  'customInsert',
  'customWriteReturning',
};
const _sqlite3SqlMethods = {'execute', 'select', 'prepare', 'prepareMultiple'};
const _postgresSqlMethods = {
  'execute',
  'query',
  'mappedResultsQuery',
  'prepare',
};

/// drift 컬럼 빌더 — `late final x = integer()();` 필드 초기화 사슬의 뿌리다.
const _driftColumnBuilders = {
  'integer',
  'int64',
  'text',
  'boolean',
  'dateTime',
  'real',
  'blob',
  'intEnum',
  'textEnum',
  'customType',
};

final _tableNameShape = RegExp(
  r'^[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*)?$',
);
final _columnNameShape = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// drift snake_case 파생을 검증된 형태로만 허용한다 — 글자만 쓰고 대문자
/// 뒤에 소문자가 이어지는 이름. 연속 대문자·숫자는 변환 규칙이 구현마다
/// 달라질 수 있어 추측하지 않는다.
final _driftSafeShape = RegExp(r'^[A-Za-z][a-z]*([A-Z][a-z]+)*$');

String _snakeCase(String name) => name
    .replaceAllMapped(RegExp('[A-Z]'), (match) => '_${match[0]!.toLowerCase()}')
    .replaceFirst(RegExp('^_'), '');

final _whitespace = RegExp(r'\s+');
final _controlCharacters = RegExp(r'[\x00-\x1F\x7F-\x9F  ]');

/// 동적 사실의 channel에 실을 원문 요약 — 공백을 접고 160자로 자른다.
String _dynamicChannel(String source) {
  final folded = source.replaceAll(_whitespace, ' ').trim();
  final clean = folded.replaceAll(_controlCharacters, '');
  var end = clean.length > 160 ? 160 : clean.length;
  // UTF-16 절단이 서로게이트 쌍을 쪼개면 짝 없는 서로게이트가 JSON에 남는다.
  if (end < clean.length && _isHighSurrogate(clean.codeUnitAt(end - 1))) {
    end--;
  }
  final text = clean.substring(0, end);
  return text.isEmpty ? '<dynamic>' : text;
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// 한 파일의 스캔 상태 — 사실 방출과 위치 계산을 맡는다.
final class _SchemaFileScanner {
  _SchemaFileScanner(this.path, this.source, this.context, this.counts)
    : lineInfo = LineInfo.fromContent(source);

  final String path;
  final String source;
  final _ProjectContext context;
  final _SchemaCounts counts;
  final LineInfo lineInfo;
  final facts = <Map<String, Object?>>[];

  /// `.drift` 파일은 SQL이다 — 파일 전체를 관계 추출기에 넣는다.
  void scanDriftFile() {
    final result = sqlRelations(source);
    for (final relation in result.relations) {
      emit(relation.name, offset: relation.keyword);
    }
    if (result.unresolved > 0) {
      counts.dynamicRelations += result.unresolved;
      emit('<drift file>', offset: 0, dynamic: true);
    }
  }

  void scanDartFile(String absolutePath) {
    final parsed = parseString(
      content: source,
      path: absolutePath,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) counts.parseErrorFiles++;
    final imported = _importedPackages(parsed.unit);
    _countObservedPackages(imported);
    final bindings = _StringBindings.collect(parsed.unit);
    final gated = _GatedVisitor(
      this,
      _Surfaces(imported, context.dependencies),
      bindings,
    );
    parsed.unit.accept(gated);
    parsed.unit.accept(_LiteralVisitor(this, gated.consumed));
  }

  void _countObservedPackages(Set<String> imported) {
    final nonRelational = imported.intersection(_nonRelationalPackages);
    final unsupported = imported.intersection(_unsupportedSqlPackages);
    if (nonRelational.isNotEmpty) counts.nonRelationalFileCount++;
    if (unsupported.isNotEmpty) counts.unsupportedFileCount++;
    for (final name in nonRelational) {
      counts.nonRelationalFiles.update(name, (n) => n + 1, ifAbsent: () => 1);
    }
    for (final name in unsupported) {
      counts.unsupportedFiles.update(name, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  /// SQL 텍스트의 관계들을 사실로 낸다 — 미해석 피연산자는 동적 사실 하나로 남긴다.
  void emitSql(String sql, AstNode at, {bool strict = false}) {
    final result = sqlRelations(sql, strict: strict);
    // 한 SQL 텍스트의 사실은 모두 같은 위치에 찍힌다 — self-join처럼 같은 이름이
    // 여러 번 나와도 같은 위치·채널의 동일 사실은 한 번만 낸다.
    for (final name in {
      for (final relation in result.relations) relation.name,
    }) {
      emit(name, offset: at.offset, node: at);
    }
    if (result.unresolved > 0) {
      counts.dynamicRelations += result.unresolved;
      emit(_dynamicChannel(sql), offset: at.offset, node: at, dynamic: true);
    }
  }

  /// 읽을 수 없는 관계 자리를 동적 사실로 남긴다.
  void emitDynamic(AstNode at, {String? channelPrefix}) {
    counts.dynamicRelations++;
    emit(
      _dynamicChannel(at.toSource()),
      offset: at.offset,
      node: at,
      dynamic: true,
      channelPrefix: channelPrefix,
    );
  }

  /// `relation-use` 사실 하나를 만든다. [symbol]이 없으면 [node]를 감싸는 선언에 귀속한다.
  void emit(
    String channel, {
    required int offset,
    AstNode? node,
    String? method,
    bool dynamic = false,
    String? channelPrefix,
    String? symbol,
  }) {
    final values = [channel, ?method, ?channelPrefix];
    if (values.any((v) => v.trim().isEmpty || _controlCharacters.hasMatch(v))) {
      counts.invalidNames++;
      return;
    }
    final resolvedSymbol = symbol != null
        ? {'qualifiedName': symbol}
        : (node == null ? null : enclosingFactSymbol(node));
    facts.add({
      'symbol': ?resolvedSymbol,
      'kind': 'relation-use',
      'channel': channel,
      'method': ?method,
      'dynamic': dynamic,
      if (dynamic && channelPrefix != null) 'channelPrefix': channelPrefix,
      'location': _location(offset),
    });
  }

  Map<String, Object?> _location(int offset) {
    final location = lineInfo.getLocation(offset);
    final lineOffset = lineInfo.getOffsetOfLine(location.lineNumber - 1);
    return {
      'path': path,
      'line': location.lineNumber,
      'column': utf8.encode(source.substring(lineOffset, offset)).length + 1,
    };
  }
}

Set<String> _importedPackages(CompilationUnit unit) => {
  for (final directive in unit.directives.whereType<ImportDirective>())
    if (_packageName(directive.uri.stringValue) case final String name) name,
};

String? _packageName(String? uri) {
  if (uri == null || !uri.startsWith('package:')) return null;
  final slash = uri.indexOf('/');
  return slash < 0 ? null : uri.substring('package:'.length, slash);
}

/// `const sql = '…'`·`final table = 'users'` — 파일 수준의 한 단계 상수 해석이다.
///
/// 같은 이름이 다른 값으로 다시 묶이면 어느 쪽도 믿지 않는다 — 잘못된 관계명을
/// 싣는 오귀속보다 사용 지점의 동적 근거가 낫다.
final class _StringBindings extends RecursiveAstVisitor<void> {
  final values = <String, String>{};

  /// 바인딩 이름별 선언 리터럴 — 게이트 호출이 이름으로 쓰면 원시 리터럴
  /// 패스가 선언 자리에서 같은 SQL을 다시 사실로 만들지 않게 억제한다.
  final literals = <String, List<StringLiteral>>{};
  final _poisoned = <String>{};

  static _StringBindings collect(CompilationUnit unit) {
    final bindings = _StringBindings();
    unit.accept(bindings);
    return bindings;
  }

  /// 리터럴이 아닌 선언(파라미터·비리터럴 초기화·루프·패턴 변수)이 같은 이름을
  /// 가지면 어느 사용이 상수를 가리키는지 어휘 범위 없이 알 수 없다 — 귀속을 끊는다.
  void _poison(String? name) {
    if (name == null) return;
    values.remove(name);
    _poisoned.add(name);
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
    for (final parameter in node.parameters) {
      _poison(parameter.name?.lexeme);
    }
    super.visitFormalParameterList(node);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    _poison(node.name.lexeme);
    super.visitDeclaredIdentifier(node);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    _poison(node.name.lexeme);
    super.visitDeclaredVariablePattern(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final initializer = node.initializer;
    final name = node.name.lexeme;
    if ((node.isConst || node.isFinal) &&
        initializer is StringLiteral &&
        initializer.stringValue != null &&
        !_poisoned.contains(name)) {
      final value = initializer.stringValue!;
      if (values[name] case final existing? when existing != value) {
        _poison(name);
      } else {
        values[name] = value;
        literals.putIfAbsent(name, () => []).add(initializer);
      }
    } else {
      _poison(name);
    }
    super.visitVariableDeclaration(node);
  }
}

/// 라이브러리 표면이 확정한 인자·선언을 읽는 패스다.
final class _GatedVisitor extends RecursiveAstVisitor<void> {
  _GatedVisitor(this.scanner, this.surfaces, this.bindings);

  final _SchemaFileScanner scanner;
  final _Surfaces surfaces;
  final _StringBindings bindings;

  /// 게이트 인자로 이미 읽은 리터럴 — 원시 리터럴 패스가 다시 읽지 않게 한다.
  final consumed = Set<AstNode>.identity();

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _visitInvocation(node);
    super.visitMethodInvocation(node);
  }

  void _visitInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    final positional = node.argumentList.arguments
        .whereType<Expression>()
        .toList();
    if (positional.isEmpty) return;
    final hasTarget = node.target != null || node.isCascaded;
    // sqflite 테이블 인자 모양이 먼저다 — postgres도 import한 파일에서 같은 이름
    // `query`가 SQL 경로로 새어 테이블 사실이 사라지지 않게 한다.
    if (surfaces.sqflite &&
        hasTarget &&
        _sqfliteTableMethods.contains(name) &&
        _isSqfliteTableArgument(name, positional.first)) {
      _visitSqfliteTableCall(node, name, positional);
    } else if (_isSqlCall(name, hasTarget)) {
      _emitSqlArgument(_unwrapPostgresSql(positional.first));
    }
  }

  /// 첫 인자가 sqflite 테이블 인자로 읽힐 수 있는지 본다. 비리터럴은 같은 이름의
  /// postgres SQL 호출일 수도 있어, 그 파일이 postgres를 import했으면 SQL로 둔다.
  bool _isSqfliteTableArgument(String name, Expression first) {
    final literal = _literalValue(first);
    if (literal != null) return _tableNameShape.hasMatch(literal);
    return !(surfaces.postgres && _postgresSqlMethods.contains(name));
  }

  /// SQL 텍스트를 첫 위치 인자로 받는 호출인지 본다.
  bool _isSqlCall(String name, bool hasTarget) {
    if (_sqfliteRawMethods.contains(name)) return surfaces.sqfliteProject;
    if (_driftCustomMethods.contains(name)) return surfaces.driftProject;
    if (!hasTarget) return false;
    return (surfaces.sqflite && name == 'execute') ||
        (surfaces.sqlite3 && _sqlite3SqlMethods.contains(name)) ||
        (surfaces.postgres && _postgresSqlMethods.contains(name));
  }

  /// postgres `Sql.named('…')`·`Sql('…')`는 SQL을 감싼 값이다 — 안쪽 인자를 읽는다.
  Expression _unwrapPostgresSql(Expression argument) {
    if (!surfaces.postgres || argument is! MethodInvocation) return argument;
    final target = argument.target;
    final isSql =
        (argument.methodName.name == 'Sql' && target == null) ||
        (argument.methodName.name == 'named' &&
            target is SimpleIdentifier &&
            target.name == 'Sql');
    final inner = argument.argumentList.arguments.whereType<Expression>();
    return isSql && inner.isNotEmpty ? inner.first : argument;
  }

  /// sqflite `db.query('users', columns: […])`·`insert('users', {…})` 계열이다.
  void _visitSqfliteTableCall(
    MethodInvocation node,
    String name,
    List<Expression> positional,
  ) {
    final first = positional.first;
    final literal = _literalValue(first);
    // 이름이 흔한 API라 테이블 이름 모양이 아닌 리터럴은 다른 라이브러리 호출이다.
    if (literal != null && !_tableNameShape.hasMatch(literal)) return;
    if ((name == 'insert' || name == 'update') && positional.length < 2) return;
    final table = _emitNameArgument(first);
    if (table == null) return;
    _emitColumnList(node, table);
    if (positional.length > 1 && (name == 'insert' || name == 'update')) {
      _emitMapKeys(positional[1], table);
    }
  }

  /// 리터럴 값 또는 바인딩된 상수 값이다.
  String? _literalValue(Expression expression) {
    if (expression is StringLiteral) return expression.stringValue;
    if (expression is SimpleIdentifier) return bindings.values[expression.name];
    return null;
  }

  /// 요약한 인자 식 안의 모든 문자열 리터럴을 소비한다 — 원시 리터럴 패스가
  /// `'SELECT * FROM ' + t`의 조각을 다시 읽어 같은 호출의 근거를 부풀리지 않게 한다.
  void _consumeSubtree(AstNode node) =>
      node.accept(_LiteralCollector(consumed));

  /// SQL 인자 하나 — 리터럴·바인딩 상수면 관계를 읽고, 아니면 동적 근거다.
  void _emitSqlArgument(Expression expression) {
    _consumeSubtree(expression);
    if (expression is StringLiteral) {
      consumed.add(expression);
      final value = expression.stringValue;
      if (value != null) return scanner.emitSql(value, expression);
      return scanner.emitDynamic(
        expression,
        channelPrefix: _interpolationPrefix(expression),
      );
    }
    if (expression is SimpleIdentifier) {
      final value = bindings.values[expression.name];
      if (value != null) {
        consumed.addAll(bindings.literals[expression.name] ?? const []);
        return scanner.emitSql(value, expression);
      }
    }
    scanner.emitDynamic(expression);
  }

  /// 관계명 인자 하나 — 채널을 돌려주고 비리터럴이면 동적 근거를 남기고 null이다.
  String? _emitNameArgument(Expression expression) {
    _consumeSubtree(expression);
    final value = _literalValue(expression);
    if (value == null) {
      scanner.emitDynamic(
        expression,
        channelPrefix: expression is StringLiteral
            ? _interpolationPrefix(expression)
            : null,
      );
      return null;
    }
    if (expression is SimpleIdentifier) {
      consumed.addAll(bindings.literals[expression.name] ?? const []);
    }
    final channel = escapeQualified(value);
    scanner.emit(channel, offset: expression.offset, node: expression);
    return channel;
  }

  /// `columns: ['id', 'name']` — 식별자 모양의 리터럴만 그 테이블의 컬럼이다.
  void _emitColumnList(MethodInvocation node, String table) {
    for (final argument
        in node.argumentList.arguments.whereType<NamedArgument>()) {
      final list = argument.argumentExpression;
      if (argument.name.lexeme != 'columns' || list is! ListLiteral) continue;
      for (final element in list.elements.whereType<SimpleStringLiteral>()) {
        _emitColumn(table, element);
      }
    }
  }

  /// `insert('users', {'name': …})`의 맵 리터럴 키가 컬럼 이름이다.
  void _emitMapKeys(Expression values, String table) {
    if (values is! SetOrMapLiteral) return;
    for (final entry in values.elements.whereType<MapLiteralEntry>()) {
      final key = entry.key;
      if (key is SimpleStringLiteral) _emitColumn(table, key);
    }
  }

  void _emitColumn(String table, SimpleStringLiteral literal) {
    consumed.add(literal);
    if (!_columnNameShape.hasMatch(literal.value)) return;
    scanner.emit(
      table,
      method: escapeName(literal.value),
      offset: literal.offset,
      node: literal,
    );
  }

  @override
  void visitAnnotation(Annotation node) {
    if (surfaces.floor && _annotationName(node) == 'Query') {
      final positional = node.arguments?.arguments.whereType<Expression>();
      if (positional != null && positional.isNotEmpty) {
        _emitSqlArgument(positional.first);
      }
    }
    super.visitAnnotation(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (surfaces.drift && _extendsType(node, 'Table')) {
      _DriftTable(this, node).emit();
    }
    if (surfaces.floor) {
      for (final annotation in node.metadata) {
        final name = _annotationName(annotation);
        if (name == 'Entity' || name == 'entity') {
          _emitFloorEntity(node, annotation);
        } else if (name == 'DatabaseView') {
          _emitFloorView(node, annotation);
        }
      }
    }
    super.visitClassDeclaration(node);
  }

  /// floor `@Entity(tableName: …)` — 이름이 없으면 클래스 이름이 테이블 이름이다.
  void _emitFloorEntity(ClassDeclaration node, Annotation annotation) {
    final className = node.namePart.typeName.lexeme;
    final table = _floorName(annotation, 'tableName', className);
    if (table == null) return;
    for (final field in node.body.members.whereType<FieldDeclaration>()) {
      if (field.isStatic || _hasAnnotation(field, const {'ignore', 'Ignore'})) {
        continue;
      }
      for (final variable in field.fields.variables) {
        _emitFloorColumn(className, table, field, variable);
      }
    }
  }

  void _emitFloorColumn(
    String className,
    String table,
    FieldDeclaration field,
    VariableDeclaration variable,
  ) {
    final columnInfo = field.metadata.where(
      (annotation) => _annotationName(annotation) == 'ColumnInfo',
    );
    final named = columnInfo.isEmpty
        ? null
        : _namedArgument(columnInfo.first, 'name');
    if (named != null && _literalValue(named) == null) {
      return scanner.emitDynamic(named);
    }
    final column = named == null ? variable.name.lexeme : _literalValue(named)!;
    scanner.emit(
      table,
      method: escapeName(column),
      offset: variable.name.offset,
      symbol: '$className.${variable.name.lexeme}',
    );
  }

  /// floor `@DatabaseView('SELECT …', viewName: …)` — 뷰 자신과 질의가 읽는 관계다.
  void _emitFloorView(ClassDeclaration node, Annotation annotation) {
    final positional = annotation.arguments?.arguments.whereType<Expression>();
    if (positional != null && positional.isNotEmpty) {
      _emitSqlArgument(positional.first);
    }
    _floorName(annotation, 'viewName', node.namePart.typeName.lexeme);
  }

  /// floor 이름 인자 또는 클래스 이름으로 관계 사실을 내고 채널을 돌려준다.
  String? _floorName(Annotation annotation, String key, String className) {
    final named = _namedArgument(annotation, key);
    if (named != null) {
      final value = _literalValue(named);
      if (named is StringLiteral) consumed.add(named);
      if (value == null) {
        scanner.emitDynamic(named);
        return null;
      }
      return _emitDeclared(escapeName(value), annotation, className);
    }
    return _emitDeclared(escapeName(className), annotation, className);
  }

  String _emitDeclared(String channel, AstNode at, String className) {
    scanner.emit(channel, offset: at.offset, symbol: className);
    return channel;
  }
}

/// drift `class Users extends Table` — 테이블 이름과 컬럼 getter를 읽는다.
final class _DriftTable {
  _DriftTable(this.visitor, this.node)
    : className = node.namePart.typeName.lexeme;

  final _GatedVisitor visitor;
  final ClassDeclaration node;
  final String className;

  _SchemaFileScanner get scanner => visitor.scanner;

  void emit() {
    final table = _tableChannel();
    if (table == null) return;
    for (final member in node.body.members) {
      if (member is MethodDeclaration && _isColumnGetter(member)) {
        _emitColumn(table, member.name, member.body);
      } else if (member is FieldDeclaration && !member.isStatic) {
        for (final variable in member.fields.variables) {
          final initializer = variable.initializer;
          if (initializer != null && _isColumnBuilder(initializer)) {
            _emitColumn(table, variable.name, initializer);
          }
        }
      }
    }
  }

  /// `String get tableName => 'x'` 재정의 또는 검증된 snake_case 파생이다.
  String? _tableChannel() {
    final getter = node.body.members.whereType<MethodDeclaration>().where(
      (m) => m.isGetter && m.name.lexeme == 'tableName',
    );
    if (getter.isNotEmpty) {
      final expression = _returnedExpression(getter.first.body);
      final value = expression is StringLiteral ? expression.stringValue : null;
      if (value == null) {
        scanner.emitDynamic(getter.first);
        return null;
      }
      if (expression != null) visitor.consumed.add(expression);
      return _emitTable(escapeName(value));
    }
    final derived = _derive(className);
    if (derived == null) {
      scanner.counts.dynamicRelations++;
      scanner.emit(
        className,
        offset: node.namePart.typeName.offset,
        dynamic: true,
        symbol: className,
      );
      return null;
    }
    return _emitTable(derived);
  }

  String _emitTable(String channel) {
    scanner.emit(
      channel,
      offset: node.namePart.typeName.offset,
      symbol: className,
    );
    return channel;
  }

  /// 검증된 형태·설정일 때만 snake_case로 파생한다. 아니면 계수하고 null이다.
  String? _derive(String name) {
    if (scanner.context.driftNamingReason == null &&
        _driftSafeShape.hasMatch(name)) {
      return _snakeCase(name);
    }
    scanner.counts.driftUnverifiedNames++;
    return null;
  }

  void _emitColumn(String table, Token name, AstNode definition) {
    final named = _namedCall(definition);
    final column = named ?? _derive(name.lexeme);
    if (column == null) return;
    scanner.emit(
      table,
      method: escapeName(column),
      offset: name.offset,
      symbol: '$className.${name.lexeme}',
    );
  }

  /// 컬럼 정의 안의 `.named('x')` 리터럴이다.
  String? _namedCall(AstNode definition) {
    final finder = _NamedCallFinder();
    definition.accept(finder);
    if (finder.literal != null) visitor.consumed.add(finder.literal!);
    return finder.literal?.stringValue;
  }
}

bool _isColumnGetter(MethodDeclaration member) {
  final type = member.returnType;
  return member.isGetter &&
      !member.isStatic &&
      type is NamedType &&
      type.name.lexeme.endsWith('Column');
}

/// `integer().named('x')()` 같은 drift 빌더 사슬인지 뿌리 호출 이름으로 본다.
bool _isColumnBuilder(Expression expression) {
  Expression? current = expression;
  while (current != null) {
    if (current is FunctionExpressionInvocation) {
      current = current.function;
    } else if (current is MethodInvocation) {
      if (current.target == null) {
        return _driftColumnBuilders.contains(current.methodName.name);
      }
      current = current.target;
    } else {
      return false;
    }
  }
  return false;
}

final class _NamedCallFinder extends RecursiveAstVisitor<void> {
  StringLiteral? literal;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final arguments = node.argumentList.arguments.whereType<Expression>();
    if (node.methodName.name == 'named' &&
        arguments.isNotEmpty &&
        arguments.first is StringLiteral &&
        (arguments.first as StringLiteral).stringValue != null) {
      literal ??= arguments.first as StringLiteral;
    }
    super.visitMethodInvocation(node);
  }
}

/// `=> expr` 또는 단일 `return expr;` 본문의 식이다.
Expression? _returnedExpression(FunctionBody body) {
  if (body is ExpressionFunctionBody) return body.expression;
  if (body is BlockFunctionBody) {
    final statements = body.block.statements;
    if (statements.length == 1 && statements.first is ReturnStatement) {
      return (statements.first as ReturnStatement).expression;
    }
  }
  return null;
}

bool _extendsType(ClassDeclaration node, String type) =>
    node.extendsClause?.superclass.name.lexeme == type;

String _annotationName(Annotation annotation) => switch (annotation.name) {
  PrefixedIdentifier(:final identifier) => identifier.name,
  final Identifier name => name.name,
};

bool _hasAnnotation(AnnotatedNode node, Set<String> names) => node.metadata.any(
  (annotation) => names.contains(_annotationName(annotation)),
);

Expression? _namedArgument(Annotation annotation, String name) {
  for (final argument
      in annotation.arguments?.arguments.whereType<NamedArgument>() ??
          const <NamedArgument>[]) {
    if (argument.name.lexeme == name) return argument.argumentExpression;
  }
  return null;
}

/// 보간 문자열의 첫 리터럴 조각이다 — 비어 있으면 null.
String? _interpolationPrefix(StringLiteral literal) {
  final first = switch (literal) {
    StringInterpolation(:final firstString) => firstString.value,
    AdjacentStrings(:final strings) when strings.isNotEmpty =>
      strings.first is SimpleStringLiteral
          ? (strings.first as SimpleStringLiteral).value
          : (strings.first is StringInterpolation
                ? (strings.first as StringInterpolation).firstString.value
                : ''),
    _ => '',
  };
  return first.isEmpty ? null : first;
}

/// 부분 트리의 문자열 리터럴 노드를 모은다.
final class _LiteralCollector extends RecursiveAstVisitor<void> {
  _LiteralCollector(this.into);

  final Set<AstNode> into;

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) => into.add(node);

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    into.add(node);
    super.visitAdjacentStrings(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    into.add(node);
    super.visitStringInterpolation(node);
  }
}

/// 어느 게이트로도 소비되지 않은 리터럴 — strict 모드(대문자 SQL)로만 발화한다.
final class _LiteralVisitor extends RecursiveAstVisitor<void> {
  _LiteralVisitor(this.scanner, this.consumed);

  final _SchemaFileScanner scanner;
  final Set<AstNode> consumed;

  @override
  void visitImportDirective(ImportDirective node) {}

  @override
  void visitExportDirective(ExportDirective node) {}

  @override
  void visitPartDirective(PartDirective node) {}

  @override
  void visitPartOfDirective(PartOfDirective node) {}

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) => _visit(node);

  @override
  void visitAdjacentStrings(AdjacentStrings node) => _visit(node);

  @override
  void visitStringInterpolation(StringInterpolation node) {
    // 보간 전체를 이미 읽었거나 동적 사실로 냈으면 안쪽 조각을 다시 읽지 않는다.
    if (!_visit(node)) super.visitStringInterpolation(node);
  }

  /// 리터럴을 읽고, 소비됐거나 사실을 냈으면 true를 돌려준다.
  bool _visit(StringLiteral node) {
    if (consumed.contains(node)) return true;
    final value = node.stringValue;
    if (value != null) {
      if (looksLikeSql(value, strict: true)) {
        scanner.emitSql(value, node, strict: true);
        return true;
      }
      if (looksLikeSql(value)) scanner.counts.skippedSqlLiterals++;
      return false;
    }
    final prefix = _interpolationPrefix(node);
    if (prefix == null) return false;
    if (looksLikeSql(prefix, strict: true)) {
      scanner.emitDynamic(node, channelPrefix: prefix);
      return true;
    }
    if (looksLikeSql(prefix)) scanner.counts.skippedSqlLiterals++;
    return false;
  }
}
