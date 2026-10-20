import 'package:dartograph/src/index/sql_relations.dart';
import 'package:test/test.dart';

/// kartograph·cartograph·rustograph와 같은 관계 추출 계약을 Dart 포트가
/// 지키는지 검증한다 — 기대값은 cartograph `SqlRelationsTests`와 같은 벡터다.
/// 관계가 아닌 세 경우(R1 함수 인자 안의 FROM, R2 같은 문장의 CTE 이름, R3
/// `IS [NOT] DISTINCT FROM`)는 persistence 생산자 계열의 공통 사례
/// ([_sharedCases])로 검증한다.
void main() {
  List<String> relations(String sql, {bool strict = false}) =>
      sqlRelations(sql, strict: strict).relations.map((r) => r.name).toList();

  // 관계 이름 집합과 미해석 0을 함께 본다 — 세 규칙이 막은 자리는 관계도
  // 미해석 피연산자도 아니다.
  void expectRelationSet(
    String sql,
    Set<String> expected, {
    bool strict = false,
  }) {
    final result = sqlRelations(sql, strict: strict);
    expect(result.relations.map((r) => r.name).toSet(), expected);
    expect(result.unresolved, 0);
  }

  test('테이블 값 함수는 관계가 아니고 미해석 근거를 남긴다', () {
    expect(relations("SELECT * FROM pragma_table_info('t')"), isEmpty);
    expect(
      relations(
        "SELECT * FROM users JOIN main.pragma_table_info('t') p ON true",
      ),
      ['users'],
    );
    expect(relations("SELECT * FROM pragma_table_info('t') AS p, users"), [
      'users',
    ]);
    expect(sqlRelations("SELECT * FROM pragma_table_info('t')").unresolved, 1);
  });

  test('기본 관계 키워드의 피연산자를 읽는다', () {
    expect(relations('SELECT * FROM users'), ['users']);
    expect(relations('SELECT * FROM users JOIN orders ON true'), [
      'users',
      'orders',
    ]);
    expect(relations('INSERT INTO users (id) VALUES (1)'), ['users']);
    expect(relations("UPDATE users SET name = 'x'"), ['users']);
    expect(relations('DELETE FROM users'), ['users']);
    expect(relations('SELECT * FROM s.t'), ['s.t']);
    expect(relations('SELECT * FROM `a.b`'), ['a%2Eb']);
  });

  test('쉼표 목록과 별칭을 읽는다', () {
    expect(relations('SELECT * FROM a, b'), ['a', 'b']);
    expect(relations('SELECT * FROM a x, b y'), ['a', 'b']);
    expect(relations('SELECT * FROM a AS x, b AS y'), ['a', 'b']);
  });

  test('문장 경계에서만 발화한다', () {
    expect(relations('UPDATE a SET x = 1; UPDATE b SET y = 2'), ['a', 'b']);
    expect(relations('please update the config'), isEmpty);
    expect(relations('GRANT SELECT ON TABLE metrics TO app'), ['metrics']);
    expect(relations('GRANT SELECT ON metrics TO app'), ['metrics']);
    expect(relations('REVOKE SELECT ON FUNCTION f FROM r'), isEmpty);
    expect(relations('grant select on the report to auditors'), isEmpty);
    expect(relations('grant access on staging to intern'), isEmpty);
    // 라벨(`name:`)은 문장 머리를 차지하지 않는다 — drift 명명 쿼리도 같다.
    expect(relations('markAdult:\nUPDATE users SET adult = 1'), ['users']);
    expect(relations('clearAll:\nTRUNCATE users'), ['users']);
    // 캐스트(`::`)는 라벨이 아니다.
    expect(relations('SELECT x::int FROM t'), ['t']);
  });

  test('산문은 관계를 만들지 않는다', () {
    expect(relations('the report into the folder'), isEmpty);
    expect(relations('merged the branch into main'), isEmpty);
    expect(relations('drop the table at noon'), isEmpty);
    expect(relations('turn the table over'), isEmpty);
  });

  test('하위 질의와 괄호를 따라간다', () {
    expect(relations('SELECT * FROM (SELECT * FROM a) x JOIN b ON true'), [
      'a',
      'b',
    ]);
    expect(relations('INSERT INTO a SELECT * FROM ignored_c'), [
      'a',
      'ignored_c',
    ]);
  });

  test('미해석 피연산자는 개수로 센다', () {
    final deleted = sqlRelations('DELETE FROM {} WHERE id = ?');
    expect(deleted.relations, isEmpty);
    expect(deleted.unresolved, 1);
    expect(sqlRelations('SELECT * FROM users').unresolved, 0);
    expect(sqlRelations('SELECT 1 FROM').unresolved, 1);
    expect(sqlRelations('SELECT * FROM {} JOIN ?').unresolved, 2);
  });

  test('SQL 형태 게이트가 산문을 걸러낸다', () {
    expect(looksLikeSql('SELECT * FROM t'), isTrue);
    expect(looksLikeSql('update t set x = 1'), isTrue);
    expect(looksLikeSql('please update the config'), isFalse);
    expect(looksLikeSql('a plain sentence'), isFalse);
    expect(looksLikeSql(''), isFalse);
  });

  test('strict 모드는 산문과 소문자 키워드를 거부한다', () {
    expect(
      looksLikeSql('Select an option from the menu', strict: true),
      isFalse,
    );
    expect(
      looksLikeSql('SELECT an option FROM the menu', strict: true),
      isTrue,
    );
    expect(relations('Select an option from the menu', strict: true), isEmpty);
    expect(relations('select * from users', strict: true), isEmpty);
    expect(relations('SELECT a FROM the'), isEmpty);
    expect(relations('select * from users'), ['users']);
  });

  test('키워드 위치는 UTF-16 오프셋이다', () {
    final result = sqlRelations('-- 한글 주석\nSELECT * FROM users');
    expect(result.relations.single.keyword, '-- 한글 주석\nSELECT * '.length);
  });

  test('이름 escape는 한정자와 한 세그먼트를 구분한다', () {
    expect(escapeQualified('main.users'), 'main.users');
    expect(escapeQualified('100%.t'), '100%25.t');
    expect(escapeName('a.b'), 'a%2Eb');
  });

  test('INTO·ON의 앞쪽 단어 판정은 본문이 ;인 토큰에서 끊긴다', () {
    expect(relations('INSERT "x" INTO t'), ['t']);
    // 포트 원본은 인용 여부를 보지 않고 본문으로 경계를 가른다.
    expect(relations('INSERT ";" INTO t'), isEmpty);
    expect(relations('INSERT INTO a; INTO b'), ['a']);
    expect(relations('CREATE INDEX i ON t'), ['t']);
    expect(relations('CREATE INDEX i ";" ON t'), isEmpty);
    expect(relations('CREATE RULE r AS ON INSERT TO t'), isEmpty);
    expect(relations('GRANT SELECT ";" ON t TO app'), isEmpty);
    expect(relations('GRANT "select" ON t TO app'), isEmpty);
    expect(relations('insert INTO t', strict: true), isEmpty);
    expect(relations('INSERT INTO t', strict: true), ['t']);
  });

  test('괄호 짝은 인용 괄호를 무시하고 닫히지 않으면 미해석이다', () {
    expect(relations('SELECT * FROM (SELECT * FROM a WHERE x = ")") y, b'), [
      'b',
      'a',
    ]);
    // 앞쪽의 짝 없는 `)`는 뒤의 `(` 짝에 영향을 주지 않는다.
    expect(relations('SELECT a) FROM (SELECT b FROM u) v, w'), ['w', 'u']);
    final unclosed = sqlRelations('SELECT * FROM (SELECT * FROM a');
    expect(unclosed.relations.map((r) => r.name), ['a']);
    expect(unclosed.unresolved, 1);
    final innerOnly = sqlRelations('SELECT * FROM ((SELECT 1) x');
    expect(innerOnly.relations, isEmpty);
    expect(innerOnly.unresolved, 1);
    expect(sqlRelations('SELECT * FROM f(').unresolved, 1);
    expect(
      sqlRelations('GRANT EXECUTE ON FUNCTION f(int) TO app').unresolved,
      0,
    );
    expect(
      sqlRelations('GRANT EXECUTE ON FUNCTION f(int TO app').unresolved,
      1,
    );
  });

  group('계열 공통 사례(R1~R3)', () {
    for (final shared in _sharedCases) {
      test(shared.id, () => expectRelationSet(shared.sql, shared.relations));
    }
  });

  group('계열 공통 규칙의 추가 사례', () {
    for (final extra in _extraCases) {
      test(extra.id, () {
        expectRelationSet(extra.sql, extra.relations, strict: extra.strict);
      });
    }
  });

  test('R1·R3이 막은 FROM 뒤의 자리표시자는 미해석으로 세지 않는다', () {
    final extract = sqlRelations('SELECT EXTRACT(EPOCH FROM ?) FROM t');
    expect(extract.relations.map((r) => r.name), ['t']);
    expect(extract.unresolved, 0);
    final distinct = sqlRelations(
      'SELECT * FROM t WHERE a IS DISTINCT FROM @a',
    );
    expect(distinct.relations.map((r) => r.name), ['t']);
    expect(distinct.unresolved, 0);
  });

  test('함수 인자 판정은 같은 문장에서 FROM을 감싼 가장 안쪽 괄호로 한다', () {
    // 함수 인자 안이어도 하위 질의 괄호의 FROM은 관계를 연다.
    expect(
      relations('SELECT EXTRACT(YEAR FROM (SELECT max(d) FROM t)) FROM u'),
      ['t', 'u'],
    );
    expect(
      relations(
        'SELECT count(*) FILTER (WHERE id IN '
        '(SELECT order_id FROM payments)) FROM orders',
      ),
      ['payments', 'orders'],
    );
    // 닫히지 않은 함수 괄호가 다음 문장의 FROM을 덮지 않는다.
    expect(relations('SELECT f(x; SELECT * FROM t'), ['t']);
  });

  test('이름 뒤 괄호도 SELECT·WITH로 시작하면 하위 질의라 FROM이 관계를 연다', () {
    expect(relations('SELECT * FROM t WHERE id = ANY (SELECT id FROM u)'), [
      't',
      'u',
    ]);
    expect(relations('SELECT ARRAY(SELECT id FROM u) FROM t'), ['u', 't']);
    expect(relations('SELECT ARRAY(WITH v AS (SELECT 1) SELECT id FROM u)'), [
      'u',
    ]);
  });

  test('CTE 이름을 내지 않아도 별칭과 쉼표 목록은 그대로 잇는다', () {
    expect(relations('WITH a AS (SELECT 1) SELECT * FROM a, b'), ['b']);
    expect(relations('WITH a AS (SELECT 1) SELECT * FROM a x, b y'), ['b']);
  });

  group('MB급 SQL도 문장·괄호 수에 비례하는 시간에 읽는다', () {
    // 기대값은 생성하면서 기록한 키워드 위치다(제품 함수로 계산하지 않는다).
    // 수정 전 구현은 키워드마다 앞쪽 토큰 전체를 복사하거나 괄호 끝까지 다시
    // 훑어 입력마다 수 초~수십 초가 걸렸다.
    for (final shape in _largeSqlShapes()) {
      test(shape.name, () {
        final stopwatch = Stopwatch()..start();
        final result = sqlRelations(shape.text);
        stopwatch.stop();
        expect([
          for (final r in result.relations) '${r.name}@${r.keyword}',
        ], shape.relations);
        expect(result.unresolved, shape.unresolved);
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 5)),
          reason: '${shape.text.length} UTF-16 units',
        );
      });
    }
  });
}

/// 시간 상한 회귀용 대형 SQL과 손으로 셀 수 있는 기대 결과다.
typedef _LargeSql = ({
  String name,
  String text,
  List<String> relations,
  int unresolved,
});

/// 문장이 많은 덤프·한 문장 안 키워드 반복·괄호 피연산자를 약 0.3~1.7MB로 만든다.
///
/// 크기는 수정 전 구현이 상한(5초)을 세 배쯤 넘고 지금 구현은 수십 ms에 끝나게
/// 골랐다.
List<_LargeSql> _largeSqlShapes() {
  _LargeSql build(
    String name,
    int count,
    void Function(StringBuffer text, List<String> relations, int i) write, {
    String prefix = '',
    int unresolvedPerItem = 0,
  }) {
    final text = StringBuffer(prefix);
    final relations = <String>[];
    for (var i = 0; i < count; i++) {
      write(text, relations, i);
    }
    return (
      name: name,
      text: text.toString(),
      relations: relations,
      unresolved: unresolvedPerItem * count,
    );
  }

  const depth = 80000;
  final open = 'SELECT a FROM (' * depth;
  return [
    build('INSERT 덤프', 20000, (text, relations, i) {
      relations.add('users_$i@${text.length + 'INSERT '.length}');
      text.write("INSERT INTO users_$i (id, name) VALUES (1, 'n');\n");
    }),
    build('CREATE INDEX 덤프', 27000, (text, relations, i) {
      relations.add('users_$i@${text.length + 'CREATE INDEX idx_$i '.length}');
      text.write('CREATE INDEX idx_$i ON users_$i (id);\n');
    }),
    build('닫히지 않은 괄호', 70000, unresolvedPerItem: 1, (text, _, _) {
      text.write('SELECT a FROM (SELECT b ');
    }),
    build('한 문장 안 INTO 반복', 30000, prefix: 'INSERT ', (text, relations, i) {
      relations.add('t_$i@${text.length}');
      text.write('INTO t_$i ');
    }),
    build('한 문장 안 ON 반복', 30000, prefix: 'CREATE INDEX i ', (
      text,
      relations,
      i,
    ) {
      relations.add('t_$i@${text.length}');
      text.write('ON t_$i ');
    }),
    // 닫힌 중첩 괄호 — 바깥 FROM마다 안쪽 전체를 건너뛴다.
    (
      name: '닫힌 중첩 괄호',
      text: '${open}SELECT 1 FROM t${') x' * depth}',
      relations: ['t@${open.length + 'SELECT 1 '.length}'],
      unresolved: 0,
    ),
  ];
}

/// SQL 관계 추출 사례 하나다 — relations는 순서·중복을 보지 않는 집합이다.
typedef _SharedCase = ({String id, String sql, Set<String> relations});

/// persistence 생산자 계열의 공통 사례 14개다(R1 함수 인자 안의 FROM, R2 문장
/// 단위 CTE 이름, R3 `IS [NOT] DISTINCT FROM`).
///
/// 다른 생산자의 테스트와 isthmus conformance `sql-relations` 벡터가 같은 SQL과
/// 기대값을 쓴다. 공통 사례 파일에서 기계적으로 옮겼으니 손으로 고치지 않는다.
const _sharedCases = <_SharedCase>[
  (
    id: 'cte/simple',
    sql: 'WITH recent AS (SELECT * FROM orders) SELECT * FROM recent',
    relations: {'orders'},
  ),
  (
    id: 'cte/recursive-with-columns',
    sql:
        'WITH RECURSIVE tree(id, parent_id) AS (SELECT id, parent_id FROM nodes UNION ALL SELECT n.id, n.parent_id FROM nodes n JOIN tree t ON n.parent_id = t.id) SELECT * FROM tree',
    relations: {'nodes'},
  ),
  (
    id: 'cte/multiple-materialized',
    sql:
        'WITH a AS (SELECT 1), b AS MATERIALIZED (SELECT * FROM orders) SELECT * FROM a JOIN b ON true',
    relations: {'orders'},
  ),
  (
    id: 'cte/not-materialized',
    sql: 'WITH c AS NOT MATERIALIZED (SELECT * FROM orders) SELECT * FROM c',
    relations: {'orders'},
  ),
  (
    id: 'cte/insert-select',
    sql:
        'WITH staged AS (SELECT * FROM imports) INSERT INTO orders SELECT * FROM staged',
    relations: {'imports', 'orders'},
  ),
  (
    id: 'cte/scope-is-one-statement',
    sql: 'WITH recent AS (SELECT 1) SELECT * FROM recent; SELECT * FROM recent',
    relations: {'recent'},
  ),
  (
    id: 'function-from/extract',
    sql: 'SELECT EXTRACT(YEAR FROM created_at) FROM orders',
    relations: {'orders'},
  ),
  (
    id: 'function-from/trim',
    sql: "SELECT TRIM(BOTH ' ' FROM name) FROM users",
    relations: {'users'},
  ),
  (
    id: 'function-from/substring',
    sql: 'SELECT SUBSTRING(name FROM 2 FOR 3) FROM users',
    relations: {'users'},
  ),
  (
    id: 'subquery/derived-table-still-fires',
    sql: 'SELECT * FROM (SELECT * FROM orders) AS sub',
    relations: {'orders'},
  ),
  (
    id: 'subquery/scalar-still-fires',
    sql: 'SELECT (SELECT max(id) FROM users) FROM orders',
    relations: {'users', 'orders'},
  ),
  (
    id: 'subquery/in-select-still-fires',
    sql: 'SELECT * FROM orders WHERE id IN (SELECT order_id FROM payments)',
    relations: {'orders', 'payments'},
  ),
  (
    id: 'distinct-from/is',
    sql: 'SELECT * FROM events WHERE a IS DISTINCT FROM b',
    relations: {'events'},
  ),
  (
    id: 'distinct-from/is-not',
    sql: 'SELECT * FROM events WHERE a IS NOT DISTINCT FROM b',
    relations: {'events'},
  ),
];

/// [_SharedCase]에 strict 모드 여부를 더한 사례다.
typedef _ExtraCase = ({
  String id,
  String sql,
  Set<String> relations,
  bool strict,
});

/// 공통 사례에 더한 dartograph 사례다 — 기대값은 손으로 검증했다.
const _extraCases = <_ExtraCase>[
  // CTE 본문이 읽는 관계는 그대로다. MATERIALIZED 뒤 괄호도 함수 인자가 아니다.
  (
    id: 'cte/delete-body',
    sql: 'WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d',
    relations: {'t'},
    strict: false,
  ),
  (
    id: 'cte/materialized-delete-body',
    sql: 'WITH d AS MATERIALIZED (DELETE FROM t RETURNING *) SELECT * FROM d',
    relations: {'t'},
    strict: false,
  ),
  // `$1`은 이 어휘기에서 이름 토큰이다 — 비교 연산자의 피연산자일 뿐이다.
  (
    id: 'distinct-from/placeholder',
    sql: r'SELECT * FROM events WHERE kind IS DISTINCT FROM $1',
    relations: {'events'},
    strict: false,
  ),
  // CTE 이름은 그것을 정의한 문장 안에서만 거른다 — 첫 문장이 아니어도 같다.
  (
    id: 'cte/defined-in-later-statement',
    sql: 'SELECT * FROM orders; WITH recent AS (SELECT 1) SELECT * FROM recent',
    relations: {'orders'},
    strict: false,
  ),
  // 규칙은 문장 단위라 CTE 본문이 같은 이름의 실제 테이블을 읽어도 그 문장에서는
  // 내지 않는다 — 계열 생산자와 같은 판정이다(알려진 손실).
  (
    id: 'cte/statement-scope-covers-body',
    sql: 'WITH users AS (SELECT * FROM users WHERE active) SELECT * FROM users',
    relations: <String>{},
    strict: false,
  ),
  // 비인용 이름끼리는 대소문자를 무시하고, 인용 이름은 그대로 비교한다.
  (
    id: 'cte/unquoted-names-ignore-case',
    sql: 'WITH Recent AS (SELECT 1) SELECT * FROM recent',
    relations: <String>{},
    strict: false,
  ),
  (
    id: 'cte/quoted-name-keeps-case',
    sql: 'WITH "Recent" AS (SELECT 1) SELECT * FROM recent',
    relations: {'recent'},
    strict: false,
  ),
  // 한정 이름은 CTE가 아니다 — 끝 세그먼트든 한정자든 CTE 이름과 같아도 그렇다.
  (
    id: 'cte/qualified-name-is-not-cte',
    sql: 'WITH recent AS (SELECT 1) SELECT * FROM s.recent',
    relations: {'s.recent'},
    strict: false,
  ),
  (
    id: 'cte/qualifier-is-not-cte',
    sql: 'WITH s AS (SELECT 1) SELECT * FROM s.recent',
    relations: {'s.recent'},
    strict: false,
  ),
  // 게이트 없는 리터럴(strict)에서도 같다. strict의 대문자 게이트는 관계 키워드의
  // 발화만 막고, 세 규칙의 판정 단어는 대소문자를 보지 않는다.
  (
    id: 'cte/strict',
    sql: 'WITH recent AS (SELECT * FROM orders) SELECT * FROM recent',
    relations: {'orders'},
    strict: true,
  ),
  (
    id: 'function-from/strict-lowercase-function',
    sql: 'SELECT extract(year FROM created_at) FROM orders',
    relations: {'orders'},
    strict: true,
  ),
  (
    id: 'distinct-from/strict-lowercase-operator',
    sql: 'SELECT * FROM events WHERE a is not distinct FROM b',
    relations: {'events'},
    strict: true,
  ),
];
