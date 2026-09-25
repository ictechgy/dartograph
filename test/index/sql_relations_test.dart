import 'package:dartograph/src/index/sql_relations.dart';
import 'package:test/test.dart';

/// kartograph·cartograph·rustograph와 같은 관계 추출 계약을 Dart 포트가
/// 지키는지 검증한다 — 기대값은 cartograph `SqlRelationsTests`와 같은 벡터다.
void main() {
  List<String> relations(String sql, {bool strict = false}) =>
      sqlRelations(sql, strict: strict).relations.map((r) => r.name).toList();

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
}
