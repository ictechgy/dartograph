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

  /// 설정에 promisor 원격(부분 클론)이 있는데 이 git이 `--no-lazy-fetch`를
  /// 모른다(2.45 미만). 부분 클론의 git은 조회에 필요한 객체가 없으면 그 원격에서
  /// `git fetch`를 띄우고, fetch는 원격의 전송 설정이 정한 명령(ssh URL의
  /// `core.sshCommand`, 로컬 경로 URL의 `remote.<이름>.uploadpack` 등)을 실행한다.
  /// 그 fetch를 끌 수 있는지 확인할 수 없으므로 조회를 실행하지 않는다.
  unavoidableLazyFetch,
}

/// 분석용 git 조회가 저장소 설정의 명령을 끌 수 없어 실행되지 않았다.
final class AnalysisGitException implements Exception {
  /// 이유만 남긴다. 드라이버 이름 원문은 신뢰하지 않는 설정 값이라 싣지 않는다.
  const AnalysisGitException(this.refusal);

  /// 조회를 실행하지 않은 이유다.
  final AnalysisGitRefusal refusal;
}

/// 분석용 git 조회 하나의 결과다.
///
/// [exitCode]와 원시 [stdout] 바이트에 더해, 설정에 promisor 원격이 있어 없는
/// 객체를 원격에서 가져오는 fetch를 끄고 실행했는지([partialClone])를 싣는다. 그런
/// 저장소에서 조회가 실패하면 필요한 객체가 로컬에 없어서일 수 있다 — 호출자가
/// 원인을 알릴 때 쓴다.
typedef AnalysisGitResult = ({
  int exitCode,
  List<int> stdout,
  bool partialClone,
});

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
  /// 같은 설정에 promisor 원격이 있으면 `--no-lazy-fetch`를 붙여, 없는 객체를 그
  /// 원격에서 가져오는 fetch(원격의 전송 설정이 정한 명령을 실행한다)를 띄우지
  /// 않는다. 그 옵션을 모르는 git(2.45 미만)이면 조회를 실행하지 않는다.
  ///
  /// [arguments]는 하위 명령과 그 인자다. 하위 명령별 격리(diff의
  /// `--no-ext-diff --no-textconv`, 서브모듈 안에서 git을 띄우는 명령의
  /// `--ignore-submodules=all`, 작업 트리 diff의 `diff.autoRefreshIndex=false`)는
  /// 호출자가 [arguments]와 [configuration]에 넣는다. [configuration]은 더 붙일
  /// `-c` 값이다. [executable]은 실행할 git이다. 시험이 다른 버전의 git을 흉내 낼
  /// 때만 바꾼다.
  ///
  /// 설정을 읽지 못했거나, 끌 수 없는 드라이버 이름이 있거나, promisor 원격의
  /// fetch를 끌 수 없으면 조회를 실행하지 않고 [AnalysisGitException]을 던진다.
  /// git이 없으면 [ProcessException]이다.
  static Future<AnalysisGitResult> run(
    String workingDirectory,
    List<String> arguments, {
    List<String> configuration = const [],
    String executable = 'git',
  }) async {
    final keys = await _configurationKeys(executable, workingDirectory);
    final drivers = parseFilterDriverNames(keys);
    final partialClone = namesPromisorRemote(keys);
    if (partialClone && !await _knowsNoLazyFetch(executable)) {
      throw const AnalysisGitException(AnalysisGitRefusal.unavoidableLazyFetch);
    }
    final result = await _git(executable, [
      ..._isolation,
      if (partialClone) '--no-lazy-fetch',
      for (final name in drivers) ..._disableFilter(name),
      for (final value in configuration) ...['-c', value],
      '-C',
      workingDirectory,
      ...arguments,
    ]);
    return (
      exitCode: result.exitCode,
      stdout: result.stdout,
      partialClone: partialClone,
    );
  }
}

/// git 프로세스 하나의 종료 코드와 원시 stdout 바이트다.
typedef _GitOutput = ({int exitCode, List<int> stdout});

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

/// 설정된 모든 키 이름을 읽기 전용 `git config`로 받는다(`-z` 원시 바이트).
///
/// filter 드라이버 이름과 promisor 원격을 여기서 고른다. `--get-regexp`를 쓰지
/// 않는다. UTF-8 로캘의 git은 정규식 `.`가 UTF-8이 아닌 이름과 맞지 않아 그
/// 드라이버를 빠뜨리는데, 속성은 이름을 바이트로 대조해 그 드라이버를 실행한다
/// (git 2.54 확인). 이름 전체를 받아 바이트로 거른다.
Future<List<int>> _configurationKeys(
  String executable,
  String workingDirectory,
) async {
  final result = await _git(executable, [
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
  return result.stdout;
}

/// [executable]이 `--no-lazy-fetch`를 아는지 묻는다(git 2.45부터 있다).
///
/// 그 옵션을 아는 git은 옵션과 `GIT_NO_LAZY_FETCH`를 모두 따른다. 옵션을 모르는
/// git 가운데 2.44.1 같은 2024년 보안 유지보수판은 그 변수만 따르지만, 그것을
/// 확인할 방법이 없어 막는 쪽으로 다룬다. `version`은 저장소를 찾지 않아 저장소
/// 설정을 읽지 않는다. promisor 원격이 있을 때만 묻는다.
Future<bool> _knowsNoLazyFetch(String executable) async {
  final probe = await _git(executable, const ['--no-lazy-fetch', 'version']);
  return probe.exitCode == 0;
}

Future<_GitOutput> _git(String executable, List<String> arguments) async {
  final process = await Process.run(
    executable,
    arguments,
    // 없는 객체를 promisor 원격에서 가져오는 fetch를 끈다. 이 변수를 아는 git에서는
    // `--no-lazy-fetch`를 붙이지 않은 호출(설정 조회 등)에서도 막힌다. 모르는 git은
    // 무시하므로, 막는 근거는 [AnalysisGit.run]의 promisor 원격 확인이다.
    environment: const {'GIT_NO_LAZY_FETCH': '1'},
    stdoutEncoding: null,
    // stderr는 어디에도 쓰지 않는다. utf8 디코딩으로 두면 비-UTF8 stderr가
    // Process.run 안에서 FormatException을 내 호출자의 실패 계약을 빠져나간다.
    stderrEncoding: null,
  );
  return (exitCode: process.exitCode, stdout: process.stdout as List<int>);
}

/// `git config -z --name-only --list` 출력에 promisor 원격(부분 클론) 설정이
/// 있는지 본다.
///
/// git은 `extensions.partialClone`이 가리키는 원격과, `remote.<이름>.promisor`나
/// `remote.<이름>.partialCloneFilter`가 있는 원격을 promisor로 쓴다. 키 이름만 보고
/// 값은 보지 않는다 — `promisor = false`도 promisor로 센다(막는 쪽). 섹션·변수
/// 이름은 git이 소문자로 낸다.
bool namesPromisorRemote(List<int> output) {
  for (final key in latin1.decode(output).split('\u0000')) {
    if (key == 'extensions.partialclone') return true;
    if (!key.startsWith('remote.')) continue;
    if (key.endsWith('.promisor') || key.endsWith('.partialclonefilter')) {
      return true;
    }
  }
  return false;
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
