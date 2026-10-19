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
      'symbol': {'qualifiedName': 'run', 'usr': 'project:lib/repo.dart::run'},
      'kind': 'relation-use',
      'channel': 'users',
      'dynamic': false,
      'location': {'path': 'lib/repo.dart', 'line': 3, 'column': 38},
    });
  });

  test('장치 링크 입력은 색인·추출 명령을 원인을 짚는 진단과 종료 2로 멈춘다', () async {
    await Directory(p.join(root.path, 'lib')).create();
    await File(p.join(root.path, 'lib', 'repo.dart')).writeAsString('''
import 'package:sqflite/sqflite.dart';

void run(Database db) => db.rawQuery('SELECT * FROM users');
''');
    // 저장소가 커밋할 수 있는 장치 링크다. /dev/null은 즉시 EOF라 수정 전
    // 코드에서도 안전하지만, 같은 경로의 /dev/zero는 메모리를 채우고 FIFO는
    // 영구 대기한다. 거부 자체는 종료 2로 굳어 있었지만 진단이 원인을 반대로
    // 짚었다: schema·bridges·routes는 '제어문자 포함', dead는 일반 색인 실패,
    // impact는 --symbol인데도 'Invalid changed list'와 종료 64였다.
    const commands = {
      'schema': ['schema', '--format', 'json'],
      'bridges': ['bridges', '--format', 'json'],
      'routes': ['routes', '--role', 'client'],
      'dead': ['dead', '--format', 'json'],
      'impact': ['impact', '--symbol', 'project:lib/repo.dart::run'],
    };
    for (final target in const [
      'dartograph.yaml',
      'pubspec.yaml',
      'build.yaml',
      'lib/x.dart',
    ]) {
      final link = Link(p.join(root.path, target));
      await link.create('/dev/null');

      for (final MapEntry(key: name, value: command) in commands.entries) {
        final result = await run([...command, root.path]);
        final reason = '$target, $name: ${result.error}';
        expect(result.code, 2, reason: reason);
        expect(result.output, isEmpty, reason: reason);
        expect(result.error, contains('not a regular file'), reason: reason);
        expect(result.error, isNot(contains('control characters')));
        expect(result.error, isNot(contains('changed list')));
      }
      await link.delete();
    }
  }, skip: Platform.isWindows);

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
    // usr는 스캔 루트(패키지) 기준 그래프 ID다 — 같은 루트의 impact와 같은 공간.
    expect((fact['symbol']! as Map)['usr'], 'project:lib/repo.dart::run');
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
