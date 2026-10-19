import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// 분석용 git 조회를 실행하지 않은 이유다.
enum AnalysisGitRefusal {
  /// `git config`로 설정을 읽지 못했다. 어떤 filter 드라이버가 설정됐는지
  /// 모르면 끌 수도 없으므로 조회를 실행하지 않는다.
  configurationUnreadable,

  /// filter 드라이버 이름에 `=`가 있거나 UTF-8이 아니다. git은 `-c` 값을 첫
  /// `=`에서 키와 값으로 나누고 프로세스 인자는 UTF-8 문자열로만 넘어가므로,
  /// 그런 이름의 드라이버는 `-c`로 끌 수 없다.
  unneutralizableFilterDriver,
}

/// 분석용 git 조회가 저장소 설정의 명령을 끌 수 없어 실행되지 않았다.
final class AnalysisGitException implements Exception {
  /// 이유만 남긴다. 드라이버 이름 원문은 신뢰하지 않는 설정 값이라 싣지 않는다.
  const AnalysisGitException(this.refusal);

  /// 조회를 실행하지 않은 이유다.
  final AnalysisGitRefusal refusal;
}

/// 분석용 git 조회 하나의 종료 코드와 원시 stdout 바이트다.
typedef AnalysisGitResult = ({int exitCode, List<int> stdout});

/// 분석 대상 저장소에서 읽기 전용 git 조회를 실행한다.
///
/// 분석 대상 저장소(와 사용자 전역·시스템) 설정이 정한 명령을 실행하지 않는다
/// (DECISIONS D1). `.git`째로 받은 저장소의 설정은 공격자가 고를 수 있다.
abstract final class AnalysisGit {
  /// [workingDirectory]에서 `git <격리 인자> -C <dir> <arguments>`를 실행한다.
  ///
  /// 실행 바로 앞에서 설정된 filter 드라이버 이름을 다시 모아, 이름마다
  /// clean·smudge·process를 빈 명령으로, required를 false로 덮는다. git은 빈
  /// filter 명령을 실행하지 않는다. `--attr-source`는 `.git/info/attributes`를
  /// 막지 못해 쓰지 않는다. 공통 격리는 [_isolation]에 있다.
  ///
  /// [arguments]는 하위 명령과 그 인자다. 하위 명령별 격리(diff의
  /// `--no-ext-diff --no-textconv`, 서브모듈 안에서 git을 띄우는 명령의
  /// `--ignore-submodules=all`, 작업 트리 diff의 `diff.autoRefreshIndex=false`)는
  /// 호출자가 [arguments]와 [configuration]에 넣는다. [configuration]은 더 붙일
  /// `-c` 값이다.
  ///
  /// 설정을 읽지 못했거나 끌 수 없는 드라이버 이름이 있으면 조회를 실행하지 않고
  /// [AnalysisGitException]을 던진다. git이 없으면 [ProcessException]이다.
  static Future<AnalysisGitResult> run(
    String workingDirectory,
    List<String> arguments, {
    List<String> configuration = const [],
  }) async {
    final drivers = await _configuredFilterDrivers(workingDirectory);
    return _git([
      ..._isolation,
      for (final name in drivers) ..._disableFilter(name),
      for (final value in configuration) ...['-c', value],
      '-C',
      workingDirectory,
      ...arguments,
    ]);
  }
}

/// 모든 분석용 git 호출(설정 조회 포함)의 앞 인자다.
///
/// - `--no-optional-locks`: `git status`는 stat만 바뀐 파일을 새로 고친 index를
///   기회가 되면 다시 쓰고, 그때 `post-index-change` 훅을 실행한다.
/// - `core.fsmonitor=false`: 설정된 fsmonitor 훅을 실행하지 않는다. git이
///   서브모듈 안에서 띄우는 git에도 이 `-c` 값이 전해진다.
/// - `log.showSignature=false`: 서명 확인 프로그램을 부르지 않는다.
const _isolation = [
  '--no-optional-locks',
  '-c',
  'core.fsmonitor=false',
  '-c',
  'log.showSignature=false',
];

/// 드라이버 [name]의 명령을 빈 값으로 덮는다. required=false가 없으면 required
/// 드라이버(git-lfs 등)는 "clean filter failed"로 git을 실패시킨다.
List<String> _disableFilter(String name) => [
  '-c',
  'filter.$name.clean=',
  '-c',
  'filter.$name.smudge=',
  '-c',
  'filter.$name.process=',
  '-c',
  'filter.$name.required=false',
];

/// 설정된 filter 드라이버 이름을 읽기 전용 `git config`로 모은다.
///
/// `--get-regexp`를 쓰지 않는다. UTF-8 로캘의 git은 정규식 `.`가 UTF-8이 아닌
/// 이름과 맞지 않아 그 드라이버를 빠뜨리는데, 속성은 이름을 바이트로 대조해 그
/// 드라이버를 실행한다(git 2.54 확인). 이름 전체를 받아 바이트로 거른다.
Future<List<String>> _configuredFilterDrivers(String workingDirectory) async {
  final result = await _git([
    ..._isolation,
    '-C',
    workingDirectory,
    'config',
    '-z',
    '--includes',
    '--name-only',
    '--list',
  ]);
  if (result.exitCode != 0) {
    throw const AnalysisGitException(
      AnalysisGitRefusal.configurationUnreadable,
    );
  }
  return parseFilterDriverNames(result.stdout);
}

Future<AnalysisGitResult> _git(List<String> arguments) async {
  final process = await Process.run(
    'git',
    arguments,
    stdoutEncoding: null,
    // stderr는 어디에도 쓰지 않는다. utf8 디코딩으로 두면 비-UTF8 stderr가
    // Process.run 안에서 FormatException을 내 호출자의 실패 계약을 빠져나간다.
    stderrEncoding: null,
  );
  return (exitCode: process.exitCode, stdout: process.stdout as List<int>);
}

/// `git config -z --name-only --list` 출력에서 filter 드라이버 이름을 모은다.
///
/// 드라이버 이름은 `filter.`과 마지막 `.<키>` 사이 전체다(점·공백이 들어갈 수
/// 있고 대소문자를 구분한다). 키가 clean·smudge·process인 항목만 센다. 빈 이름도
/// 드라이버다(`* filter=`가 고른다). 정렬·중복 제거해 `-c` 순서를 결정적으로 둔다.
///
/// `=`가 들거나 UTF-8이 아닌 이름은 `-c`로 덮을 수 없어
/// [AnalysisGitRefusal.unneutralizableFilterDriver]로 거부한다.
List<String> parseFilterDriverNames(List<int> output) {
  final names = SplayTreeSet<String>();
  // latin1은 바이트를 그대로 옮긴다. 다른 섹션의 비-UTF8 키로 실패하지 않는다.
  for (final key in latin1.decode(output).split('\u0000')) {
    final name = _filterDriverName(key);
    if (name != null) names.add(_neutralizableName(name));
  }
  return names.toList();
}

/// 섹션·변수 이름은 git이 소문자로 낸다. 드라이버(subsection)가 없는
/// `filter.clean`은 드라이버가 아니다.
String? _filterDriverName(String key) {
  const prefix = 'filter.';
  const commands = {'clean', 'smudge', 'process'};
  final separator = key.lastIndexOf('.');
  if (!key.startsWith(prefix) || separator < prefix.length) return null;
  if (!commands.contains(key.substring(separator + 1))) return null;
  return key.substring(prefix.length, separator);
}

/// latin1로 옮긴 이름 바이트를 UTF-8 문자열로 돌린다.
String _neutralizableName(String latin1Name) {
  final bytes = latin1.encode(latin1Name);
  if (bytes.contains(0x3d)) {
    throw const AnalysisGitException(
      AnalysisGitRefusal.unneutralizableFilterDriver,
    );
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const AnalysisGitException(
      AnalysisGitRefusal.unneutralizableFilterDriver,
    );
  }
}
