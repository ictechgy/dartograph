import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dartograph schema` — isthmus persistence 도메인 생산 명령의 CLI 계약이다.
void main() {
  late Directory root;
  final fixedNow = DateTime.utc(2026, 9, 26, 1, 2, 3, 456);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('schema-cli.');
  });
  tearDown(() => root.delete(recursive: true));

  Future<({int code, String output, String error})> run(
    List<String> arguments,
  ) async {
    final output = StringBuffer();
    final error = StringBuffer();
    final code = await runDartograph(
      arguments,
      output: output,
      error: error,
      now: () => fixedNow,
    );
    return (code: code, output: output.toString(), error: error.toString());
  }

  test('persistence 버전 1 문서를 낸다', () async {
    await Directory(p.join(root.path, 'lib')).create();
    await File(p.join(root.path, 'lib', 'repo.dart')).writeAsString('''
import 'package:sqflite/sqflite.dart';

void run(Database db) => db.rawQuery('SELECT * FROM users');
''');

    final result = await run(['schema', '--format', 'json', root.path]);

    expect(result.code, 0, reason: result.error);
    final document = jsonDecode(result.output) as Map<String, Object?>;
    expect(document['format'], 'bridge-facts');
    expect(document['version'], 1);
    expect(document['platform'], 'dart');
    expect(document['target'], 'persistence');
    expect(document['project'], root.resolveSymbolicLinksSync());
    expect(document['generatedAt'], '2026-09-26T01:02:03.456Z');
    expect(document.containsKey('transport'), isFalse);
    expect((document['facts']! as List).single, {
      'symbol': {'qualifiedName': 'run'},
      'kind': 'relation-use',
      'channel': 'users',
      'dynamic': false,
      'location': {'path': 'lib/repo.dart', 'line': 3, 'column': 38},
    });
  });

  test('사실이 없으면 target은 null이다', () async {
    final result = await run(['schema', '--format', 'json', root.path]);

    expect(result.code, 0, reason: result.error);
    final document = jsonDecode(result.output) as Map<String, Object?>;
    expect(document['target'], isNull);
    expect(document['facts'], isEmpty);
  });

  test('--project는 공유 루트 기준 위치를 쓴다', () async {
    final package = Directory(p.join(root.path, 'packages', 'app', 'lib'));
    await package.create(recursive: true);
    await File(p.join(package.path, 'repo.dart')).writeAsString('''
import 'package:sqflite/sqflite.dart';

void run(Database db) => db.rawQuery('SELECT * FROM users');
''');

    final result = await run([
      'schema',
      '--format',
      'json',
      '--project',
      root.path,
      p.join(root.path, 'packages', 'app'),
    ]);

    expect(result.code, 0, reason: result.error);
    final document = jsonDecode(result.output) as Map<String, Object?>;
    expect(document['project'], root.resolveSymbolicLinksSync());
    final fact = (document['facts']! as List).single as Map<String, Object?>;
    expect((fact['location']! as Map)['path'], 'packages/app/lib/repo.dart');
  });

  test('bridges 전용 플래그와 잘못된 인자는 usage다', () async {
    for (final invocation in [
      ['schema', '--messages', '--format', 'json', root.path],
      ['schema', '--events', '--format', 'json', root.path],
      ['schema', '--format', 'text', root.path],
      ['schema', root.path],
      ['schema', '--format', 'json', '-pkg'],
      ['schema', '--format', 'json', '--project', root.path],
    ]) {
      final result = await run(invocation);
      expect(result.code, 64, reason: invocation.join(' '));
      expect(result.output, isEmpty, reason: invocation.join(' '));
    }
  });

  test('도움말에 schema 사용법이 있다', () async {
    final result = await run(['--help']);

    expect(
      result.output + result.error,
      contains(
        'dartograph schema --format json [--project <shared-root>] '
        '<package-root>',
      ),
    );
  });
}
