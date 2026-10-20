// dartograph 확장은 설치된 CLI를 호출해 JSON 보고를 Problems 진단으로 옮긴다.
// 빌드 단계와 런타임 의존성을 두지 않아 저장소의 Dart 도구와 독립적으로 동작한다.
'use strict';

const vscode = require('vscode');
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const mapper = require('./mapper');

const SAVE_DELAY_MS = 1500;

// 기본 인자는 package.json의 `dartograph.args` 기본값과 같다. 증분 사실 캐시를
// 작업 공간 밖 사용자 캐시에 둔다 — 작업 공간 안 캐시 디렉터리는 저장소가 위조한
// 사실이나 FIFO 링크를 커밋해 둘 수 있는 자리다.
const DEFAULT_ARGS = ['--incremental-user-cache'];

const SEVERITY = {
  warning: () => vscode.DiagnosticSeverity.Warning,
  information: () => vscode.DiagnosticSeverity.Information,
  hint: () => vscode.DiagnosticSeverity.Hint,
};

let diagnostics;
let impactDiagnostics;
let output;
let saveTimer;
let running = false;
let pendingRerun = false;
let missingExecutable = null;

function activate(context) {
  diagnostics = vscode.languages.createDiagnosticCollection('dartograph');
  impactDiagnostics = vscode.languages.createDiagnosticCollection(
    'dartograph-impact',
  );
  output = vscode.window.createOutputChannel('dartograph');
  context.subscriptions.push(
    diagnostics,
    impactDiagnostics,
    output,
    vscode.commands.registerCommand('dartograph.analyzeWorkspace', () =>
      runWorkspaceAnalysis(),
    ),
    vscode.commands.registerCommand('dartograph.checkImpact', () =>
      runImpactCheck(),
    ),
    vscode.commands.registerCommand('dartograph.clearFindings', () => {
      diagnostics.clear();
      impactDiagnostics.clear();
    }),
    vscode.workspace.onDidSaveTextDocument((document) => {
      if (document.languageId !== 'dart' || !config().runOnSave) return;
      clearTimeout(saveTimer);
      saveTimer = setTimeout(() => {
        // 진행 중인 분석이 끝난 뒤 한 번 다시 돌려 최신 저장을 반영한다.
        if (running) {
          pendingRerun = true;
          return;
        }
        runWorkspaceAnalysis();
      }, SAVE_DELAY_MS);
    }),
  );
}

function deactivate() {
  clearTimeout(saveTimer);
}

/// 현재 설정을 읽는다.
function config() {
  const section = vscode.workspace.getConfiguration('dartograph');
  return {
    executable: section.get('executable', 'dartograph'),
    runOnSave: section.get('runOnSave', false),
    minTokens: section.get('minTokens', 40),
    args: section.get('args', DEFAULT_ARGS),
  };
}

/// pubspec.yaml을 가진 폴더를 분석 대상으로 본다 — 루트와 `packages/*` 하위까지.
async function packageRoots() {
  const folders = vscode.workspace.workspaceFolders || [];
  const roots = [];
  for (const folder of folders) {
    if (await hasManifest(folder.uri)) {
      roots.push(folder.uri);
      continue;
    }
    // 모노레포의 한 수준 하위 패키지도 대상으로 삼는다.
    try {
      const entries = await vscode.workspace.fs.readDirectory(
        vscode.Uri.joinPath(folder.uri, 'packages'),
      );
      for (const [name, kind] of entries) {
        if (kind !== vscode.FileType.Directory) continue;
        const sub = vscode.Uri.joinPath(folder.uri, 'packages', name);
        if (await hasManifest(sub)) roots.push(sub);
      }
    } catch {
      // packages/ 디렉터리가 없으면 건너뛴다.
    }
  }
  return roots;
}

async function hasManifest(uri) {
  try {
    await vscode.workspace.fs.stat(vscode.Uri.joinPath(uri, 'pubspec.yaml'));
    return true;
  } catch {
    return false;
  }
}

/// dead·deps·dup를 실행해 결과를 Problems에 반영한다.
async function runWorkspaceAnalysis() {
  if (running) {
    pendingRerun = true;
    return;
  }
  running = true;
  const collected = new Map();
  try {
    const roots = await packageRoots();
    if (roots.length === 0) {
      vscode.window.showInformationMessage(
        'dartograph: no workspace folder contains pubspec.yaml',
      );
      return;
    }
    let succeeded = 0;
    for (const root of roots) {
      const reports = await runReports(root);
      succeeded += reports.length;
      for (const report of reports) {
        logLimitations(report);
        for (const item of mapper.mapReport(report)) {
          collect(collected, root, item);
        }
      }
    }
    // 모든 명령이 실패한 실행은 성공(0 finding)과 구분해 기존 진단을 보존한다.
    if (succeeded === 0) {
      vscode.window.setStatusBarMessage(
        'dartograph: analysis failed — see output',
        8000,
      );
      return;
    }
    publish(collected);
    vscode.window.setStatusBarMessage(
      `dartograph: analysis complete (${totalFindings(collected)} finding(s))`,
      5000,
    );
  } finally {
    running = false;
    if (pendingRerun) {
      pendingRerun = false;
      runWorkspaceAnalysis();
    }
  }
}

/// 세 검사를 순차 실행한다. 한 명령이 분석 실패로 끝나도 나머지 결과를 살린다.
async function runReports(root) {
  const cwd = root.fsPath;
  const extra = config().args;
  const reports = [];
  const specs = [
    ['dead', ['dead', '--format', 'json', ...extra, cwd]],
    ['deps', ['deps', '--format', 'json', ...extra, cwd]],
    [
      'dup',
      [
        'dup',
        '--format',
        'json',
        '--min-tokens',
        String(config().minTokens),
        ...extra,
        cwd,
      ],
    ],
  ];
  for (const [name, args] of specs) {
    const report = await runJson(name, args, cwd);
    if (report) reports.push(report);
  }
  return reports;
}

/// 현재 편집 파일을 변경본으로 간주해 영향받는 선언을 Problems에 표시한다.
/// 워크스페이스 분석과 컬렉션이 분리돼 서로의 진단을 지우지 않는다.
async function runImpactCheck() {
  if (running) return;
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== 'dart') {
    vscode.window.showInformationMessage(
      'dartograph: open a Dart file to check impact',
    );
    return;
  }
  const folder = vscode.workspace.getWorkspaceFolder(editor.document.uri);
  if (!folder) return;
  const cwd = folder.uri.fsPath;
  const relative = path.relative(cwd, editor.document.uri.fsPath);
  const outside =
    relative === '..' ||
    relative.startsWith('..' + path.sep) ||
    path.isAbsolute(relative);
  if (outside) {
    vscode.window.showInformationMessage(
      'dartograph: file is outside the package root',
    );
    return;
  }
  running = true;
  let changes = null;
  try {
    changes = await writeChangedList(relative.split(path.sep).join('/'));
    if (!changes) return;
    const report = await runJson(
      'impact',
      [
        'impact',
        '--changed',
        changes.file,
        '--format',
        'json',
        ...config().args,
        cwd,
      ],
      cwd,
    );
    if (!report) return;
    const collected = new Map();
    logLimitations(report);
    for (const item of mapper.mapImpact(report)) {
      collect(collected, folder.uri, item);
    }
    publishImpact(collected);
    vscode.window.setStatusBarMessage(
      `dartograph: ${(report.impacted || []).length} impacted symbol(s), ` +
        `${(report.tests || []).length} related test(s)`,
      5000,
    );
  } finally {
    running = false;
    if (changes) await removeChangedList(changes.directory);
  }
}

/// `impact --changed`가 읽을 변경 목록 파일을 OS 임시 디렉터리에 쓴다.
/// CLI는 이 값을 JSON 문자열이 아니라 목록 파일의 경로로 읽는다(생성 훅과 같은
/// 방식). 작업 공간에는 파일을 남기지 않고, 디렉터리는 호출자가 지운다.
/// 쓰지 못하면 원인을 출력 채널에 남기고 null을 돌려준다.
async function writeChangedList(entry) {
  let directory = null;
  try {
    directory = await fs.promises.mkdtemp(
      path.join(os.tmpdir(), 'dartograph-'),
    );
    const file = path.join(directory, 'changes.json');
    await fs.promises.writeFile(file, JSON.stringify([entry]));
    return { directory, file };
  } catch (error) {
    output.appendLine(
      `[impact] failed: could not write the changed list under ` +
        `${os.tmpdir()} — check that it is writable (${error.message})`,
    );
    vscode.window.showErrorMessage('dartograph impact failed — see output');
    if (directory) await removeChangedList(directory);
    return null;
  }
}

/// 임시 변경 목록 디렉터리를 지운다. 지우지 못해도 점검 결과는 그대로 유효하므로
/// 원인만 출력 채널에 남긴다.
async function removeChangedList(directory) {
  try {
    await fs.promises.rm(directory, { recursive: true, force: true });
  } catch (error) {
    output.appendLine(
      `[impact] could not remove the temporary changed list ${directory}: ` +
        error.message,
    );
  }
}

/// 명령을 실행해 stdout의 JSON 문서를 돌려준다. 종료 1(발견)도 정상 결과다.
function runJson(name, args, cwd) {
  const { executable } = config();
  return new Promise((resolve) => {
    execFile(
      executable,
      args,
      { cwd, maxBuffer: 32 * 1024 * 1024 },
      (error, stdout, stderr) => {
        if (error && error.code === 'ENOENT') {
          if (missingExecutable !== executable) {
            missingExecutable = executable;
            vscode.window.showErrorMessage(
              `dartograph: '${executable}' not found — ` +
                'run `dart pub global activate dartograph`',
            );
          }
          return resolve(null);
        }
        // 숫자 0/1은 정상(1은 발견), 그 밖의 오류(2·64·문자열 코드·signal)를 여기서 잡는다.
        const ok =
          !error ||
          (typeof error.code === 'number' &&
            (error.code === 0 || error.code === 1));
        if (!ok) {
          const detail = String(stderr).trim() || error.message;
          output.appendLine(`[${name}] failed: ${detail}`);
          vscode.window.showErrorMessage(
            `dartograph ${name} failed — see output`,
          );
          return resolve(null);
        }
        try {
          resolve(JSON.parse(stdout));
        } catch (parseError) {
          output.appendLine(
            `[${name}] invalid JSON: ${parseError.message}\n${stdout}`,
          );
          resolve(null);
        }
      },
    );
  });
}

/// 진단 레코드를 파일별 목록에 추가한다.
function collect(collected, root, item) {
  const uri = vscode.Uri.joinPath(root, ...item.file.split('/'));
  const key = uri.toString();
  if (!collected.has(key)) collected.set(key, { uri, items: [] });
  const range = new vscode.Range(
    item.range.startLine,
    item.range.startCol,
    item.range.endLine,
    item.range.endCol,
  );
  const diagnostic = new vscode.Diagnostic(
    range,
    item.message,
    (SEVERITY[item.severity] || SEVERITY.information)(),
  );
  diagnostic.source = 'dartograph';
  collected.get(key).items.push(diagnostic);
}

/// 보고서의 한계 목록을 출력 채널에 남긴다 — 발견 부재를 안전 증명으로 읽지 않게 한다.
function logLimitations(report) {
  for (const limitation of report.limitations || []) {
    output.appendLine(`[${report.report}] limitation: ${limitation}`);
  }
}

/// 수집된 진단을 Problems에 반영한다.
function publish(collected) {
  diagnostics.clear();
  for (const { uri, items } of collected.values()) {
    diagnostics.set(uri, items);
  }
}

/// impact 진단은 별도 컬렉션이므로 워크스페이스 분석 결과를 지우지 않는다.
function publishImpact(collected) {
  impactDiagnostics.clear();
  for (const { uri, items } of collected.values()) {
    impactDiagnostics.set(uri, items);
  }
}

function totalFindings(collected) {
  let count = 0;
  for (const { items } of collected.values()) count += items.length;
  return count;
}

module.exports = { activate, deactivate };
