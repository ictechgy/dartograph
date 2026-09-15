import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/core/tool_info.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 검증 원장의 CLI 배선 계약이다 — `--record`가 실행을 남기고 `history`가 읽는다.
void main() {
  late Directory workspace;
  late Directory root;
  late String ledgerDirectory;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('dartograph-ledger-cli.');
    root = Directory(p.join(workspace.path, 'app'));
    ledgerDirectory = p.join(workspace.path, 'ledger');
    Future<void> write(String path, String contents) async {
      final file = File(p.join(root.path, path));
      await file.create(recursive: true);
      await file.writeAsString(contents);
    }

    await write('pubspec.yaml', 'name: app\nenvironment:\n  sdk: ^3.11.0\n');
    await write('lib/app.dart', "export 'service.dart';\n");
    await write('lib/service.dart', 'class Service {}\n');
    await write(
      'lib/main.dart',
      "import 'service.dart';\nvoid main() {\n  Service();\n}\n",
    );
    // 어디서도 참조하지 않는 파일이라 dead finding(종료 코드 1)을 만든다.
    await write('lib/orphan.dart', 'class Orphan {}\n');
  });

  tearDown(() => workspace.delete(recursive: true));

  test('--record appends a run that history reads back', () async {
    final run = await _run([
      'dead',
      '--format',
      'json',
      '--record',
      ledgerDirectory,
      root.path,
    ]);
    expect(run.status, 1, reason: run.error);

    final history = await _run([
      'history',
      '--ledger',
      ledgerDirectory,
      '--format',
      'json',
    ]);
    expect(history.status, 0, reason: history.error);
    final document = jsonDecode(history.output) as Map<String, Object?>;
    expect(document['version'], 1);
    expect(document['skippedLines'], 0);
    final entries = document['entries']! as List;
    expect(entries, hasLength(1));
    final entry = (entries.single as Map).cast<String, Object?>();
    expect(entry['command'], 'dead');
    expect(entry['exitCode'], 1);
    expect(entry['toolVersion'], toolVersion);
    expect(DateTime.tryParse('${entry['recordedAt']}'), isNotNull);
    expect((entry['inputs']! as Map)['format'], 'json');
    expect(entry['failedItems'], isNotEmpty);
    final commit = entry['commit'];
    expect(
      commit == null || RegExp(r'^[0-9a-f]{7,64}$').hasMatch('$commit'),
      isTrue,
    );
  });

  test('history text lists the recorded command', () async {
    await _run(['cycles', '--record', ledgerDirectory, root.path]);
    final history = await _run(['history', '--ledger', ledgerDirectory]);
    expect(history.status, 0, reason: history.error);
    expect(history.output, contains('history: 1 entr(ies)'));
    expect(history.output, contains('cycles'));
  });

  test('--env and --dart-define values are redacted to keys', () async {
    final run = await _run([
      'runtime',
      '--env',
      'API_TOKEN=super-secret',
      '--dart-define',
      'FLAVOR=prod',
      '--record',
      ledgerDirectory,
      root.path,
    ]);
    expect(run.status, 0, reason: run.error);

    final history = await _run([
      'history',
      '--ledger',
      ledgerDirectory,
      '--format',
      'json',
    ]);
    expect(history.output, isNot(contains('super-secret')));
    expect(history.output, isNot(contains('prod')));
    final document = jsonDecode(history.output) as Map<String, Object?>;
    final entry = ((document['entries']! as List).single as Map)
        .cast<String, Object?>();
    final inputs = (entry['inputs']! as Map).cast<String, Object?>();
    expect(inputs['env'], 'API_TOKEN');
    expect(inputs['dart-define'], 'FLAVOR');
  });

  test('a damaged line is reported, not fatal', () async {
    final file = File(p.join(ledgerDirectory, 'ledger.jsonl'));
    await file.create(recursive: true);
    await file.writeAsString(
      '{"command":"dead","exitCode":1,'
      '"recordedAt":"2026-09-16T00:00:00.000Z","toolVersion":"1.0.0",'
      '"inputs":{},"failedItems":[]}\n'
      '{"command":"cyc',
    );
    final history = await _run([
      'history',
      '--ledger',
      ledgerDirectory,
      '--format',
      'json',
    ]);
    expect(history.status, 0, reason: history.error);
    final document = jsonDecode(history.output) as Map<String, Object?>;
    expect(document['skippedLines'], 1);
    expect(
      document['limitations'],
      contains('ledger-skipped-lines: 1 damaged line(s) were skipped on read'),
    );
    expect((document['entries']! as List), hasLength(1));
  });

  test('a failed ledger write keeps the command exit code', () async {
    final blocker = File(p.join(workspace.path, 'blocker'));
    await blocker.writeAsString('not a directory');
    final run = await _run([
      'dead',
      '--format',
      'json',
      '--record',
      blocker.path,
      root.path,
    ]);
    expect(run.status, 1, reason: run.error);
    expect(run.error, contains('Ledger write failed'));
  });

  test('--record option errors are usage errors', () async {
    for (final invocation in [
      ['graph', '--format', 'json', '--record'],
      [
        'graph',
        '--format',
        'json',
        '--record',
        ledgerDirectory,
        '--record',
        ledgerDirectory,
        root.path,
      ],
      ['graph', '--format', 'json', '--record', '--level', root.path],
      ['dead', '--record', ledgerDirectory, '--record', root.path],
      ['init', '--record', ledgerDirectory, root.path],
    ]) {
      final result = await _run(invocation);
      expect(
        result.status,
        64,
        reason: 'usage error expected for $invocation (${result.error})',
      );
    }
  });

  test('history option errors are usage errors', () async {
    for (final invocation in [
      ['history'],
      ['history', '--ledger'],
      ['history', '--ledger', ledgerDirectory, '--format', 'sarif'],
      ['history', '--ledger', ledgerDirectory, '--unknown'],
      ['history', '--ledger', ledgerDirectory, '--commit'],
    ]) {
      final result = await _run(invocation);
      expect(
        result.status,
        64,
        reason: 'usage error expected for $invocation (${result.error})',
      );
    }
  });
}

Future<({int status, String output, String error})> _run(
  List<String> arguments,
) async {
  final output = StringBuffer();
  final error = StringBuffer();
  final status = await runDartograph(arguments, output: output, error: error);
  return (status: status, output: output.toString(), error: error.toString());
}
