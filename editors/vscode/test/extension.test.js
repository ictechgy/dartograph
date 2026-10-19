// extension.js의 영향 점검 배선을 VS Code 없이 검증한다. `node`로 실행한다.
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
    onDidSaveTextDocument: () => ({ dispose() {} }),
    getConfiguration: () => ({
      get: (key, fallback) =>
        settings.has(key) ? settings.get(key) : fallback,
    }),
    getWorkspaceFolder: () => editorState.workspaceFolder,
  },
};

const originalLoad = Module._load;
Module._load = function load(request, parent, isMain) {
  if (request === 'vscode') return vscodeStub;
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

/// 가짜 CLI를 [exitCode]로 설정하고 현재 파일 영향 점검을 한 번 실행한다.
/// CLI가 목록을 읽지 못해 기록을 남기지 않았으면 null이다.
async function checkImpact(scratch, exitCode) {
  const record = path.join(scratch, `record-${exitCode}.json`);
  const executable = path.join(scratch, `fake-dartograph-${exitCode}`);
  fs.rmSync(record, { force: true });
  fs.writeFileSync(executable, fakeCliSource(record, exitCode));
  fs.chmodSync(executable, 0o755);
  settings.set('executable', executable);
  notices.length = 0;
  outputLines.length = 0;
  await commands.get('dartograph.checkImpact')();
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
    assert.deepStrictEqual(seen.args, [
      'impact',
      '--changed',
      seen.changed,
      '--format',
      'json',
      '--incremental',
      '.dartograph/cache',
      root,
    ]);
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
    extension.deactivate();
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
  console.log('extension.test.js: all assertions passed');
}

/// [directory]를 TMPDIR로 두고 [run]을 실행한 뒤 원래 값을 되돌린다.
async function withTemporaryDirectory(directory, run) {
  const original = process.env.TMPDIR;
  process.env.TMPDIR = directory;
  try {
    return await run();
  } finally {
    if (original === undefined) {
      delete process.env.TMPDIR;
    } else {
      process.env.TMPDIR = original;
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
