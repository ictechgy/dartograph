import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/core/result_ledger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 검증 원장의 경계 계약이다 — append-only, 손상 복구, commit 필터.
void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dartograph-ledger.');
  });
  tearDown(() => directory.delete(recursive: true));

  test('append and read round-trip preserves every field', () async {
    final ledger = ResultLedger(directory.path);
    await ledger.append(
      LedgerEntry(
        recordedAt: DateTime.utc(2026, 9, 16, 1, 2, 3),
        toolVersion: '9.9.9',
        command: 'dead',
        exitCode: 1,
        commit: 'a' * 40,
        inputs: {'format': 'json', 'since': 'origin/main'},
        failedItems: ['project:lib/a.dart::A'],
      ),
    );

    final result = await ledger.read();

    expect(result.isDamaged, isFalse);
    expect(result.entries, hasLength(1));
    final entry = result.entries.single;
    expect(entry.recordedAt, DateTime.utc(2026, 9, 16, 1, 2, 3));
    expect(entry.toolVersion, '9.9.9');
    expect(entry.command, 'dead');
    expect(entry.exitCode, 1);
    expect(entry.commit, 'a' * 40);
    expect(entry.inputs, {'format': 'json', 'since': 'origin/main'});
    expect(entry.failedItems, ['project:lib/a.dart::A']);
  });

  test('appending never rewrites existing lines', () async {
    final ledger = ResultLedger(directory.path);
    await ledger.append(_entry('dead'));
    final firstLine = await ledger.file.readAsString();

    await ledger.append(_entry('cycles'));
    final contents = await ledger.file.readAsString();

    expect(contents.startsWith(firstLine), isTrue);
    expect((await ledger.read()).entries.map((e) => e.command), [
      'dead',
      'cycles',
    ]);
  });

  test(
    'a truncated final line is skipped and does not swallow the next',
    () async {
      final ledger = ResultLedger(directory.path);
      await ledger.append(_entry('dead'));
      // 쓰기 중단을 흉내 낸다: 개행 없이 잘린 줄을 덧붙인다.
      final contents = await ledger.file.readAsString();
      await ledger.file.writeAsString('$contents{"command":"cyc');

      final damaged = await ledger.read();
      expect(damaged.isDamaged, isTrue);
      expect(damaged.skippedLines, 1);
      expect(damaged.entries.map((e) => e.command), ['dead']);

      // 다음 append는 개행을 먼저 넣어 새 항목을 온전한 줄로 쓴다.
      await ledger.append(_entry('rules'));
      final after = await ledger.read();
      expect(after.skippedLines, 1);
      expect(after.entries.map((e) => e.command), ['dead', 'rules']);
    },
  );

  test('the commit filter selects matching entries only', () async {
    final ledger = ResultLedger(directory.path);
    await ledger.append(_entry('dead', commit: 'a' * 40));
    await ledger.append(_entry('cycles', commit: 'b' * 40));

    expect(
      (await ledger.read(commit: 'b' * 40)).entries.map((e) => e.command),
      ['cycles'],
    );
    expect((await ledger.read(commit: 'c' * 40)).entries, isEmpty);
  });

  test('a missing ledger reads as empty without damage', () async {
    final result = await ResultLedger(p.join(directory.path, 'absent')).read();
    expect(result.entries, isEmpty);
    expect(result.isDamaged, isFalse);
  });

  test('inputs serialize in sorted key order', () {
    final entry = LedgerEntry(
      recordedAt: DateTime.utc(2026, 9, 16),
      toolVersion: '1.0.0',
      command: 'dead',
      exitCode: 0,
      inputs: {'since': 'origin/main', 'depth': '2', 'format': 'json'},
    );
    expect(
      jsonEncode(entry.toJson()),
      contains('"inputs":{"depth":"2","format":"json","since":"origin/main"}'),
    );
  });

  test('fromJson rejects malformed entries', () {
    expect(LedgerEntry.fromJson(null), isNull);
    expect(LedgerEntry.fromJson('x'), isNull);
    expect(LedgerEntry.fromJson({'command': 'dead'}), isNull);
    expect(
      LedgerEntry.fromJson({
        'command': 'dead',
        'exitCode': '1',
        'recordedAt': '2026-09-16T00:00:00.000Z',
      }),
      isNull,
    );
    expect(
      LedgerEntry.fromJson({
        'command': 'dead',
        'exitCode': 1,
        'recordedAt': 'nope',
      }),
      isNull,
    );

    final parsed = LedgerEntry.fromJson({
      'command': 'dead',
      'exitCode': 1,
      'recordedAt': '2026-09-16T00:00:00.000Z',
      'toolVersion': '1.0.0',
    });
    expect(parsed, isNotNull);
    expect(parsed!.inputs, isEmpty);
    expect(parsed.failedItems, isEmpty);
    expect(parsed.commit, isNull);
  });
}

LedgerEntry _entry(String command, {String? commit}) => LedgerEntry(
  recordedAt: DateTime.utc(2026, 9, 16),
  toolVersion: '1.0.0',
  command: command,
  exitCode: 0,
  commit: commit,
);
