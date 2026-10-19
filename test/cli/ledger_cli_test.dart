import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/core/tool_info.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/hostile_git_support.dart';

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

  test(
    '--record reads the commit without running repository git settings',
    () async {
      // 속성이 겨루는 점 든 이름만 빼고 모든 설정을 한 저장소에 심는다.
      final repository = await createRepositoryWithHostileSettings(
        Directory(p.join(workspace.path, 'hostile'))..createSync(),
        {...HostileGitSetting.values}
          ..remove(HostileGitSetting.dottedDriverName),
      );
      final previous = Directory.current;
      final ({int status, String output, String error}) run;
      try {
        // 원장 commit은 cwd의 HEAD다. cwd는 프로세스 전역이라 다른 테스트 파일과
        // 경합하므로 인덱싱 없이 usage(64)로 끝나는 실행 한 번만 감싼다.
        Directory.current = repository.root;
        run = await _run([
          'runtime',
          '--record',
          ledgerDirectory,
          '--format=json',
          root.path,
        ]);
      } finally {
        Directory.current = previous;
      }

      expect(run.status, 64, reason: run.error);
      final entry =
          jsonDecode(
                File(
                  p.join(ledgerDirectory, 'ledger.jsonl'),
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(entry['commit'], repository.head);
      expect(repository.commandRan, isFalse);
    },
    skip: Platform.isWindows ? 'the fixture plants POSIX sh scripts' : false,
  );

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

  test('inline --key=value tokens never record their values', () async {
    final run = await _run([
      'runtime',
      '--record',
      ledgerDirectory,
      '--env=API_TOKEN=s3cr3t-value',
      '--dart-define=FLAVOR=prod-secret',
      '--format=json',
      '--no-verify',
      root.path,
    ]);
    // CLI는 `--key=value` 형식을 받지 않는다. 실패한 실행도 원장에 남는다.
    expect(run.status, 64, reason: run.error);

    final ledger = File(
      p.join(ledgerDirectory, 'ledger.jsonl'),
    ).readAsStringSync();
    expect(ledger, isNot(contains('s3cr3t-value')));
    expect(ledger, isNot(contains('prod-secret')));
    expect(ledger, isNot(contains(root.path)));
    final entry = jsonDecode(ledger.trim()) as Map<String, Object?>;
    expect(entry['inputs'], {
      'dart-define': 'FLAVOR',
      'env': 'API_TOKEN',
      'format': 'true',
      'no-verify': 'true',
    });
  });

  test('value-less switches do not swallow the package root', () async {
    final cache = p.join(workspace.path, 'cache');
    for (final arguments in [
      ['cycles', '--strict', root.path],
      ['dead', '--format', 'json', '--workspace', root.path],
      ['query', 'Service', '--with-source', root.path],
    ]) {
      await _run([
        arguments.first,
        '--record',
        ledgerDirectory,
        '--incremental',
        cache,
        ...arguments.skip(1),
      ]);
    }

    final lines = File(
      p.join(ledgerDirectory, 'ledger.jsonl'),
    ).readAsLinesSync();
    // 값을 받는 옵션은 값을 그대로 남기고, 스위치는 뒤따르는 위치 인자를
    // 값으로 삼키지 않는다.
    expect(
      [for (final line in lines) (jsonDecode(line) as Map)['inputs']],
      [
        {'incremental': cache, 'strict': 'true'},
        {'format': 'json', 'incremental': cache, 'workspace': 'true'},
        {'incremental': cache, 'with-source': 'true'},
      ],
    );
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
