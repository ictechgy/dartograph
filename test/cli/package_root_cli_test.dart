import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 없는 경로나 파일을 패키지 루트로 넘기면 분석 명령이 원인을 짚는 진단과 종료 2로
/// 끝나는지 고정한다.
///
/// 수정 전에는 경로 오타(`./lbi`)나 파일 경로(`lib/main.dart`)도 모든 분석 명령에서
/// `Analysis failed: unable to index the package.`로만 보였다(#160과 같은 문구).
void main() {
  const diagnostic =
      'Analysis failed: the package root was not found or is not a directory. '
      'Check the path, or pass the package directory (the one that contains '
      'pubspec.yaml).\n';

  late Directory root;
  late String changed;
  late String baseline;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dartograph-root-cli.');
    await File(
      p.join(root.path, 'pubspec.yaml'),
    ).writeAsString('name: root_app\npublish_to: none\n');
    await Directory(p.join(root.path, 'lib')).create();
    await File(
      p.join(root.path, 'lib', 'root_app.dart'),
    ).writeAsString('void run() {}\n');
    changed = p.join(root.path, 'changed.json');
    await File(changed).writeAsString('["lib/root_app.dart"]');
    baseline = p.join(root.path, 'baseline.json');
  });
  tearDown(() => root.delete(recursive: true));

  /// 패키지 루트 자리에 [target]을 넣어 실행할 명령들이다.
  List<List<String>> commands(String target) => [
    ['graph', '--format', 'json', target],
    ['dead', '--format', 'text', target],
    ['cycles', '--strict', target],
    ['deps', target],
    ['dup', target],
    ['metrics', target],
    ['query', 'run', target],
    ['baseline', '--write', baseline, target],
    ['impact', '--symbol', 'project:lib/root_app.dart::run', target],
    ['impact', '--changed', changed, target],
    ['impact', '--before', root.path, target],
    ['impact', '--format', 'language-traversal', target, 'x'],
    ['compare', root.path, target],
    ['affected', 'HEAD', target],
    ['bridges', '--format', 'json', target],
    ['schema', '--format', 'json', target],
    ['routes', '--role', 'client', target],
    ['runtime', target],
  ];

  for (final (name, target) in [
    ('a missing path', (Directory root) => p.join(root.path, 'lbi')),
    ('a file', (Directory root) => p.join(root.path, 'lib', 'root_app.dart')),
    (
      'a link loop',
      (Directory root) {
        // 링크 순환도 해석되지 않는 경로다. 상위 디렉터리 권한으로 닿을 수 없는
        // 경로와 함께 진단 문구의 "was not found"에 해당한다.
        final first = p.join(root.path, 'loop_a');
        Link(first).createSync(p.join(root.path, 'loop_b'));
        Link(p.join(root.path, 'loop_b')).createSync(first);
        return first;
      },
    ),
    (
      'a dangling link',
      (Directory root) {
        final link = p.join(root.path, 'stale');
        Link(link).createSync(p.join(root.path, 'gone'));
        return link;
      },
    ),
  ]) {
    test(
      '$name as the package root is named by every analysis command',
      () async {
        final path = target(root);
        for (final command in commands(path)) {
          final output = StringBuffer();
          final error = StringBuffer();
          // 사용자 캐시를 쓰지 않는다(격리).
          final status = await runDartograph(
            command,
            output: output,
            error: error,
            userCacheEnvironment: const {},
          );
          final reason = '${command.first} ${command[1]}: $error';
          expect(status, ExitStatus.failure.code, reason: reason);
          expect(output.toString(), isEmpty, reason: reason);
          expect(error.toString(), diagnostic, reason: reason);
        }
      },
      skip: name.contains('link') && Platform.isWindows,
    );
  }

  test('a link to the package directory is still followed', () async {
    // 루트 판정은 링크를 따라간 대상을 본다. 디렉터리 링크 루트는 지금처럼 분석된다.
    final link = p.join(
      (await Directory.systemTemp.createTemp('dartograph-root-link.')).path,
      'app',
    );
    addTearDown(() => Directory(p.dirname(link)).delete(recursive: true));
    Link(link).createSync(root.path);

    final error = StringBuffer();
    final status = await runDartograph(
      ['cycles', '--strict', link],
      output: StringBuffer(),
      error: error,
      userCacheEnvironment: const {},
    );

    expect(status, ExitStatus.success.code, reason: error.toString());
  }, skip: Platform.isWindows);
}
