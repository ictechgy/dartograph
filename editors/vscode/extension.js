// dartograph 확장은 설치된 CLI를 호출해 JSON 보고를 Problems 진단으로 옮긴다.
// 빌드 단계와 런타임 의존성을 두지 않아 저장소의 Dart 도구와 독립적으로 동작한다.
'use strict';

const vscode = require('vscode');
const { execFile } = require('child_process');
const path = require('path');
const mapper = require('./mapper');

const SAVE_DELAY_MS = 1500;

const SEVERITY = {
  warning: () => vscode.DiagnosticSeverity.Warning,
  information: () => vscode.DiagnosticSeverity.Information,
  hint: () => vscode.DiagnosticSeverity.Hint,
};

let diagnostics;
let output;
let saveTimer;
let running = false;
let reportedMissing = false;

function activate(context) {
  diagnostics = vscode.languages.createDiagnosticCollection('dartograph');
  output = vscode.window.createOutputChannel('dartograph');
  context.subscriptions.push(
    diagnostics,
    output,
    vscode.commands.registerCommand('dartograph.analyzeWorkspace', () =>
      runWorkspaceAnalysis(),
    ),
    vscode.commands.registerCommand('dartograph.checkImpact', () =>
      runImpactCheck(),
    ),
    vscode.commands.registerCommand('dartograph.clearFindings', () =>
      diagnostics.clear(),
    ),
    vscode.workspace.onDidSaveTextDocument((document) => {
      if (document.languageId !== 'dart' || !config().runOnSave) return;
      clearTimeout(saveTimer);
      saveTimer = setTimeout(runWorkspaceAnalysis, SAVE_DELAY_MS);
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
    args: section.get('args', []),
  };
}

/// pubspec.yaml을 가진 워크스페이스 폴더만 분석 대상으로 본다.
async function packageRoots() {
  const folders = vscode.workspace.workspaceFolders || [];
  const roots = [];
  for (const folder of folders) {
    const manifest = vscode.Uri.joinPath(folder.uri, 'pubspec.yaml');
    try {
      await vscode.workspace.fs.stat(manifest);
      roots.push(folder);
    } catch {
      // pubspec.yaml이 없는 폴더는 Dart 패키지가 아니므로 건너뛴다.
    }
  }
  return roots;
}

/// dead·deps·dup를 실행해 결과를 Problems에 반영한다.
async function runWorkspaceAnalysis() {
  if (running) return;
  const roots = await packageRoots();
  if (roots.length === 0) {
    vscode.window.showInformationMessage(
      'dartograph: no workspace folder contains pubspec.yaml',
    );
    return;
  }
  running = true;
  const collected = new Map();
  try {
    for (const folder of roots) {
      for (const report of await runReports(folder)) {
        logLimitations(report);
        for (const item of mapper.mapReport(report)) {
          collect(collected, folder, item);
        }
      }
    }
    publish(collected);
    vscode.window.setStatusBarMessage(
      `dartograph: analysis complete (${totalFindings(collected)} finding(s))`,
      5000,
    );
  } finally {
    running = false;
  }
}

/// 세 검사를 순차 실행한다. 한 명령이 분석 실패로 끝나도 나머지 결과를 살린다.
async function runReports(folder) {
  const cwd = folder.uri.fsPath;
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
async function runImpactCheck() {
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
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    vscode.window.showInformationMessage(
      'dartograph: file is outside the package root',
    );
    return;
  }
  const report = await runJson(
    'impact',
    [
      'impact',
      '--changed',
      JSON.stringify([relative]),
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
    collect(collected, folder, item);
  }
  publish(collected);
  vscode.window.setStatusBarMessage(
    `dartograph: ${(report.impacted || []).length} impacted symbol(s), ` +
      `${(report.tests || []).length} related test(s)`,
    5000,
  );
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
          if (!reportedMissing) {
            reportedMissing = true;
            vscode.window.showErrorMessage(
              `dartograph: '${executable}' not found — ` +
                'run `dart pub global activate dartograph`',
            );
          }
          return resolve(null);
        }
        const exitCode = error ? error.code : 0;
        if (typeof exitCode === 'number' && exitCode !== 0 && exitCode !== 1) {
          output.appendLine(
            `[${name}] exit ${exitCode}: ${String(stderr).trim()}`,
          );
          vscode.window.showErrorMessage(
            `dartograph ${name} failed (exit ${exitCode}) — see output`,
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
function collect(collected, folder, item) {
  const uri = vscode.Uri.joinPath(folder.uri, ...item.file.split('/'));
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

function totalFindings(collected) {
  let count = 0;
  for (const { items } of collected.values()) count += items.length;
  return count;
}

module.exports = { activate, deactivate };
