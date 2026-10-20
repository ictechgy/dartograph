// extension.js의 영향 점검 배선과 실행 파일 설정의 신뢰 경계를 VS Code 없이
// 검증한다. `node`로 실행한다.
// vscode 모듈은 이 파일의 가짜로 바꾸고, CLI는 실제 `impact --changed` 계약을
// 흉내 내는 가짜 실행 파일로 바꾼다 — 값을 목록 파일 경로로 읽고, 읽지 못하면
// 'Changed list could not be read'와 함께 64로 끝난다.
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

// CLI가 실제로 낸 `impact --format json` 문서에서 고른 항목이다(키·값 그대로).
// 위험도 키는 `risk`이고, 파일 항목은 source가 없어 진단이 되지 않는다.
const report = {
  impacted: [
    {
      depth: 1,
      id: 'package:app/step1.dart',
      kind: 'file',
      path: ['package:app/step1.dart', 'package:app/step0.dart'],
      risk: 'high',
      riskScore: 90,
    },
    {
      column: 1,
      depth: 1,
      id: 'package:app/step1.dart::step1',
      kind: 'declaration',
      line: 3,
      path: ['package:app/step1.dart::step1', 'package:app/step0.dart::step0'],
      risk: 'high',
      riskScore: 100,
      source: 'lib/step1.dart',
    },
  ],
  limitations: [
    'tests and visibleForTesting declarations are conservative retention roots',
  ],
  tests: [
    {
      depth: 2,
      id: 'project:test/step1_test.dart::main',
      path: [
        'project:test/step1_test.dart::main',
        'package:app/step1.dart::step1',
        'package:app/step0.dart::step0',
      ],
      source: 'test/step1_test.dart',
    },
  ],
};

const commands = new Map();
const collections = new Map();
const notices = [];
const outputLines = [];
const settings = new Map();
const editorState = { activeTextEditor: undefined, workspaceFolder: undefined };

/// 경로 하나를 가리키는 최소 Uri다. 진단 컬렉션은 fsPath로 묶어 비교한다.
function fileUri(fsPath) {
  return { fsPath, toString: () => `file://${fsPath}` };
}

/// extension.js가 쓰는 vscode API만 흉내 낸다.
const vscodeStub = {
  DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
  FileType: { File: 1, Directory: 2 },
  Range: class {
    constructor(startLine, startCol, endLine, endCol) {
      Object.assign(this, { startLine, startCol, endLine, endCol });
    }
  },
  Diagnostic: class {
    constructor(range, message, severity) {
      Object.assign(this, { range, message, severity });
    }
  },
  Uri: {
    file: fileUri,
    joinPath: (base, ...segments) =>
      fileUri(path.join(base.fsPath, ...segments)),
  },
  languages: {
    createDiagnosticCollection(name) {
      const entries = new Map();
      collections.set(name, entries);
      return {
        set: (uri, items) => entries.set(uri.fsPath, items),
        clear: () => entries.clear(),
        dispose() {},
      };
    },
  },
  window: {
    get activeTextEditor() {
      return editorState.activeTextEditor;
    },
    createOutputChannel: () => ({
      appendLine: (line) => outputLines.push(line),
      dispose() {},
    }),
    showInformationMessage: (message) => notices.push(['information', message]),
    showErrorMessage: (message) => notices.push(['error', message]),
    setStatusBarMessage: (message) => notices.push(['status', message]),
  },
  commands: {
    registerCommand(id, callback) {
      commands.set(id, callback);
      return { dispose() {} };
    },
  },
  workspace: {
    workspaceFolders: [],
    // 작업 공간 분석이 pubspec.yaml을 찾을 때 쓰는 stat만 실제 파일 시스템으로 옮긴다.
    fs: { stat: (uri) => fs.promises.stat(uri.fsPath) },
    onDidSaveTextDocument: () => ({ dispose() {} }),
    getConfiguration: () => ({
      get: (key, fallback) =>
        settings.has(key) ? settings.get(key) : fallback,
    }),
    getWorkspaceFolder: () => editorState.workspaceFolder,
  },
};

// 실행 파일 해석기는 실제 모듈을 쓰되, 확장이 해석 결과를 그대로 실행하는지
// 보려고 결과를 바꿔 끼울 수 있게 감싼다(Windows의 PATH 해석은 이 OS에서 돌지 않는다).
const executableModule = require('../executable');
let resolveOverride = null;
const executableStub = {
  resolveExecutable: (value, options) =>
    resolveOverride
      ? resolveOverride(value)
      : executableModule.resolveExecutable(value, options),
};

const originalLoad = Module._load;
Module._load = function load(request, parent, isMain) {
  if (request === 'vscode') return vscodeStub;
  if (request === './executable') return executableStub;
  return originalLoad.call(this, request, parent, isMain);
};
const extension = require('../extension');

/// 받은 인자와 `--changed` 목록을 [recordPath]에 남기고 [exitCode]로 끝나는
/// 가짜 CLI 소스다. 종료 0이면 [report]를 stdout에 쓴다.
function fakeCliSource(recordPath, exitCode) {
  return `#!/usr/bin/env node
'use strict';
const fs = require('fs');
const args = process.argv.slice(2);
const changed = args[args.indexOf('--changed') + 1];
let entries;
try {
  entries = JSON.parse(fs.readFileSync(changed, 'utf8'));
} catch {
  process.stderr.write('Changed list could not be read: ' + changed + '\\n');
  process.exit(64);
}
fs.writeFileSync(
  ${JSON.stringify(recordPath)},
  JSON.stringify({ args, changed, entries }),
);
if (${exitCode} === 0) {
  process.stdout.write(${JSON.stringify(JSON.stringify(report))});
}
process.exit(${exitCode});
`;
}

/// 실행되면 받은 인자를 [markerPath]에 한 줄씩 덧붙이는 가짜 CLI 소스다. 저장소가
/// 커밋해 둔 스크립트 역할이다 — 기록이 생기면 확장이 그 스크립트를 실행한 것이다.
function markerCliSource(markerPath) {
  return `#!/usr/bin/env node
'use strict';
require('fs').appendFileSync(
  ${JSON.stringify(markerPath)},
  JSON.stringify(process.argv.slice(2)) + '\\n',
);
`;
}

/// [source]를 [file]에 실행 가능한 스크립트로 쓴다.
function writeScript(file, source) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, source);
  fs.chmodSync(file, 0o755);
}

/// 실행 파일 설정을 [executable]로 두고 [command]를 한 번 실행한다. 알림과 출력
/// 채널 기록은 이 실행의 것만 남긴다.
async function runWithExecutable(command, executable) {
  settings.set('executable', executable);
  notices.length = 0;
  outputLines.length = 0;
  await commands.get(command)();
}

/// 가짜 CLI를 [exitCode]로 설정하고 현재 파일 영향 점검을 한 번 실행한다.
/// CLI가 목록을 읽지 못해 기록을 남기지 않았으면 null이다.
async function checkImpact(scratch, exitCode) {
  const record = path.join(scratch, `record-${exitCode}.json`);
  const executable = path.join(scratch, `fake-dartograph-${exitCode}`);
  fs.rmSync(record, { force: true });
  writeScript(executable, fakeCliSource(record, exitCode));
  await runWithExecutable('dartograph.checkImpact', executable);
  if (!fs.existsSync(record)) return null;
  return JSON.parse(fs.readFileSync(record, 'utf8'));
}

async function main() {
  if (process.platform === 'win32') {
    // 가짜 CLI는 shebang 스크립트라 Windows의 execFile로는 직접 실행되지 않는다.
    console.log('extension.test.js: skipped on Windows');
    return;
  }
  const scratch = fs.mkdtempSync(
    path.join(os.tmpdir(), 'dartograph-extension-test-'),
  );
  try {
    const root = path.join(scratch, 'app');
    fs.mkdirSync(path.join(root, 'lib'), { recursive: true });
    editorState.workspaceFolder = { uri: fileUri(root) };
    editorState.activeTextEditor = {
      document: {
        languageId: 'dart',
        uri: fileUri(path.join(root, 'lib', 'step0.dart')),
      },
    };
    extension.activate({ subscriptions: [] });

    // --changed에는 상대 경로 배열을 담은 목록 파일의 경로가 간다. 파일은
    // 작업 공간이 아니라 OS 임시 디렉터리에 두고, 점검이 끝나면 지운다.
    const seen = await checkImpact(scratch, 0);
    // 실패하면 CLI가 출력 채널에 남긴 원인을 함께 보여 준다.
    assert.deepStrictEqual(
      notices.filter(([kind]) => kind === 'error'),
      [],
      `impact check failed: ${outputLines.join('\n')}`,
    );
    assert.deepStrictEqual(seen.entries, ['lib/step0.dart']);
    // 기본 인자는 증분 사실 캐시를 작업 공간 밖 사용자 캐시에 둔다. 작업 공간
    // 안 `.dartograph/cache`는 저장소가 위조한 캐시를 심어 둘 수 있는 자리다.
    assert.deepStrictEqual(seen.args, [
      'impact',
      '--changed',
      seen.changed,
      '--format',
      'json',
      '--incremental-user-cache',
      root,
    ]);
    // 실제 VS Code는 package.json이 선언한 기본값을 넘긴다 — 두 기본값이 같아야
    // 위의 인자가 설치된 확장의 동작이다.
    const manifest = JSON.parse(
      fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'),
    );
    const properties = manifest.contributes.configuration.properties;
    assert.deepStrictEqual(properties['dartograph.args'].default, [
      '--incremental-user-cache',
    ]);
    // 실행 파일은 사용자(원격) 설정에서만 정한다 — 작업 공간 settings.json이
    // 저장소 안 스크립트를 가리키게 할 수 없다. args·runOnSave는 신뢰한 작업
    // 공간에서는 작업 공간 값을 계속 쓴다(README 설정 표의 범위).
    assert.strictEqual(properties['dartograph.executable'].scope, 'machine');
    assert.strictEqual(properties['dartograph.args'].scope, undefined);
    assert.strictEqual(properties['dartograph.runOnSave'].scope, undefined);
    // 제한 모드에서도 켜지되 세 설정은 사용자 값만 받는다. 'limited'는 신뢰가
    // 필요한 이유(description)를 함께 선언해야 한다(VS Code Workspace Trust 안내).
    const trust = manifest.capabilities.untrustedWorkspaces;
    assert.strictEqual(trust.supported, 'limited');
    assert.deepStrictEqual(trust.restrictedConfigurations, [
      'dartograph.executable',
      'dartograph.args',
      'dartograph.runOnSave',
    ]);
    assert.strictEqual(typeof trust.description, 'string');
    assert.ok(trust.description.length > 0);
    // 선언하지 않은 이름은 VS Code가 막지 않으므로 오타가 곧 우회로가 된다.
    for (const name of trust.restrictedConfigurations) {
      assert.ok(Object.hasOwn(properties, name), name);
    }
    assert.strictEqual(path.basename(seen.changed), 'changes.json');
    assert.strictEqual(path.dirname(path.dirname(seen.changed)), os.tmpdir());
    assert.strictEqual(fs.existsSync(path.dirname(seen.changed)), false);

    // risk가 high인 대상은 Problems에 경고로 올라간다.
    const impact = collections.get('dartograph-impact');
    const step1 = impact.get(path.join(root, 'lib', 'step1.dart'));
    assert.deepStrictEqual(
      step1.map((item) => [item.severity, item.message]),
      [
        [
          vscodeStub.DiagnosticSeverity.Warning,
          'impacted by change (risk: high, depth: 1)',
        ],
      ],
    );
    assert.strictEqual(
      impact.get(path.join(root, 'test', 'step1_test.dart'))[0].severity,
      vscodeStub.DiagnosticSeverity.Hint,
    );

    // CLI가 분석 실패(2)로 끝나도 오류를 알리고 임시 목록은 지운다.
    const failed = await checkImpact(scratch, 2);
    assert.deepStrictEqual(notices, [
      ['error', 'dartograph impact failed — see output'],
    ]);
    assert.strictEqual(fs.existsSync(path.dirname(failed.changed)), false);

    // 임시 목록을 쓰지 못하면 CLI를 부르지 않고 원인을 출력 채널에 남긴다.
    // os.tmpdir()는 호출마다 TMPDIR을 읽으므로 없는 디렉터리로 돌린다.
    const missing = path.join(scratch, 'missing');
    const unwritten = await withTemporaryDirectory(missing, () =>
      checkImpact(scratch, 0),
    );
    assert.strictEqual(unwritten, null);
    assert.deepStrictEqual(notices, [
      ['error', 'dartograph impact failed — see output'],
    ]);
    assert.ok(outputLines.some((line) => line.includes(missing)), outputLines);

    await checkExecutableBoundary(scratch, root);
    extension.deactivate();
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
  console.log('extension.test.js: all assertions passed');
}

/// 실행 파일 설정은 절대 경로나 PATH의 명령 이름만 받는다. 상대 경로는 execFile의
/// cwd인 패키지 루트를 기준으로 풀려, 저장소가 커밋한 스크립트를 가리킬 수 있다.
async function checkExecutableBoundary(scratch, root) {
  const marker = path.join(scratch, 'planted-script-ran');
  writeScript(path.join(root, 'tools', 'dartograph'), markerCliSource(marker));
  // 저장 시 재분석(runOnSave)이 타는 작업 공간 분석도 그 스크립트를 실행하지
  // 않는다. 세 명령 모두 이유를 남기고, 알림은 한 번만 뜬다.
  fs.writeFileSync(path.join(root, 'pubspec.yaml'), 'name: app\n');
  vscodeStub.workspace.workspaceFolders = [{ uri: fileUri(root) }];
  await runWithExecutable('dartograph.analyzeWorkspace', 'tools/dartograph');
  assert.strictEqual(fs.existsSync(marker), false, 'the planted script ran');
  assert.deepStrictEqual(notices.map(([kind]) => kind), ['error', 'status']);
  assert.ok(notices[0][1].includes('dartograph.executable'), notices[0][1]);
  assert.deepStrictEqual(
    outputLines.map((line) => line.slice(0, line.indexOf(':'))),
    ['[dead] not run', '[deps] not run', '[dup] not run'],
  );
  assert.ok(outputLines[0].includes('"tools/dartograph"'), outputLines[0]);

  // 영향 점검도 같다. `~`는 셸이 아니라 펼치지 않으므로 상대 경로다. 빈 값과
  // 문자열이 아닌 값은 execFile이 던지기 전에 거부한다.
  const rejected = [
    './tools/dartograph',
    'tools\\dartograph',
    '~/bin/x',
    '',
    42,
  ];
  for (const value of rejected) {
    await runWithExecutable('dartograph.checkImpact', value);
    assert.strictEqual(fs.existsSync(marker), false, `ran for ${value}`);
    assert.deepStrictEqual(
      notices.map(([kind]) => kind),
      ['error'],
      String(value),
    );
    assert.strictEqual(outputLines.length, 1, outputLines);
    assert.ok(
      outputLines[0].startsWith('[impact] not run: dartograph.executable'),
      outputLines[0],
    );
  }
  // 같은 값이 다시 거부되면 알림 없이 출력 채널에만 남긴다(저장마다 뜨지 않게).
  await runWithExecutable('dartograph.checkImpact', 42);
  assert.deepStrictEqual(notices, []);
  assert.strictEqual(outputLines.length, 1, outputLines);

  // 경로 구분자 없는 이름은 PATH에서 찾는다. 패키지 루트의 같은 이름 파일이
  // 아니다.
  const record = path.join(scratch, 'record-path.json');
  const bin = path.join(scratch, 'bin');
  writeScript(path.join(bin, 'dartograph'), fakeCliSource(record, 0));
  writeScript(path.join(root, 'dartograph'), markerCliSource(marker));
  const searchPath = `${bin}${path.delimiter}${process.env.PATH}`;
  await withEnvironment('PATH', searchPath, () =>
    runWithExecutable('dartograph.checkImpact', 'dartograph'),
  );
  assert.deepStrictEqual(notices.filter(([kind]) => kind === 'error'), []);
  assert.strictEqual(fs.existsSync(record), true, outputLines.join('\n'));
  assert.strictEqual(fs.existsSync(marker), false, 'the planted script ran');

  // 확장은 설정값이 아니라 해석기가 고른 명령을 실행한다 — Windows에서 PATH로
  // 찾은 절대 경로가 그 명령이다. 설정값 그대로라면 이 이름은 PATH에 없다.
  fs.rmSync(record);
  resolveOverride = () => ({ command: path.join(bin, 'dartograph') });
  try {
    await runWithExecutable('dartograph.checkImpact', 'dartograph-elsewhere');
  } finally {
    resolveOverride = null;
  }
  assert.deepStrictEqual(notices.filter(([kind]) => kind === 'error'), []);
  assert.strictEqual(fs.existsSync(record), true, outputLines.join('\n'));

  // 받을 수 있는 값으로 실행한 뒤 다시 거부되면 알림이 다시 뜬다.
  await runWithExecutable('dartograph.checkImpact', 42);
  assert.deepStrictEqual(notices.map(([kind]) => kind), ['error']);
}

/// [directory]를 TMPDIR로 두고 [run]을 실행한 뒤 원래 값을 되돌린다.
function withTemporaryDirectory(directory, run) {
  return withEnvironment('TMPDIR', directory, run);
}

/// 환경 변수 [name]을 [value]로 두고 [run]을 실행한 뒤 원래 값을 되돌린다.
async function withEnvironment(name, value, run) {
  const original = process.env[name];
  process.env[name] = value;
  try {
    return await run();
  } finally {
    if (original === undefined) {
      delete process.env[name];
    } else {
      process.env[name] = original;
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
