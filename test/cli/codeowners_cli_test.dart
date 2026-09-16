import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dead --format codeowners`의 CLI 배선 계약이다.
void main() {
  late Directory workspace;
  late Directory root;
  late String codeownersPath;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('dartograph-codeowners.');
    root = Directory(p.join(workspace.path, 'app'));
    codeownersPath = p.join(workspace.path, 'CODEOWNERS');
    Future<void> write(String path, String contents) async {
      final file = File(p.join(root.path, path));
      await file.create(recursive: true);
      await file.writeAsString(contents);
    }

    await write('pubspec.yaml', 'name: app\nenvironment:\n  sdk: ^3.11.0\n');
    await write('lib/app.dart', '\n');
    await write('lib/orphan.dart', 'class Orphan {}\n');
    await write('example/orphan.dart', 'class ExampleOrphan {}\n');
    await File(codeownersPath).writeAsString('''
* @fallback
lib/ @lib-team
example/
''');
  });

  tearDown(() => workspace.delete(recursive: true));

  test('groups findings by owner and reports unowned paths', () async {
    final result = await _run([
      'dead',
      '--format',
      'codeowners',
      '--codeowners',
      codeownersPath,
      root.path,
    ]);

    expect(result.status, 1, reason: result.error);
    // pub get 없는 프로젝트는 project: ID라 파일 발견이 선언 발견과 함께 난다 —
    // lib/는 orphan 선언 + orphan.dart·app.dart 파일, example/은 선언 + 파일.
    expect(result.output, contains('@lib-team: 3 finding(s)'));
    expect(result.output, contains('(unowned): 2 finding(s)'));
    expect(result.output, contains('example/orphan.dart'));
    expect(
      result.output,
      contains('dead: 5 finding(s), 0 suppressed by baseline'),
    );
  });

  test('codeowners option errors are usage errors', () async {
    for (final invocation in [
      ['dead', '--format', 'codeowners', root.path],
      ['dead', '--format', 'json', '--codeowners', codeownersPath, root.path],
      ['dead', '--format', 'codeowners', '--codeowners', root.path],
      ['dead', '--format', 'codeowners', '--codeowners'],
      ['dead', '--format', 'codeowners', '--codeowners', '--level', root.path],
    ]) {
      final result = await _run(invocation);
      expect(
        result.status,
        64,
        reason: 'usage error expected for $invocation (${result.error})',
      );
    }
  });

  test('a missing CODEOWNERS file is an analysis failure', () async {
    final result = await _run([
      'dead',
      '--format',
      'codeowners',
      '--codeowners',
      p.join(workspace.path, 'absent'),
      root.path,
    ]);
    expect(result.status, 2, reason: result.error);
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
