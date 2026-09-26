/// SQL 텍스트에서 관계(테이블·뷰) 이름을 읽는 어휘 기반 추출기다.
///
/// kartograph `SqlRelations.kt`·cartograph `SqlRelations.swift`의 포트다 —
/// 알고리즘·게이트·미해석 계수 규칙을 같이 유지한다. 생산자마다 같은 SQL을
/// 다르게 읽으면 isthmus persistence 조인 결과가 생산자 언어에 따라 달라지기
/// 때문이다. 오프셋은 Dart 문자열의 UTF-16 code unit 위치다.
library;

/// SQL 어휘 하나다 — 인용된 식별자는 키워드가 아니다.
///
/// [offset]은 원문의 UTF-16 위치로, 같은 키워드의 피연산자 목록 안에서 같은
/// 이름을 두 번 내지 않는 dedup 키의 일부이자 사실 위치 계산의 근거다.
final class SqlToken {
  /// 어휘 하나를 만든다.
  const SqlToken(this.text, {required this.quoted, required this.offset});

  /// 인용 부호를 벗긴 어휘 본문이다.
  final String text;

  /// `"…"`·`` `…` ``·`[…]`로 인용된 식별자인지 여부다.
  final bool quoted;

  /// 원문에서의 UTF-16 시작 위치다.
  final int offset;
}

/// 관계 이름 하나와 그것을 연 키워드 토큰의 원문 위치다.
typedef SqlRelation = ({String name, int keyword});

/// SQL 텍스트를 어휘로 나눈다 — 인용 식별자는 내용을 보존하고 그 외엔
/// 식별자 문자열과 단일 기호 토큰만 만든다.
///
/// `;`는 문장 경계로, `{}`·`$`·`?`·`:`·`@` 같은 플레이스홀더 기호는 미해석
/// 피연산자 계수를 위해 토큰으로 남긴다.
List<SqlToken> lexSql(String text) {
  final tokens = <SqlToken>[];
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c == '"' || c == '`' || c == '[') {
      final end = c == '[' ? ']' : c;
      var j = i + 1;
      while (j < text.length && text[j] != end) {
        j++;
      }
      tokens.add(SqlToken(text.substring(i + 1, j), quoted: true, offset: i));
      i = j + 1;
    } else if (_isIdentStart(text.codeUnitAt(i))) {
      var j = i + 1;
      while (j < text.length && _isIdentPart(text.codeUnitAt(j))) {
        j++;
      }
      tokens.add(SqlToken(text.substring(i, j), quoted: false, offset: i));
      i = j;
    } else if (c == '-' && i + 1 < text.length && text[i + 1] == '-') {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < text.length && text[i + 1] == '*') {
      i += 2;
      while (i + 1 < text.length && !(text[i] == '*' && text[i + 1] == '/')) {
        i++;
      }
      i += 2;
    } else if (c == "'") {
      i = _skipStringLiteral(text, i + 1);
    } else {
      if (_symbolTokens.contains(c)) {
        tokens.add(SqlToken(c, quoted: false, offset: i));
      }
      i++;
    }
  }
  return tokens;
}

/// 문자열 리터럴은 이름이 아니다 — `''`와 `\'`는 escape다. 닫힌 뒤 위치를 돌려준다.
int _skipStringLiteral(String text, int start) {
  var i = start;
  while (i < text.length) {
    if (text[i] == r'\') {
      i += 2;
      continue;
    }
    if (text[i] == "'" && i + 1 < text.length && text[i + 1] == "'") {
      i += 2;
      continue;
    }
    if (text[i] == "'") return i + 1;
    i++;
  }
  return i;
}

const _symbolTokens = {'.', ',', '(', ')', ';', '{', '}', r'$', '?', ':', '@'};
const _placeholderSymbols = {'{', '}', r'$', '?', ':', '@'};

/// SQL 문을 여는 강한 동사가 있는지 본다.
///
/// 관계 키워드와 겹치는 update·truncate는 문장 머리일 때만 인정한다. [strict]는
/// 게이트 없는 문자열 리터럴용으로, 동사가 대문자일 때만 인정해 산문을 거른다.
bool looksLikeSql(String text, {bool strict = false}) {
  var head = true;
  for (final token in lexSql(text)) {
    if (!_isNameToken(token)) continue;
    final upper = token.text == token.text.toUpperCase();
    if (_isSqlVerb(token.text) && (!strict || upper)) return true;
    if (head) {
      head = false;
      final lower = token.text.toLowerCase();
      if ((lower == 'update' || lower == 'truncate') && (!strict || upper)) {
        return true;
      }
    }
  }
  return false;
}

/// SQL 텍스트에서 관계 이름을 읽는다.
///
/// 한정 이름(`schema.table`)은 그대로 두고, 이름 자체에 점이 있는 인용
/// 식별자(`"a.b"`)는 한 세그먼트로 escape한다. `unresolved`는 관계 자리의
/// 피연산자를 읽지 못한 횟수다 — `FROM {}` 같은 플레이스홀더를 사실 없이
/// 조용히 넘기지 않기 위해서다.
({List<SqlRelation> relations, int unresolved}) sqlRelations(
  String text, {
  bool strict = false,
}) {
  final tokens = lexSql(text);
  final scan = _RelationScan(tokens, strict: strict);
  for (var i = 0; i < tokens.length; i++) {
    scan.visitKeyword(i);
  }
  return (relations: scan.out, unresolved: scan.unresolved);
}

/// [sqlRelations]의 한 번 스캔 상태다 — 원본의 지역 변수·중첩 함수를 필드와
/// 메서드로 옮겼다. 규칙 자체는 포트 원본과 한 줄씩 대응한다.
final class _RelationScan {
  _RelationScan(this.tokens, {required this.strict})
    : consumed = List.filled(tokens.length, false),
      stmtHead = List.filled(tokens.length, false),
      stmtVerb = List.filled(tokens.length, null) {
    _markStatements();
  }

  final List<SqlToken> tokens;
  final bool strict;
  final List<bool> consumed;

  /// `;`로 갈리는 각 문장의 머리 식별자 위치다.
  final List<bool> stmtHead;

  /// 각 토큰이 속한 문장의 (대문자 게이트를 통과한) 동사다.
  final List<String?> stmtVerb;
  final out = <SqlRelation>[];

  /// 같은 키워드의 피연산자 목록 안에서만 중복을 막는 키다(`FROM a, a`).
  final seen = <String>{};
  var unresolved = 0;

  /// strict 모드는 관계 키워드와 동사가 모두 대문자일 때만 발화한다.
  bool upperOk(SqlToken token) =>
      !strict || token.text == token.text.toUpperCase();

  bool _isSymbol(int index, String symbol) =>
      index < tokens.length &&
      !tokens[index].quoted &&
      tokens[index].text == symbol;

  /// 문장 머리와 동사를 표시한다. 문장 머리의 `ident :`는 SQLDelight 라벨이라
  /// 머리를 차지하지 않고 다음 식별자가 머리가 된다(`::` 캐스트는 라벨이 아니다).
  void _markStatements() {
    var pending = true;
    String? verb;
    var i = 0;
    while (i < tokens.length) {
      final token = tokens[i];
      if (_isSymbol(i, ';')) {
        pending = true;
        verb = null;
        i++;
        continue;
      }
      if (_isNameToken(token) && pending) {
        if (_isSymbol(i + 1, ':') && !_isSymbol(i + 2, ':')) {
          i += 2;
          continue;
        }
        stmtHead[i] = true;
        verb = upperOk(token) ? token.text.toLowerCase() : null;
        pending = false;
      }
      stmtVerb[i] = verb;
      i++;
    }
  }

  /// [end] 앞쪽으로 같은 문장 안의 토큰들이다.
  Iterable<SqlToken> segmentBefore(int end) =>
      tokens.sublist(0, end).reversed.takeWhile((token) => token.text != ';');

  /// [start]부터 같은 문장 안에 대문자 게이트를 통과한 단어 [word]가 있는지 본다.
  bool segmentAfterHas(int start, String word) => tokens
      .skip(start)
      .takeWhile((token) => token.text != ';')
      .any(
        (token) =>
            !token.quoted && token.text.toLowerCase() == word && upperOk(token),
      );

  bool _precededBy(int index, bool Function(String lower) test) =>
      segmentBefore(index).any(
        (token) =>
            !token.quoted && upperOk(token) && test(token.text.toLowerCase()),
      );

  /// 키워드 토큰이 현재 문맥에서 관계 자리를 여는지 판정한다.
  bool _fires(int i, String word, bool grantStmt) {
    switch (word) {
      // 산문 "update the .."·upsert의 `DO UPDATE SET`을 막는다.
      case 'update':
        return stmtHead[i] && segmentAfterHas(i + 1, 'set');
      case 'truncate':
        return stmtHead[i];
      // "merged the branch into main" 같은 산문을 막는다.
      case 'into':
        return _precededBy(
          i,
          (lower) =>
              const {'insert', 'select', 'merge', 'replace'}.contains(lower),
        );
      case 'table':
        return _tableKeywordContext(i);
      // `GRANT .. ON t`와 `CREATE INDEX/TRIGGER/POLICY .. ON t`만 관계 자리다.
      // CREATE RULE의 ON은 이벤트 자리라 제외한다.
      case 'on':
        final grantOn = grantStmt && _precededBy(i, _isGrantPriv);
        final createOn =
            stmtVerb[i] == 'create' &&
            _precededBy(
              i,
              (lower) => const {'index', 'trigger', 'policy'}.contains(lower),
            );
        return grantOn || createOn;
      // grant·revoke의 FROM은 권한 주체 자리다.
      case 'from':
      case 'join':
        return !grantStmt;
      default:
        return true;
    }
  }

  /// `table` 토큰은 직전 비인용 식별자가 DDL 동사일 때만 키워드다.
  bool _tableKeywordContext(int i) {
    for (var k = i - 1; k >= 0; k--) {
      if (!_isNameToken(tokens[k])) continue;
      if (strict && tokens[k].text != tokens[k].text.toUpperCase()) {
        return false;
      }
      return const {
        'alter',
        'drop',
        'create',
        'truncate',
        'rename',
        'lock',
        'unlock',
        'describe',
        'desc',
        'analyze',
        'vacuum',
      }.contains(tokens[k].text.toLowerCase());
    }
    return false;
  }

  /// 한 토큰이 관계 키워드면 뒤의 피연산자 목록을 읽는다.
  void visitKeyword(int i) {
    final keyword = tokens[i];
    if (consumed[i] ||
        keyword.quoted ||
        !_isRelationKeyword(keyword.text) ||
        !upperOk(keyword)) {
      return;
    }
    final word = keyword.text.toLowerCase();
    final grantStmt = stmtVerb[i] == 'grant' || stmtVerb[i] == 'revoke';
    if (!_fires(i, word, grantStmt)) return;
    var j = i + 1;
    // ONLY·IF NOT EXISTS 같은 수식어를 건너뛴다. `table`은 TRUNCATE 뒤에서만.
    while (j < tokens.length &&
        !tokens[j].quoted &&
        _isNameModifier(tokens[j].text, afterTruncate: word == 'truncate')) {
      consumed[j] = true;
      j++;
    }
    if (word == 'on' && grantStmt) {
      final next = _skipGrantObjectKind(j);
      if (next == null) return;
      j = next;
    }
    if (j >= tokens.length) {
      unresolved++; // 이름이 없는 키워드 — "SELECT ... FROM" 꼴.
      return;
    }
    _readOperands(j, keyword, bufferedGrant: word == 'on' && grantStmt);
  }

  /// GRANT/REVOKE ON 뒤의 객체 종류어를 처리한다. 테이블 계열이면 이름 위치를,
  /// 비테이블 권한 객체면 이름까지 삼키고 null을 돌려준다(사실을 내지 않는다).
  int? _skipGrantObjectKind(int j) {
    if (j >= tokens.length || tokens[j].quoted) return j;
    final kind = tokens[j].text.toLowerCase();
    if (_grantTableKinds.contains(kind)) {
      var k = j;
      while (k < tokens.length &&
          _grantTableKinds.contains(tokens[k].text.toLowerCase())) {
        consumed[k] = true;
        k++;
      }
      return k;
    }
    if (!_grantNonTableKinds.contains(kind)) return j;
    var k = j;
    while (k < tokens.length) {
      final token = tokens[k];
      if (!token.quoted && token.text == '(') {
        final next = _skipParens(tokens, k);
        if (next == null) {
          unresolved++; // 닫히지 않은 괄호.
          break;
        }
        k = next;
      } else if (_isNameToken(token) || (!token.quoted && token.text == '.')) {
        consumed[k] = true;
        k++;
      } else {
        // 플레이스홀더 피연산자(`ON SEQUENCE {s}`)는 읽히지 않은 근거다.
        if (!token.quoted && _placeholderSymbols.contains(token.text)) {
          unresolved++;
        }
        break;
      }
    }
    return null;
  }

  /// 쉼표로 이어지는 피연산자 목록(`FROM a, b`)을 읽는다 — 괄호 피연산자는
  /// 통째로 건너뛰고(안쪽 관계는 그 안의 키워드가 읽는다) 별칭은 삼킨다.
  void _readOperands(
    int start,
    SqlToken keyword, {
    required bool bufferedGrant,
  }) {
    final buffer = <String>[];
    var j = start;
    var endPos = j;
    while (j < tokens.length) {
      int operandEnd;
      if (_isSymbol(j, '(')) {
        final next = _skipParens(tokens, j);
        if (next == null) {
          unresolved++; // 닫히지 않은 괄호.
          break;
        }
        operandEnd = next;
      } else {
        final read = _readQualifiedName(tokens, j);
        if (read == null) {
          // 이름 자리에 절 키워드가 오는 것은 정상 종료다 — 플레이스홀더 등
          // 읽히지 않는 피연산자만 미해석으로 센다.
          final clauseNext =
              j < tokens.length &&
              _isNameToken(tokens[j]) &&
              _isClauseWord(tokens[j].text);
          if (!clauseNext) unresolved++;
          break;
        }
        if (bufferedGrant) {
          buffer.add(read.name);
        } else {
          _emit(read.name, keyword);
        }
        for (var c = j; c < read.next; c++) {
          consumed[c] = true;
        }
        operandEnd = read.next;
      }
      final k = _skipAlias(operandEnd);
      endPos = k;
      if (_isSymbol(k, ',')) {
        j = k + 1;
        continue;
      }
      break;
    }
    if (bufferedGrant && _grantTerminatorAt(endPos)) {
      for (final name in buffer) {
        _emit(name, keyword);
      }
    }
  }

  /// `AS alias` 또는 쉼표 직전 별칭(`FROM users u, ..`)을 건너뛴다.
  int _skipAlias(int operandEnd) {
    var k = operandEnd;
    if (k < tokens.length &&
        !tokens[k].quoted &&
        tokens[k].text.toLowerCase() == 'as' &&
        k + 1 < tokens.length &&
        _isNameToken(tokens[k + 1])) {
      k += 2;
    } else if (k < tokens.length &&
        _isNameToken(tokens[k]) &&
        _isSymbol(k + 1, ',')) {
      k += 1;
    }
    for (var c = operandEnd; c < k; c++) {
      consumed[c] = true;
    }
    return k;
  }

  /// GRANT 피연산자 뒤가 TO·FROM·`;`·끝이어야 산문이 아닌 GRANT 형태다.
  bool _grantTerminatorAt(int endPos) {
    if (endPos >= tokens.length) return true;
    final token = tokens[endPos];
    return !token.quoted &&
        const {'to', 'from', ';'}.contains(token.text.toLowerCase());
  }

  void _emit(String name, SqlToken keyword) {
    if (seen.add('${keyword.offset} $name')) {
      out.add((name: name, keyword: keyword.offset));
    }
  }
}

const _grantTableKinds = {'table', 'tables', 'view', 'materialized'};
const _grantNonTableKinds = {
  'all',
  'sequence',
  'schema',
  'database',
  'domain',
  'type',
  'function',
  'procedure',
  'routine',
  'foreign',
  'server',
  'wrapper',
  'language',
  'large',
  'publication',
  'subscription',
  'statistics',
  'tablespace',
  'collation',
  'conversion',
  'extension',
  'aggregate',
  'operator',
  'policy',
  'cast',
  'fdw',
  'parser',
  'template',
  'dictionary',
  'configuration',
};

/// 뒤따르는 식별자가 관계 이름인 키워드다.
bool _isRelationKeyword(String word) => const {
  'from',
  'join',
  'into',
  'update',
  'table',
  'truncate',
  'on',
}.contains(word.toLowerCase());

bool _isSqlVerb(String word) => const {
  'select',
  'insert',
  'delete',
  'create',
  'alter',
  'drop',
  'replace',
  'merge',
  'lock',
  'unlock',
  'rename',
  'describe',
  'desc',
  'analyze',
  'vacuum',
  'grant',
  'revoke',
}.contains(word.toLowerCase());

/// GRANT/REVOKE의 권한 단어인지 본다 — `ON`이 관계 자리임을 확정하는 근거다.
bool _isGrantPriv(String lower) => const {
  'select',
  'insert',
  'update',
  'delete',
  'truncate',
  'references',
  'trigger',
  'execute',
  'usage',
  'create',
  'connect',
  'temporary',
  'temp',
  'maintain',
  'all',
}.contains(lower);

/// 관계 키워드와 이름 사이에 올 수 있는 수식어다.
bool _isNameModifier(String word, {required bool afterTruncate}) {
  final lower = word.toLowerCase();
  return const {'only', 'if', 'not', 'exists'}.contains(lower) ||
      (afterTruncate && lower == 'table');
}

/// `(` 토큰부터 짝이 맞는 `)` 다음 위치를 돌려준다 — 닫히지 않으면 null.
int? _skipParens(List<SqlToken> tokens, int start) {
  var depth = 0;
  for (var k = start; k < tokens.length; k++) {
    final token = tokens[k];
    if (token.quoted) continue;
    if (token.text == '(') {
      depth++;
    } else if (token.text == ')') {
      depth--;
      if (depth == 0) return k + 1;
    }
  }
  return null;
}

/// 관계 이름 위치에 올 수 없는 SQL 절 키워드다. `table`은 `UPDATE table SET`
/// 때문에 제외하고, 산문 관사 `the`·`an`은 포함한다(`a`는 흔한 별칭이라 제외).
bool _isClauseWord(String word) => _clauseWords.contains(word.toLowerCase());

const _clauseWords = {
  'where', 'set', 'on', 'group', 'order', 'by', 'having', 'limit', 'offset', //
  'union', 'intersect', 'except', 'values', 'returning', 'as', 'left', //
  'right', 'inner', 'outer', 'full', 'cross', 'natural', 'lateral', 'using', //
  'and', 'or', 'not', 'null', 'select', 'insert', 'delete', 'from', 'join', //
  'into', 'update', 'truncate', 'with', 'for', 'in', 'is', 'case', 'when', //
  'then', 'else', 'end', 'distinct', 'asc', 'desc', 'if', 'exists', 'only', //
  'between', 'like', 'to', 'grant', 'revoke', 'option', 'cascade', //
  'restrict', 'privileges', 'the', 'an', //
};

/// `ident(.ident)*` 한정 이름을 읽어 (이름, 다음 위치)를 돌려준다.
({String name, int next})? _readQualifiedName(
  List<SqlToken> tokens,
  int start,
) {
  if (start >= tokens.length) return null;
  final first = tokens[start];
  if (first.quoted) {
    if (first.text.isEmpty) return null;
  } else if (!_isNameToken(first) || _isClauseWord(first.text)) {
    return null;
  }
  final name = StringBuffer(_escapeSegment(first));
  var i = start + 1;
  while (i + 1 < tokens.length && tokens[i].text == '.' && !tokens[i].quoted) {
    final next = tokens[i + 1];
    if (!next.quoted && (!_isNameToken(next) || _isClauseWord(next.text))) {
      break;
    }
    name.write('.${_escapeSegment(next)}');
    i += 2;
  }
  return (name: name.toString(), next: i);
}

/// 인용 세그먼트의 `%`와 `.`을 escape한다 — `"a.b"` 같은 한 식별자가
/// 한정자로 오독되지 않게 한다. 비인용 세그먼트는 점이 없어 `%`만 escape한다.
String _escapeSegment(SqlToken token) =>
    token.quoted ? escapeName(token.text) : token.text.replaceAll('%', '%25');

/// 한정 이름의 각 세그먼트를 escape해 합친다 — API 인자에서 온 이름도
/// `.`가 한정자라는 계약과 같게 맞춘다.
String escapeQualified(String name) =>
    name.split('.').map((segment) => segment.replaceAll('%', '%25')).join('.');

/// 이름 문자열 그대로를 한 세그먼트로 escape한다 — `tableName => 'a.b'` 같은
/// 값은 한정자가 아니라 한 식별자다.
String escapeName(String name) =>
    name.replaceAll('%', '%25').replaceAll('.', '%2E');

bool _isNameToken(SqlToken token) =>
    !token.quoted &&
    token.text.isNotEmpty &&
    _isIdentStart(token.text.codeUnitAt(0));

/// SQL 식별자 시작 문자인지 본다 — 비ASCII(서로게이트 포함)는 식별자로 본다.
bool _isIdentStart(int unit) =>
    unit == 0x5F || // _
    unit == 0x24 || // $
    (unit >= 0x61 && unit <= 0x7A) ||
    (unit >= 0x41 && unit <= 0x5A) ||
    unit >= 0x80;

bool _isIdentPart(int unit) =>
    _isIdentStart(unit) || (unit >= 0x30 && unit <= 0x39);
