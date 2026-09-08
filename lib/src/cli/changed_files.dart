import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Git 기준점이나 변경 파일 집합을 신뢰할 수 있게 계산하지 못했다.
final class ChangedFilesException implements Exception {
  /// 호출자가 경로나 Git stderr를 노출하지 않는 진단으로 바꾸도록 표식만 남긴다.
  const ChangedFilesException();
}

/// Git 기준점과 현재 작업 상태 사이에서 바뀐 파일을 완전하게 모은다.
abstract final class ChangedFiles {
  /// merge-base 이후 커밋, HEAD 대비 작업 트리, untracked 파일을 합친다.
  static Future<Set<String>> since(
    String reference,
    String workingDirectory,
  ) async {
    final resolvedReference = await _run(
      ['rev-parse', '--verify', '--end-of-options', '$reference^{commit}'],
      workingDirectory,
      reference,
      nulSeparated: false,
    );
    if (resolvedReference.length != 1) {
      throw const ChangedFilesException();
    }
    final baseCommit = resolvedReference.single;
    final rootValues = await _run(
      const ['rev-parse', '--show-toplevel'],
      workingDirectory,
      reference,
      nulSeparated: false,
    );
    if (rootValues.isEmpty) {
      throw const ChangedFilesException();
    }
    final root = rootValues.single;
    final groups = await Future.wait([
      _run(
        ['diff', '--name-only', '--diff-filter=d', '-z', '$baseCommit...HEAD'],
        workingDirectory,
        reference,
      ),
      _run(
        const ['diff', '--name-only', '--diff-filter=d', '-z', 'HEAD'],
        workingDirectory,
        reference,
      ),
      _run(
        const [
          'ls-files',
          '--others',
          '--exclude-standard',
          '--full-name',
          '-z',
        ],
        workingDirectory,
        reference,
      ),
    ]);
    return {
      for (final relative in groups.expand((paths) => paths))
        p.normalize(p.join(root, relative)),
    };
  }

  static Future<List<String>> _run(
    List<String> arguments,
    String workingDirectory,
    String reference, {
    bool nulSeparated = true,
  }) async {
    final process = await Process.run(
      'git',
      // diff.relative=true면 `git diff`가 cwd 상대 경로를 출력한다. 패키지 루트가
      // 저장소 루트와 다르면 아래에서 저장소 루트와 join할 때 경로가 어긋나
      // 변경 파일 집합이 잘못 계산된다. 경로는 항상 저장소 루트 기준으로 고정한다.
      ['-c', 'diff.relative=false', '-C', workingDirectory, ...arguments],
      stdoutEncoding: null,
      stderrEncoding: utf8,
    );
    if (process.exitCode != 0) {
      throw const ChangedFilesException();
    }
    final decoded = utf8.decode(process.stdout as List<int>);
    return decoded
        .split(nulSeparated ? '\u0000' : '\n')
        .where((value) => value.isNotEmpty)
        .toList();
  }
}
