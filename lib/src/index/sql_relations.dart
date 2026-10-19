/// SQL 텍스트에서 관계(테이블·뷰) 이름을 읽는 어휘 기반 추출기다.
///
/// kartograph `SqlRelations.kt`·cartograph `SqlRelations.swift`의 포트다 —
/// 알고리즘·게이트·미해석 계수 규칙을 같이 유지한다. 생산자마다 같은 SQL을
/// 다르게 읽으면 isthmus persistence 조인 결과가 생산자 언어에 따라 달라지기
/// 때문이다. 관계가 아닌 세 경우(R1 함수 인자 안의 FROM, R2 같은 문장의 CTE
/// 이름, R3 `IS [NOT] DISTINCT FROM`)도 persistence 생산자 계열의 공통 규칙과
/// 공통 사례를 따른다. 오프셋은 Dart 문자열의 UTF-16 code unit 위치다.
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
/// 조용히 넘기지 않기 위해서다. 같은 문장의 CTE 이름, `EXTRACT(YEAR FROM d)`
/// 같은 함수 인자 안의 FROM, `IS [NOT] DISTINCT FROM`의 피연산자는 관계 자리가
/// 아니므로 관계로도 미해석으로도 세지 않는다.
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
/// 메서드로 옮겼다. 규칙 자체는 포트 원본과 한 줄씩 대응한다. 다만 같은 문장의
/// 앞쪽 단어 판정과 괄호 짝은 원본처럼 키워드마다 다시 훑지 않고 한 번씩 미리
/// 계산한다 — 결과는 같고, 큰 SQL에서 시간이 2차로 늘지 않는다. 계열 공통
/// 규칙 R1~R3의 판정도 같은 이유로 생성자에서 한 번에 미리 계산한다.
final class _RelationScan {
  _RelationScan(this.tokens, {required this.strict})
    : consumed = List.filled(tokens.length, false),
      stmtHead = List.filled(tokens.length, false),
      stmtVerb = List.filled(tokens.length, null),
      _statement = List.filled(tokens.length, 0),
      _nonRelationFrom = List.filled(tokens.length, false) {
    _markStatements();
    _markRelationContexts();
  }

  final List<SqlToken> tokens;
  final bool strict;
  final List<bool> consumed;

  /// `;`로 갈리는 각 문장의 머리 식별자 위치다.
  final List<bool> stmtHead;

  /// 각 토큰이 속한 문장의 (대문자 게이트를 통과한) 동사다.
  final List<String?> stmtVerb;

  /// 각 토큰이 속한 문장(비인용 `;`로 나뉜 구간)의 번호다 — R2 CTE 이름의 범위다.
  final List<int> _statement;

  /// 관계 자리를 열지 않는 FROM 위치다 — 함수 인자 괄호 안(R1)이거나
  /// `IS [NOT] DISTINCT FROM` 비교 연산자의 일부(R3)다.
  final List<bool> _nonRelationFrom;

  /// 문장 번호마다 그 문장에서 정의한 CTE 이름의 비교 키다(R2, [_cteKey]).
  /// CTE가 없는 문장은 항목이 없다.
  final _cteNames = <int, Set<String>>{};
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

  /// 계열 공통 규칙 R1~R3의 판정을 한 번에 미리 계산한다 — 토큰마다 문장 번호,
  /// 문장마다 CTE 이름(R2), 관계 자리를 열지 않는 FROM(R1·R3)이다.
  ///
  /// 토큰을 앞에서부터 한 번만 지나고 재귀하지 않는다. CTE 정의는 이름 앞의
  /// WITH·쉼표에서 몇 토큰만 앞으로 보고(열 목록 괄호는 미리 맞춘 짝으로
  /// 건너뛴다) 판정하므로 본문 `(`에 닿기 전에 그 괄호가 CTE 본문임을 안다.
  /// 함수 인자 괄호(R1)는 같은 문장 안에서만 쌓는다 — 닫히지 않은 함수 괄호가
  /// 다음 문장의 FROM까지 덮지 않게 하려는 것이다.
  void _markRelationContexts() {
    // CTE 본문을 여는 `(` 위치다 — 함수 인자 괄호로 읽지 않는다.
    final cteBodies = <int>{};
    // 열린 비인용 `(`마다 함수 인자 괄호인지를 쌓는다. 끝이 가장 안쪽 괄호다.
    final functionArguments = <bool>[];
    var statement = 0;
    for (var k = 0; k < tokens.length; k++) {
      _statement[k] = statement;
      final token = tokens[k];
      if (token.quoted) continue;
      switch (token.text) {
        case ';':
          statement++;
          functionArguments.clear();
        case '(':
          functionArguments.add(
            !cteBodies.contains(k) && _opensFunctionArguments(k),
          );
        case ')':
          if (functionArguments.isNotEmpty) functionArguments.removeLast();
        case ',':
          _recordCte(k + 1, statement, cteBodies);
        default:
          final lower = token.text.toLowerCase();
          if (lower == 'from') {
            final inArguments =
                functionArguments.isNotEmpty && functionArguments.last;
            _nonRelationFrom[k] = inArguments || _isDistinctFrom(k);
          } else if (lower == 'with') {
            final name = _isWordAt(k + 1, 'recursive') ? k + 2 : k + 1;
            _recordCte(name, statement, cteBodies);
          }
      }
    }
  }

  /// [name]에서 `name [(cols)] AS [NOT] [MATERIALIZED] (`가 시작하면 그 이름을
  /// [statement]의 CTE 이름으로, 본문 `(` 위치를 [cteBodies]에 기록한다(R2).
  ///
  /// 본문 괄호는 앞 단어(`MATERIALIZED`)가 이름이어도 함수 인자가 아니다 —
  /// 그렇게 읽으면 `WITH d AS MATERIALIZED (DELETE FROM t …)`의 t를 잃는다.
  void _recordCte(int name, int statement, Set<int> cteBodies) {
    if (name >= tokens.length) return;
    final token = tokens[name];
    if (!_isNameToken(token) && !(token.quoted && token.text.isNotEmpty)) {
      return;
    }
    var k = name + 1;
    if (_isSymbol(k, '(')) {
      final columnsEnd = _skipParens(k);
      if (columnsEnd == null) return;
      k = columnsEnd;
    }
    if (!_isWordAt(k, 'as')) return;
    k++;
    if (_isWordAt(k, 'not')) k++;
    if (_isWordAt(k, 'materialized')) k++;
    if (!_isSymbol(k, '(')) return;
    _cteNames.putIfAbsent(statement, () => <String>{}).add(_cteKey(token));
    cteBodies.add(k);
  }

  /// [open] 위치의 `(`가 함수 인자 괄호인지 본다(R1).
  ///
  /// 바로 앞이 절 단어가 아닌 비인용 이름(함수 이름)이고, 그룹의 첫 토큰이
  /// 하위 질의를 여는 SELECT·WITH·VALUES가 아니어야 한다. `IN (`·`AS (`·
  /// `FROM (`처럼 절 단어 뒤의 괄호는 함수 호출이 아니다.
  bool _opensFunctionArguments(int open) {
    if (open == 0) return false;
    final callee = tokens[open - 1];
    if (!_isNameToken(callee) || _isClauseWord(callee.text)) return false;
    final head = open + 1;
    return head >= tokens.length ||
        tokens[head].quoted ||
        !_subqueryHeads.contains(tokens[head].text.toLowerCase());
  }

  /// [from] 위치의 FROM이 `IS [NOT] DISTINCT FROM` 비교 연산자의 일부인지 본다(R3).
  bool _isDistinctFrom(int from) =>
      _isWordAt(from - 1, 'distinct') &&
      (_isWordAt(from - 2, 'is') ||
          (_isWordAt(from - 2, 'not') && _isWordAt(from - 3, 'is')));

  /// [index]의 토큰이 대소문자와 상관없이 비인용 단어 [word]인지 본다.
  ///
  /// strict 모드의 대문자 게이트는 관계 키워드의 발화만 막는다 — R1~R3의 판정
  /// 단어는 두 모드 모두 대소문자를 보지 않는다.
  bool _isWordAt(int index, String word) =>
      index >= 0 &&
      index < tokens.length &&
      !tokens[index].quoted &&
      tokens[index].text.toLowerCase() == word;

  /// [start]부터 [next] 앞까지 읽은 피연산자가 같은 문장의 CTE 이름인지 본다(R2).
  /// 한정 이름(`s.recent`)은 CTE가 아니다.
  bool _isCteName(int start, int next) {
    if (next != start + 1) return false;
    final names = _cteNames[_statement[start]];
    return names != null && names.contains(_cteKey(tokens[start]));
  }

  /// 위치마다 같은 문장 앞쪽에 [test]를 통과한 단어가 있었는지를 담는다.
  ///
  /// 포트 원본의 `segmentBefore(i)`는 키워드마다 `i` 앞을 문장 경계까지 거꾸로
  /// 훑는다. 한 문장에 INTO·ON이 많으면 키워드마다 문장 머리까지 다시 훑어
  /// 2차가 되므로, 같은 판정을 앞에서부터 한 번에 누적한다. 경계는 원본처럼
  /// 인용 여부와 상관없이 본문이 `;`인 토큰이고, 그 토큰 자체는 판정에 넣지 않는다.
  List<bool> _precedingFlags(bool Function(String lower) test) {
    final flags = List.filled(tokens.length, false);
    var found = false;
    for (var k = 0; k < tokens.length; k++) {
      flags[k] = found;
      final token = tokens[k];
      if (token.text == ';') {
        found = false;
      } else if (!found &&
          !token.quoted &&
          upperOk(token) &&
          test(token.text.toLowerCase())) {
        found = true;
      }
    }
    return flags;
  }

  /// 같은 문장 앞쪽에 INSERT·SELECT·MERGE·REPLACE가 있었는지다(INTO 판정).
  late final List<bool> _intoVerbBefore = _precedingFlags(_isIntoVerb);

  /// 같은 문장 앞쪽에 GRANT/REVOKE 권한 단어가 있었는지다(GRANT ON 판정).
  late final List<bool> _grantPrivilegeBefore = _precedingFlags(_isGrantPriv);

  /// 같은 문장 앞쪽에 INDEX·TRIGGER·POLICY가 있었는지다(CREATE ON 판정).
  late final List<bool> _createOnKindBefore = _precedingFlags(_isCreateOnKind);

  /// 비인용 `(` 위치마다 짝이 맞는 `)` 다음 위치다 — 닫히지 않으면 null.
  late final List<int?> _parenEnds = _matchParens(tokens);

  /// `(` 토큰부터 짝이 맞는 `)` 다음 위치를 돌려준다 — 닫히지 않으면 null.
  /// 포트 원본의 `skipParens`와 같은 값을 미리 만든 표에서 읽는다.
  int? _skipParens(int start) => _parenEnds[start];

  /// [start]부터 같은 문장 안에 대문자 게이트를 통과한 단어 [word]가 있는지 본다.
  bool segmentAfterHas(int start, String word) => tokens
      .skip(start)
      .takeWhile((token) => token.text != ';')
      .any(
        (token) =>
            !token.quoted && token.text.toLowerCase() == word && upperOk(token),
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
        return _intoVerbBefore[i];
      case 'table':
        return _tableKeywordContext(i);
      // `GRANT .. ON t`와 `CREATE INDEX/TRIGGER/POLICY .. ON t`만 관계 자리다.
      // CREATE RULE의 ON은 이벤트 자리라 제외한다.
      case 'on':
        final grantOn = grantStmt && _grantPrivilegeBefore[i];
        final createOn = stmtVerb[i] == 'create' && _createOnKindBefore[i];
        return grantOn || createOn;
      // grant·revoke의 FROM은 권한 주체 자리다. 함수 인자 안의 FROM(R1,
      // `EXTRACT(YEAR FROM d)`)과 `IS [NOT] DISTINCT FROM`(R3)도 관계 자리가 아니다.
      case 'from':
        return !grantStmt && !_nonRelationFrom[i];
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
        final next = _skipParens(k);
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
        final next = _skipParens(j);
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
        for (var c = j; c < read.next; c++) {
          consumed[c] = true;
        }
        if (const {'from', 'join'}.contains(keyword.text.toLowerCase()) &&
            _isSymbol(read.next, '(')) {
          // 함수의 내부 관계를 추측하지 않고 미해석 근거를 남긴다.
          unresolved++;
          final end = _skipParens(read.next);
          if (end == null) break;
          operandEnd = end;
        } else {
          // R2: 같은 문장의 CTE 이름은 관계가 아니라 내지 않는다. 소비·별칭·쉼표
          // 목록 진행은 그대로 두어 뒤의 스캔이 바뀌지 않게 한다.
          if (!_isCteName(j, read.next)) {
            if (bufferedGrant) {
              buffer.add(read.name);
            } else {
              _emit(read.name, keyword);
            }
          }
          operandEnd = read.next;
        }
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

/// 같은 문장 앞에 있으면 INTO를 관계 자리로 만드는 동사인지 본다.
bool _isIntoVerb(String lower) =>
    const {'insert', 'select', 'merge', 'replace'}.contains(lower);

/// CREATE 문에서 뒤따르는 ON을 관계 자리로 만드는 객체 종류어인지 본다 —
/// CREATE RULE의 ON은 이벤트 자리라 `rule`은 넣지 않는다.
bool _isCreateOnKind(String lower) =>
    const {'index', 'trigger', 'policy'}.contains(lower);

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

/// 비인용 `(`마다 짝이 맞는 `)` 다음 위치를 한 번에 구한다 — 닫히지 않으면 null.
///
/// 포트 원본의 `skipParens`는 `(`부터 비인용 괄호 깊이를 세며 0이 되는 곳을
/// 찾는다. 같은 짝을 스택 한 번으로 맞추면 값이 같고, 닫히지 않거나 깊게 중첩된
/// 괄호에서 피연산자마다 텍스트 끝까지 다시 훑지 않는다. 스택이 빈 채로 만나는
/// `)`는 원본에서도 어떤 `(`의 깊이를 0으로 만들지 못하므로 버린다.
List<int?> _matchParens(List<SqlToken> tokens) {
  final ends = List<int?>.filled(tokens.length, null);
  final open = <int>[];
  for (var k = 0; k < tokens.length; k++) {
    final token = tokens[k];
    if (token.quoted) continue;
    if (token.text == '(') {
      open.add(k);
    } else if (token.text == ')' && open.isNotEmpty) {
      ends[open.removeLast()] = k + 1;
    }
  }
  return ends;
}

/// 괄호 그룹의 첫 토큰이면 그 그룹을 하위 질의로 만드는 단어다(R1) — 그 안의
/// FROM은 함수 인자가 아니라 관계 자리다.
const _subqueryHeads = {'select', 'with', 'values'};

/// CTE 이름과 한정자 없는 피연산자의 비교 키다(R2).
///
/// 비인용 이름은 소문자로 접고 인용 이름은 그대로 둔다 — SQL의 비인용 식별자
/// 접기이고, 계열 생산자·isthmus 참조 구현과 같은 비교다(계약은 대소문자가 다른
/// 경우를 정하지 않는다).
String _cteKey(SqlToken token) =>
    token.quoted ? token.text : token.text.toLowerCase();

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
