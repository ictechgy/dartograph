import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `--incremental <dir>`의 CLI 배선 계약이다.
///
/// 옵션을 떼어내는 규칙(위치·중복·값 누락)과, 실제 실행이 캐시를 만들고 두 번째
/// 실행에서 같은 산출물을 내는지 확인한다. 색인을 주입하지 않고 프로덕션 기본
/// 배선을 그대로 탄다 — 배선 자체가 검증 대상이다.
void main() {
  late Directory workspace;
  late Directory root;
  late String cacheDirectory;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'dartograph-incremental-cli.',
    );
    root = Directory(p.join(workspace.path, 'app'));
    cacheDirectory = p.join(workspace.path, 'facts');
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
  });

  tearDown(() => workspace.delete(recursive: true));

  test('incremental runs are byte-identical to the default path', () async {
    final plain = await _run(['graph', '--format', 'json', root.path]);
    final first = await _run([
      'graph',
      '--format',
      'json',
      '--incremental',
      cacheDirectory,
      root.path,
    ]);
    final second = await _run([
      'graph',
      '--format',
      'json',
      '--incremental',
      cacheDirectory,
      root.path,
    ]);

    expect(first.status, 0, reason: first.error);
    expect(second.status, 0, reason: second.error);
    expect(first.output, plain.output);
    expect(second.output, plain.output);
    expect(File(p.join(cacheDirectory, 'facts.json')).existsSync(), isTrue);

    // 옵션 위치는 고정이 아니다 — 명령 이름 바로 뒤에도 올 수 있다.
    final leading = await _run([
      'graph',
      '--incremental',
      cacheDirectory,
      '--format',
      'json',
      root.path,
    ]);
    expect(leading.status, 0, reason: leading.error);
    expect(leading.output, plain.output);

    // dead도 같은 색인 경로를 쓴다.
    final dead = await _run([
      'dead',
      '--incremental',
      cacheDirectory,
      '--format',
      'json',
      root.path,
    ]);
    expect(dead.status, 0, reason: dead.error);
  });

  test('incremental option errors are usage errors', () async {
    for (final invocation in [
      ['graph', '--format', 'json', '--incremental', root.path],
      ['graph', '--format', 'json', '--incremental'],
      [
        'graph',
        '--format',
        'json',
        '--incremental',
        cacheDirectory,
        '--incremental',
        cacheDirectory,
        root.path,
      ],
      ['graph', '--format', 'json', '--incremental', '--level', root.path],
      ['dead', '--incremental', cacheDirectory, '--incremental', root.path],
      ['cycles', '--incremental', root.path],
    ]) {
      final result = await _run(invocation);
      expect(
        result.status,
        64,
        reason: 'usage error expected for $invocation (${result.error})',
      );
    }
  });

  test('commands without an index reject the option', () async {
    // runtime/skill/init은 이 옵션을 정의하지 않는다 — 조용히 무시하지 않는다.
    for (final invocation in [
      ['runtime', '--incremental', cacheDirectory, root.path],
      ['init', '--incremental', cacheDirectory, root.path],
    ]) {
      final result = await _run(invocation);
      expect(result.status, 64, reason: invocation.toString());
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
