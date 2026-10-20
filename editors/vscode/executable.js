// dartograph.executable 설정값을 execFile에 넘길 명령으로 바꾸고, 그 실행에 넘길
// 환경을 만든다. vscode API에 의존하지 않아 `node test/`로 단위 검증할 수 있다.
'use strict';

const fs = require('fs');
const path = require('path');

/// 받을 수 없는 설정값을 고치는 방법이다. 실행 파일은 machine 범위 설정이라
/// 사용자(원격) 설정에서만 바꿀 수 있다.
const REMEDY =
  'set it to an absolute path or a command name on PATH in user settings';

/// POSIX에서 PATH가 없거나 비었을 때 찾는 디렉터리이고, CLI에 넘길 PATH에 절대
/// 경로 디렉터리가 하나도 남지 않을 때 대신 넘기는 값이다. execvp의 기본 경로와 같은
/// 취지이고, 모두 절대 경로라 패키지 루트를 보지 않는다.
const DEFAULT_POSIX_PATH = '/usr/bin:/bin';

/// 실행 파일 설정 [executable]을 execFile에 넘길 명령으로 바꾼다.
///
/// 절대 경로와 경로 구분자 없는 명령 이름만 받는다. 상대 경로(`./x`·`tools/x`·
/// `~/bin/x`)는 execFile의 cwd인 패키지 루트를 기준으로 풀려 저장소가 커밋한
/// 파일을 실행하게 되므로 거부한다. 이름도 PATH의 절대 경로 디렉터리에서 직접
/// 찾아 그 절대 경로를 넘긴다. Windows의 libuv는 이름만 받은 실행 파일을 PATH보다
/// 먼저 cwd에서 찾고, POSIX의 execvp는 PATH의 빈 항목(앞뒤·연속 `:`)과 상대
/// 항목(`.`·`node_modules/.bin`)을 cwd 기준으로 풀기 때문이다.
///
/// [options]는 시험용 주입점이다: `platform`(기본 `process.platform`),
/// `searchPath`(기본 PATH 환경 변수), `isFile`(Windows 후보 확인, 기본 파일
/// 시스템), `isExecutable`(POSIX 후보 확인, 기본 파일 시스템). 반환값은 실행할 수
/// 있으면 `{ command }`, 아니면 `{ reason, missing }`이다. reason은 출력 채널에
/// 남길 원인과 해결 방향이고, missing은 PATH에서 찾지 못한 경우에만 true다.
function resolveExecutable(executable, options = {}) {
  const platform = options.platform || process.platform;
  const pathApi = platform === 'win32' ? path.win32 : path.posix;
  if (!isUsableString(executable)) {
    return rejected(
      'dartograph.executable is empty, not a string, or contains a NUL ' +
        `character; ${REMEDY}`,
    );
  }
  if (pathApi.isAbsolute(executable)) return { command: executable };
  if (!isCommandName(executable, platform)) {
    return rejected(
      `dartograph.executable ${JSON.stringify(executable)} is a relative ` +
        `path, which would run a file inside the package folder; ${REMEDY}`,
    );
  }
  return platform === 'win32'
    ? findOnWindowsPath(executable, options)
    : findOnPosixPath(executable, options);
}

/// 실행할 수 없다는 결과다.
function rejected(reason) {
  return { reason, missing: false };
}

/// 명령으로 쓸 수 없는 값(문자열 아님·빈 값·공백뿐인 값·NUL 문자)을 걸러 낸다.
/// 공백뿐인 값을 뺀 나머지는 execFile이 동기 예외를 던져 명령 전체가 실패한다.
function isUsableString(value) {
  return (
    typeof value === 'string' && value.trim() !== '' && !value.includes('\0')
  );
}

/// 경로 없이 이름만 준 값인지 본다. 역슬래시는 POSIX에서도 Windows 경로를 옮겨
/// 적은 값으로 보고, Windows의 `:`는 드라이브 상대 경로(`C:x`)라 이름이 아니다.
function isCommandName(value, platform) {
  if (value.includes('/') || value.includes('\\')) return false;
  return platform !== 'win32' || !value.includes(':');
}

/// Windows PATH의 절대 경로 디렉터리에서 [name]을 찾는다. libuv가 맨 앞에 보는
/// cwd(패키지 루트)를 빼고, cwd 기준으로 풀리는 상대 항목도 건너뛴다. 남은
/// 디렉터리의 순서와 디렉터리마다 시도하는 후보 순서는 libuv와 같다.
function findOnWindowsPath(name, options) {
  const searchPath = options.searchPath ?? process.env.PATH ?? '';
  const isFile = options.isFile || isRegularFile;
  for (const entry of searchPath.split(';')) {
    const directory = entry.replace(/^["']/, '').replace(/["']$/, '');
    if (!path.win32.isAbsolute(directory)) continue;
    for (const candidate of windowsCandidates(name)) {
      const file = path.win32.join(directory, candidate);
      if (isFile(file)) return { command: file };
    }
  }
  return notFoundOnPath(name);
}

/// POSIX PATH의 절대 경로 디렉터리에서 [name]을 찾는다. execvp가 cwd(패키지
/// 루트) 기준으로 푸는 빈 항목과 상대 항목은 건너뛴다. 남은 디렉터리는 execvp와
/// 같은 순서로 보고, 실행 권한이 있는 정규 파일만 고른다.
function findOnPosixPath(name, options) {
  const searchPath = options.searchPath ?? process.env.PATH;
  const isExecutable = options.isExecutable || isExecutableFile;
  for (const directory of absolutePosixDirectories(searchPath)) {
    const file = path.posix.join(directory, name);
    if (isExecutable(file)) return { command: file };
  }
  return notFoundOnPath(name);
}

/// POSIX PATH 값 [searchPath]의 절대 경로 디렉터리를 PATH 순서대로 돌려준다.
/// 빈 항목(앞뒤·연속 `:`)과 상대 항목(`.`·`node_modules/.bin`)은 execvp와 셸이
/// cwd 기준으로 풀므로 뺀다. PATH가 없거나 비었으면 [DEFAULT_POSIX_PATH]를 본다.
/// 확장의 첫 탐색과 CLI에 넘기는 PATH가 같은 규칙을 쓰게 하는 한 곳이다.
function absolutePosixDirectories(searchPath) {
  return (searchPath || DEFAULT_POSIX_PATH)
    .split(':')
    .filter((directory) => path.posix.isAbsolute(directory));
}

/// CLI를 실행할 때 넘길 환경 변수를 만든다.
///
/// POSIX에서는 PATH를 절대 경로 디렉터리만 남긴 값으로 바꾸고, 다른 변수는 그대로
/// 둔다. 확장이 찾은 CLI와 그 자손도 프로그램을 이름으로 찾기 때문이다. pub이
/// 설치하는 실행 스크립트는 `#!/usr/bin/env sh`로 시작해 `dart`를 부르고, CLI는
/// `--since`·`--record`에서 git을 부른다. 이들은 cwd(패키지 루트)를 물려받아 PATH의
/// 빈·상대 항목을 그 기준으로 풀므로, 첫 탐색만 막으면 저장소가 `sh`·`dart`·`git`
/// 이름으로 커밋한 파일이 실행된다. 남는 디렉터리가 없으면 [DEFAULT_POSIX_PATH]를
/// 넘긴다. 빈 PATH는 execvp가 현재 디렉터리로 읽기 때문이다.
///
/// Windows에서는 받은 환경을 그대로 돌려준다. Windows의 이름 탐색(CreateProcess·
/// cmd.exe)은 PATH보다 현재 디렉터리를 먼저 보므로 PATH를 고쳐서는 막지 못하고,
/// 기존 동작을 바꾸지 않는다.
///
/// [options]는 시험용 주입점이다: `platform`(기본 `process.platform`), `environment`
/// (기본 `process.env`). 받은 환경 객체는 바꾸지 않는다.
function childEnvironment(options = {}) {
  const platform = options.platform || process.platform;
  const environment = options.environment || process.env;
  if (platform === 'win32') return environment;
  const directories = absolutePosixDirectories(environment.PATH);
  const searchPath =
    directories.length > 0 ? directories.join(':') : DEFAULT_POSIX_PATH;
  return { ...environment, PATH: searchPath };
}

/// PATH의 절대 경로 디렉터리에서 [name]을 찾지 못했다는 결과다.
function notFoundOnPath(name) {
  return {
    reason:
      `${JSON.stringify(name)} was not found in an absolute directory on ` +
      'PATH, and the package folder is not searched; install the dartograph ' +
      'CLI on PATH or set dartograph.executable to an absolute path in user ' +
      'settings',
    missing: true,
  };
}

/// libuv가 이름마다 시도하는 파일 이름이다: 확장자가 있으면 그 이름을 먼저,
/// 그다음 `.com`, `.exe`를 붙인 이름이다.
function windowsCandidates(name) {
  const dot = name.lastIndexOf('.');
  const hasExtension = dot !== -1 && dot < name.length - 1;
  return [...(hasExtension ? [name] : []), `${name}.com`, `${name}.exe`];
}

/// [file]이 정규 파일이면 true다.
function isRegularFile(file) {
  try {
    const stat = fs.statSync(file, { throwIfNoEntry: false });
    return stat !== undefined && stat.isFile();
  } catch {
    // ENOTDIR·EACCES처럼 읽을 수 없는 후보는 '여기에 없음'으로 보고 다음 후보를
    // 본다. libuv와 cmd.exe도 읽지 못한 PATH 디렉터리를 건너뛰고 계속 찾는다.
    return false;
  }
}

/// [file]이 지금 사용자가 실행할 수 있는 정규 파일이면 true다(링크는 따라간다).
function isExecutableFile(file) {
  try {
    const stat = fs.statSync(file, { throwIfNoEntry: false });
    if (stat === undefined || !stat.isFile()) return false;
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    // 실행 권한이 없거나(EACCES) 읽을 수 없는(ENOTDIR 등) 후보는 '여기에 없음'으로
    // 보고 다음 디렉터리를 본다. execvp도 그런 후보를 건너뛰고 계속 찾는다.
    return false;
  }
}

module.exports = { childEnvironment, resolveExecutable };
