// executable의 실행 파일 설정 검사와 Windows PATH 탐색을 검증한다. vscode 없이
// `node`로 실행한다. 플랫폼과 파일 확인을 주입하므로 Windows 규칙도 어느 OS에서나
// 확인된다.
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { resolveExecutable } = require('../executable');

const posix = { platform: 'linux' };

/// 거부 결과인지, 그리고 원인에 설정값이 드러나는지 확인한다.
function assertRejected(value, options) {
  const result = resolveExecutable(value, options);
  assert.strictEqual(result.command, undefined, String(value));
  assert.strictEqual(result.missing, false, String(value));
  assert.ok(result.reason.startsWith('dartograph.executable '), result.reason);
  assert.ok(result.reason.includes('user settings'), result.reason);
  return result.reason;
}

// 절대 경로는 탐색 없이 그대로 실행한다.
assert.deepStrictEqual(resolveExecutable('/opt/dart/bin/dartograph', posix), {
  command: '/opt/dart/bin/dartograph',
});

// POSIX: execvp는 PATH의 빈 항목(앞뒤·연속 `:`)과 상대 항목을 cwd(패키지 루트)
// 기준으로 푼다. 그래서 이름은 PATH의 절대 경로 디렉터리에서만 찾아 그 절대 경로를
// 넘긴다. 패키지 루트에 심은 같은 이름 파일(`dartograph`, `./dartograph`,
// `node_modules/.bin/dartograph`)은 후보가 되지 않는다.
const executables = new Set([
  'dartograph',
  './dartograph',
  'node_modules/.bin/dartograph',
  '/opt/pub/bin/dartograph',
  '/usr/bin/dartograph',
  '/bin/dartograph',
]);
const posixProbed = [];
/// [searchPath]를 PATH로 쓰는 POSIX 탐색 옵션이다. 확인한 경로를 [posixProbed]에 남긴다.
function posixOn(searchPath) {
  return {
    platform: 'linux',
    searchPath,
    isExecutable: (file) => {
      posixProbed.push(file);
      return executables.has(file);
    },
  };
}
for (const [searchPath, command] of [
  [':/usr/bin:/bin', '/usr/bin/dartograph'],
  ['.:/usr/bin', '/usr/bin/dartograph'],
  ['node_modules/.bin:/opt/pub/bin', '/opt/pub/bin/dartograph'],
  ['/empty::/bin:', '/bin/dartograph'],
  // PATH가 비면 execvp 기본값과 같은 취지의 절대 경로만 본다(cwd를 보지 않는다).
  ['', '/usr/bin/dartograph'],
]) {
  posixProbed.length = 0;
  assert.deepStrictEqual(
    resolveExecutable('dartograph', posixOn(searchPath)),
    { command },
    searchPath,
  );
  // 빈 항목·상대 항목은 확인조차 하지 않는다.
  assert.ok(
    posixProbed.every((file) => path.posix.isAbsolute(file)),
    `${searchPath}: ${posixProbed}`,
  );
}
// 절대 경로 디렉터리에 없으면 실행하지 않는다. 원인은 패키지 폴더를 찾지 않는다는
// 사실을 알린다.
for (const searchPath of [':.:node_modules/.bin', '/empty', 'tools:/empty:']) {
  const result = resolveExecutable('dartograph', posixOn(searchPath));
  assert.strictEqual(result.command, undefined, searchPath);
  assert.strictEqual(result.missing, true, searchPath);
  assert.ok(result.reason.includes('"dartograph"'), result.reason);
  assert.ok(result.reason.includes('package folder'), result.reason);
}

// 실제 파일 시스템 확인: 실행 권한 없는 정규 파일과 같은 이름 디렉터리는 건너뛰고
// 다음 디렉터리의 실행 파일을 고른다. 링크는 대상을 본다.
if (process.platform !== 'win32') {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'dartograph-path-'));
  try {
    const directories = ['plain', 'folder', 'run', 'ln'].map((name) =>
      path.join(scratch, name),
    );
    const [plain, folder, runnable, linked] = directories;
    for (const directory of directories) fs.mkdirSync(directory);
    fs.writeFileSync(path.join(plain, 'dartograph'), '#!/bin/sh\n', {
      mode: 0o644,
    });
    fs.mkdirSync(path.join(folder, 'dartograph'));
    fs.writeFileSync(path.join(runnable, 'dartograph'), '#!/bin/sh\n', {
      mode: 0o755,
    });
    fs.symlinkSync(
      path.join(runnable, 'dartograph'),
      path.join(linked, 'dartograph'),
    );
    assert.deepStrictEqual(
      resolveExecutable('dartograph', {
        platform: process.platform,
        searchPath: [plain, folder, runnable].join(':'),
      }),
      { command: path.join(runnable, 'dartograph') },
    );
    assert.deepStrictEqual(
      resolveExecutable('dartograph', {
        platform: process.platform,
        searchPath: [plain, linked].join(':'),
      }),
      { command: path.join(linked, 'dartograph') },
    );
    assert.strictEqual(
      resolveExecutable('dartograph', {
        platform: process.platform,
        searchPath: [plain, folder].join(':'),
      }).missing,
      true,
    );
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

// 상대 경로는 패키지 루트를 기준으로 풀리므로 거부한다. `~`는 셸이 아니라
// 펼치지 않고, 역슬래시는 Windows 경로를 옮겨 적은 값으로 본다.
for (const value of [
  './dartograph',
  'tools/dartograph',
  '../bin/dartograph',
  '~/bin/dartograph',
  'tools\\dartograph',
]) {
  const reason = assertRejected(value, posix);
  assert.ok(reason.includes(JSON.stringify(value)), reason);
  assert.ok(reason.includes('relative path'), reason);
}

// 빈 값·공백·문자열이 아닌 값·NUL 문자는 execFile이 던지기 전에 거부한다.
for (const value of ['', '   ', 42, null, undefined, ['dartograph'], 'a\0b']) {
  assertRejected(value, posix);
}

// Windows: libuv는 이름만 받은 실행 파일을 PATH보다 먼저 cwd(패키지 루트)에서
// 찾는다. 그래서 이름은 PATH의 절대 경로 디렉터리에서만 찾아 그 경로를 넘긴다.
// cwd와 상대 항목(cwd 기준)의 dartograph.exe는 후보가 되지 않는다.
const files = new Set([
  'C:\\work\\app\\dartograph.exe',
  'tools\\dartograph.exe',
  'C:\\Pub Cache\\bin\\dartograph.exe',
  'C:\\Both\\dartograph.com',
  'C:\\Both\\dartograph.exe',
  'C:\\Exact\\dartograph.exe',
  'C:\\Exact\\dartograph.exe.com',
]);
const probed = [];
/// [searchPath]를 PATH로 쓰는 Windows 탐색 옵션이다. 확인한 경로를 [probed]에 남긴다.
function windows(searchPath) {
  return {
    platform: 'win32',
    searchPath,
    isFile: (file) => {
      probed.push(file);
      return files.has(file);
    },
  };
}

assert.deepStrictEqual(
  resolveExecutable(
    'dartograph',
    windows('tools;;.;C:\\Empty;"C:\\Pub Cache\\bin";C:\\Both'),
  ),
  { command: 'C:\\Pub Cache\\bin\\dartograph.exe' },
);
// 상대 항목·빈 항목은 확인조차 하지 않고, 디렉터리마다 .com 다음 .exe를 본다.
assert.deepStrictEqual(probed, [
  'C:\\Empty\\dartograph.com',
  'C:\\Empty\\dartograph.exe',
  'C:\\Pub Cache\\bin\\dartograph.com',
  'C:\\Pub Cache\\bin\\dartograph.exe',
]);
// 같은 디렉터리에서는 .com이 .exe보다 먼저다(libuv·cmd.exe와 같은 순서).
assert.deepStrictEqual(resolveExecutable('dartograph', windows('C:\\Both')), {
  command: 'C:\\Both\\dartograph.com',
});
// 확장자를 준 이름은 그 이름을 먼저 찾는다.
assert.deepStrictEqual(
  resolveExecutable('dartograph.exe', windows('C:\\Exact')),
  { command: 'C:\\Exact\\dartograph.exe' },
);
// 찾지 못하면 실행하지 않는다. 원인은 패키지 폴더를 찾지 않는다는 사실을 알린다.
for (const searchPath of ['', 'tools;.', 'C:\\Empty']) {
  const result = resolveExecutable('dartograph', windows(searchPath));
  assert.strictEqual(result.command, undefined, searchPath);
  assert.strictEqual(result.missing, true, searchPath);
  assert.ok(result.reason.includes('"dartograph"'), result.reason);
  assert.ok(result.reason.includes('package folder'), result.reason);
}

// Windows의 절대 경로(드라이브·UNC)는 탐색 없이 그대로 실행한다.
probed.length = 0;
for (const value of [
  'C:\\Tools\\dartograph.exe',
  'C:/Tools/dartograph.exe',
  '\\\\server\\share\\dartograph.exe',
]) {
  assert.deepStrictEqual(resolveExecutable(value, windows('C:\\Both')), {
    command: value,
  });
}
assert.deepStrictEqual(probed, []);
// 드라이브 상대 경로(`C:dartograph`)도 cwd 기준이라 거부한다.
for (const value of [
  '.\\dartograph',
  'tools\\dartograph',
  'tools/dartograph',
  'C:dartograph',
]) {
  assertRejected(value, windows('C:\\Both'));
}

console.log('executable.test.js: all assertions passed');
