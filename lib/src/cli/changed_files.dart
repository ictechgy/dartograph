import 'dart:convert';

import 'package:path/path.dart' as p;

import 'analysis_git.dart';

/// Git 기준점이나 변경 파일 집합을 신뢰할 수 있게 계산하지 못했다.
final class ChangedFilesException implements Exception {
  /// 호출자가 경로나 Git stderr를 노출하지 않는 진단으로 바꾸도록 표식만 남긴다.
  const ChangedFilesException({this.unneutralizableFilterDriver = false});

  /// 저장소 설정의 filter 드라이버 이름을 `-c`로 덮을 수 없어 git을 실행하지
  /// 않았는지다. 호출자는 이때 일반 Git 실패와 다른 원인·해결 방향을 알린다.
  final bool unneutralizableFilterDriver;
}

/// Git 기준점과 현재 작업 상태 사이에서 바뀐 파일을 완전하게 모은다.
abstract final class ChangedFiles {
  /// merge-base 이후 커밋, HEAD 대비 작업 트리, untracked 파일을 합친다.
  ///
  /// 출력 계약: 반환 경로는 `git rev-parse --show-toplevel`(물리 경로) 기준
  /// `p.normalize(p.join(root, relative))` 절대 경로다. 소비자는 이 형태와
  /// canonical(심볼릭 링크 해석) 경로 **양쪽**으로 매칭한다(_changedContains) —
  /// 링크 파일 자체의 변경은 toplevel 기준 경로로, 대상의 변경은 해석 경로로
  /// 오기 때문이다. 삭제 파일은 `--diff-filter=d`로 제외된다.
  ///
  /// 모든 git 호출은 [AnalysisGit]을 지나 저장소 설정의 명령(filter·fsmonitor·
  /// 훅·서브모듈 설정)을 실행하지 않는다. 그래서 git-lfs처럼 filter가 정규화하던
  /// 파일과 stat만 바뀐 파일도 변경으로 센다(보수적 상위집합).
  static Future<Set<String>> since(
    String reference,
    String workingDirectory,
  ) async {
    final resolvedReference = await _run(
      ['rev-parse', '--verify', '--end-of-options', '$reference^{commit}'],
      workingDirectory,
      nulSeparated: false,
    );
    if (resolvedReference.length != 1) {
      throw const ChangedFilesException();
    }
    final baseCommit = resolvedReference.single;
    final rootValues = await _run(
      const ['rev-parse', '--show-toplevel'],
      workingDirectory,
      nulSeparated: false,
    );
    if (rootValues.isEmpty) {
      throw const ChangedFilesException();
    }
    final root = rootValues.single;
    final groups = await Future.wait([
      _run([
        'diff',
        '--no-ext-diff',
        '--no-textconv',
        '--name-only',
        '--diff-filter=d',
        '-z',
        '$baseCommit...HEAD',
      ], workingDirectory),
      // 작업 트리 비교는 두 가지를 더 막는다. git은 서브모듈이 바뀌었는지 보려고
      // 그 안에서 git을 띄워 서브모듈 저장소 자신의 설정(fsmonitor·filter·훅)을
      // 따른다. gitlink 경로는 디렉터리라 원래 Dart 소스와 맞지 않는다. 또 stat만
      // 바뀐 파일의 내용을 다시 읽은 뒤 index를 고쳐 쓰며 post-index-change 훅을
      // 실행한다. 그래서 stat만 바뀐 파일도 변경으로 센다(보수적 상위집합).
      _run(
        const [
          'diff',
          '--no-ext-diff',
          '--no-textconv',
          '--ignore-submodules=all',
          '--name-only',
          '--diff-filter=d',
          '-z',
          'HEAD',
        ],
        workingDirectory,
        configuration: const ['diff.autoRefreshIndex=false'],
      ),
      _run(const [
        'ls-files',
        '--others',
        '--exclude-standard',
        '--full-name',
        '-z',
      ], workingDirectory),
    ]);
    return {
      for (final relative in groups.expand((paths) => paths))
        p.normalize(p.join(root, relative)),
    };
  }

  static Future<List<String>> _run(
    List<String> arguments,
    String workingDirectory, {
    bool nulSeparated = true,
    List<String> configuration = const [],
  }) async {
    final AnalysisGitResult result;
    try {
      result = await AnalysisGit.run(
        workingDirectory,
        arguments,
        // diff.relative=true면 `git diff`가 cwd 상대 경로를 출력한다. 패키지
        // 루트가 저장소 루트와 다르면 아래에서 저장소 루트와 join할 때 경로가
        // 어긋나 변경 파일 집합이 잘못 계산된다. 경로는 항상 저장소 루트 기준으로
        // 고정한다.
        configuration: ['diff.relative=false', ...configuration],
      );
    } on AnalysisGitException catch (refused) {
      throw ChangedFilesException(
        unneutralizableFilterDriver:
            refused.refusal == AnalysisGitRefusal.unneutralizableFilterDriver,
      );
    }
    if (result.exitCode != 0) {
      throw const ChangedFilesException();
    }
    return decodeChangedFilesOutput(result.stdout, nulSeparated: nulSeparated);
  }
}

/// git의 원시 바이트 출력을 경로 목록으로 나눈다.
///
/// `-z` 원시 바이트의 파일명이 비-UTF8일 수 있다(Linux에서 가능, macOS APFS는
/// 거부). 디코드 실패는 FormatException을 흘려 인덱싱 실패로 오귀인하지 않고
/// [ChangedFilesException]으로 모은다. 플랫폼 없이 테스트 가능한 순수 함수다.
List<String> decodeChangedFilesOutput(
  List<int> stdoutBytes, {
  bool nulSeparated = true,
}) {
  final String decoded;
  try {
    decoded = utf8.decode(stdoutBytes);
  } on FormatException {
    throw const ChangedFilesException();
  }
  return decoded
      .split(nulSeparated ? '\u0000' : '\n')
      .where((value) => value.isNotEmpty)
      .toList();
}
