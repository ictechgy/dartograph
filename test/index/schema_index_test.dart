import 'dart:io';

import 'package:dartograph/src/index/schema_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `schema` persistence 생산자의 표면·게이트·한계 계약이다.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('schema-index.');
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> write(String relative, String content) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  /// 사실을 비교하기 쉬운 `channel[.method]@line` 문자열로 줄인다.
  List<String> summarize(SchemaIndexResult result) => [
    for (final fact in result.facts)
      '${fact['dynamic'] == true ? '~' : ''}${fact['channel']}'
          '${fact['method'] == null ? '' : '#${fact['method']}'}'
          '@${(fact['location']! as Map)['line']}',
  ];

  test('sqflite SQL·테이블·컬럼 인자를 읽는다', () async {
    await write('lib/repo.dart', r'''
import 'package:sqflite/sqflite.dart';

class Repo {
  Repo(this.db);
  final Database db;
  Future<void> load() async {
    await db.rawQuery('SELECT * FROM users u JOIN orders o ON o.uid = u.id');
    await db.query('users', columns: ['id', 'name', 'COUNT(*)']);
    await db.insert('audit_log', {'actor': 'me'});
    await db.update('users', {'name': 'x'}, where: 'id = ?');
    await db.delete('sessions');
    await db.execute('CREATE TABLE IF NOT EXISTS settings (k TEXT)');
  }
}
''');

    final result = indexSchema(root.path);

    // 같은 위치의 사실은 channel 순으로 정렬된다.
    expect(summarize(result), [
      'orders@7',
      'users@7',
      'users@8',
      'users#id@8',
      'users#name@8',
      'audit_log@9',
      'audit_log#actor@9',
      'users@10',
      'users#name@10',
      'sessions@11',
      'settings@12',
    ]);
    expect(result.facts.first['symbol'], {'qualifiedName': 'Repo.load'});
    expect(result.facts.first['location'], {
      'path': 'lib/repo.dart',
      'line': 7,
      'column': 23,
    });
    expect(result.facts.first['kind'], 'relation-use');
    expect(result.limitations, isEmpty);
  });

  test('흔한 메서드 이름은 import 게이트와 테이블 이름 모양이 있어야 사실이 된다', () async {
    await write('lib/no_import.dart', r'''
class Client {
  void query(String s) {}
  void run() {
    query('users');
    this.query('orders');
  }
}
''');
    await write('lib/with_import.dart', r'''
import 'package:sqflite/sqflite.dart';

void run(Database db, dynamic http, Map<String, int> counts) {
  http.delete('https://example.com/a b');
  counts.update('users', (v) => v + 1);
}
''');

    final result = indexSchema(root.path);

    // import 없는 파일의 query는 다른 API다. 모양이 URL인 리터럴과 맵이 아닌
    // 두 번째 인자를 요구하지 않는 update 오판을 막는다.
    expect(summarize(result), ['users@5']);
    // `counts.update('users', fn)`은 sqflite update 모양(두 인자)이라 여전히
    // 관계로 읽힌다 — import 게이트 안의 남은 오탐 여지로 고정해 둔다.
    expect(
      result.facts.single['location'],
      containsPair('path', 'lib/with_import.dart'),
    );
  });

  test('구별되는 raw 메서드는 pubspec 의존성만으로도 게이트를 통과한다', () async {
    await write('pubspec.yaml', '''
name: app
dependencies:
  sqflite: any
''');
    await write('lib/helper.dart', r'''
import 'db.dart';

Future<void> run(Db db) async {
  await db.rawQuery('SELECT * FROM users');
  await db.query('orders');
}
''');

    final result = indexSchema(root.path);

    // rawQuery는 이름 자체가 근거지만 흔한 query는 파일 import가 필요하다.
    expect(summarize(result), ['users@4']);
  });

  test('상수 SQL은 호출 위치에서 한 번만 사실이 되고 재바인딩은 동적이다', () async {
    await write('lib/repo.dart', r'''
import 'package:sqflite/sqflite.dart';

const selectUsers = 'SELECT * FROM users';
const table = 'a';

void run(Database db, String name) {
  db.rawQuery(selectUsers);
  db.rawQuery('DELETE FROM $name WHERE id = 1');
  db.query(name);
}

void other() {
  const table = 'b';
}

void again(Database db) {
  db.query(table);
}
''');

    final result = indexSchema(root.path);

    expect(summarize(result), [
      'users@7',
      "~'DELETE FROM \$name WHERE id = 1'@8",
      '~name@9',
      '~table@17',
    ]);
    expect(result.facts[1]['channelPrefix'], 'DELETE FROM ');
    expect(
      result.limitations,
      contains(startsWith('dynamic-relation-names: 3 ')),
    );
  });

  test('sqlite3·postgres·drift custom 쿼리의 SQL 인자를 읽는다', () async {
    await write('lib/sqlite.dart', r'''
import 'package:sqlite3/sqlite3.dart';

void run(Database db) {
  db.execute('INSERT INTO events (id) VALUES (1)');
  db.select('SELECT * FROM events');
}
''');
    await write('lib/pg.dart', r'''
import 'package:postgres/postgres.dart';

Future<void> run(Connection conn) async {
  await conn.execute(Sql.named('SELECT * FROM accounts WHERE id = @id'));
  await conn.execute('TRUNCATE ledger');
}
''');
    await write('lib/db.dart', r'''
import 'package:drift/drift.dart';

abstract class AppDb {
  Future<void> wipe() => customStatement('DELETE FROM todo_items');
  Future<void> customStatement(String sql);
}
''');

    final result = indexSchema(root.path);

    expect(summarize(result), [
      'todo_items@4',
      'accounts@4',
      'ledger@5',
      'events@4',
      'events@5',
    ]);
  });

  test('drift Table은 재정의 이름·snake_case·named 컬럼을 싣는다', () async {
    await write('lib/tables.dart', r'''
import 'package:drift/drift.dart';

class TodoItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().named('headline')();
  late final isDone = boolean()();
  Set<Column> get primaryKey => {id};
}

class Categories extends Table {
  @override
  String get tableName => 'category_table';
  IntColumn get parentId => integer()();
}

class HTTPLogs extends Table {
  IntColumn get id => integer()();
}
''');

    final result = indexSchema(root.path);

    expect(summarize(result), [
      'todo_items@3',
      'todo_items#id@4',
      'todo_items#headline@5',
      'todo_items#is_done@6',
      'category_table@10',
      'category_table#parent_id@13',
      '~HTTPLogs@16',
    ]);
    expect(result.facts.first['symbol'], {'qualifiedName': 'TodoItems'});
    expect(
      result.limitations,
      contains(startsWith('drift-name-derivation-unverified: 1 ')),
    );
  });

  test('build.yaml이 drift 명명 규칙을 바꾸면 파생 이름을 싣지 않는다', () async {
    await write('build.yaml', '''
targets:
  \$default:
    builders:
      drift_dev:
        options:
          case_from_dart_to_sql: preserve
''');
    await write('lib/tables.dart', r'''
import 'package:drift/drift.dart';

class TodoItems extends Table {
  IntColumn get id => integer().named('id')();
  IntColumn get createdAt => integer()();
}
''');

    final result = indexSchema(root.path);

    // 테이블 이름을 모르면 컬럼 귀속도 불확실하다 — 동적 테이블 사실 하나만 남는다.
    expect(summarize(result), ['~TodoItems@3']);
    expect(
      result.limitations,
      contains(contains('build.yaml sets case_from_dart_to_sql to preserve')),
    );
  });

  test('floor Entity·ColumnInfo·ignore·Query·DatabaseView를 읽는다', () async {
    await write('lib/entities.dart', r'''
import 'package:floor/floor.dart';

@Entity(tableName: 'people')
class Person {
  @primaryKey
  final int id;
  @ColumnInfo(name: 'full_name')
  final String name;
  @ignore
  final String cache;
  static const version = 1;
  Person(this.id, this.name, this.cache);
}

@entity
class Pet {
  final int id;
  Pet(this.id);
}

@dao
abstract class PersonDao {
  @Query('SELECT * FROM people WHERE id = :id')
  Future<Person?> find(int id);
}

@DatabaseView('SELECT full_name FROM people', viewName: 'person_names')
class PersonName {
  final String name;
  PersonName(this.name);
}
''');

    final result = indexSchema(root.path);

    expect(summarize(result), [
      'people@3',
      'people#id@6',
      'people#full_name@8',
      'Pet@15',
      'Pet#id@17',
      'people@23',
      'person_names@27',
      'people@27',
    ]);
    expect(result.facts[5]['symbol'], {'qualifiedName': 'PersonDao.find'});
  });

  test('.drift 파일은 SQL로 읽고 명명 쿼리 라벨을 건너뛴다', () async {
    await write('lib/queries.drift', '''
CREATE TABLE notes (id INT, body TEXT);
allNotes: SELECT * FROM notes n JOIN tags t ON t.note_id = n.id;
''');

    final result = indexSchema(root.path);

    expect(summarize(result), ['notes@1', 'notes@2', 'tags@2']);
    expect(result.facts.first, isNot(contains('symbol')));
    expect(
      result.limitations,
      contains(startsWith('missing-relation-symbols: 3 ')),
    );
  });

  test('게이트 없는 리터럴은 대문자 SQL만 읽고 나머지는 계수한다', () async {
    await write('lib/misc.dart', r'''
import 'x.dart';

void f(String t) {
  print('Select an option from the menu');
  final legacy = 'SELECT * FROM legacy_table';
  final lower = 'select * from ignored';
  final dynamicSql = 'UPDATE $t SET x = 1';
  final multi = 'SELECT * '
      'FROM joined_table';
}
''');

    final result = indexSchema(root.path);

    expect(summarize(result), [
      'legacy_table@5',
      "~'UPDATE \$t SET x = 1'@7",
      'joined_table@8',
    ]);
    expect(
      result.limitations,
      contains(startsWith('skipped-sql-literals: 2 ')),
    );
  });

  test('비관계 저장소와 지원 밖 SQL 패키지는 사실 없이 한계로 남긴다', () async {
    await write('lib/store.dart', r'''
import 'package:isar/isar.dart';
import 'package:hive/hive.dart';

void f(dynamic isar) => isar.users.where();
''');
    await write('lib/mysql.dart', r'''
import 'package:mysql1/mysql1.dart';

void g(dynamic conn) => conn.query('select * from users');
''');

    final result = indexSchema(root.path);

    expect(result.facts, isEmpty);
    expect(
      result.limitations,
      containsAll([
        'non-relational-stores: 1 Dart source file(s) import non-SQL '
            'persistence packages outside the relation join: hive (1), isar (1)',
        'unsupported-db-packages: 1 Dart source file(s) import SQL packages '
            'outside the supported surface: mysql1 (1)',
      ]),
    );
  });

  test('위치는 UTF-8 byte 열이고 동적 channel은 공백을 접는다', () async {
    await write('lib/repo.dart', '''
import 'package:sqflite/sqflite.dart';

void run(Database db, String t) {
  /* 한글 */ db.rawQuery('SELECT * FROM users');
  db.rawQuery(
    t
      + 'x',
  );
}
''');

    final result = indexSchema(root.path);

    expect(result.facts.first['location'], {
      'path': 'lib/repo.dart',
      'line': 4,
      // `  /* 한글 */ db.rawQuery(`는 27 bytes다 — 한글 두 글자가 6 bytes를 차지한다.
      'column': 28,
    });
    expect(result.facts.last['channel'], "t + 'x'");
  });

  test('projectRootPath는 위치를 공유 루트 기준으로 재기준화한다', () async {
    await write('packages/app/lib/repo.dart', r'''
import 'package:sqflite/sqflite.dart';

void run(Database db) => db.rawQuery('SELECT * FROM users');
''');

    final result = indexSchema(
      p.join(root.path, 'packages', 'app'),
      projectRootPath: root.path,
    );

    expect(
      (result.facts.single['location']! as Map)['path'],
      'packages/app/lib/repo.dart',
    );
    expect(
      () => indexSchema(root.path, projectRootPath: p.join(root.path, 'x')),
      throwsA(isA<FileSystemException>()),
    );
  });
}
