import 'package:dartograph/src/index/sql_relations.dart';
import 'package:test/test.dart';

/// kartograph·cartograph·rustograph와 같은 관계 추출 계약을 Dart 포트가
/// 지키는지 검증한다 — 기대값은 cartograph `SqlRelationsTests`와 같은 벡터다.
void main() {
  List<String> relations(String sql, {bool strict = false}) =>
      sqlRelations(sql, strict: strict).relations.map((r) => r.name).toList();

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
