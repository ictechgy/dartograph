// 보고서 JSON을 에디터 독립적인 진단 레코드로 변환한다.
// vscode API에 의존하지 않아 `node test/`로 단위 검증할 수 있다.
'use strict';

const SOURCE_PREFIX = 'project:';

/// `project:` 스킴을 벗긴다. 다른 스킴은 패키지 밖 위치이므로 null이다.
function stripScheme(source) {
  if (!source) return null;
  if (source.startsWith(SOURCE_PREFIX)) {
    return source.slice(SOURCE_PREFIX.length);
  }
  return source.includes(':') ? null : source;
}

/// 알려진 행·열에서 시작하는 0-based 범위를 만든다(보고서는 1-based).
function pointRange(line, column) {
  const row = Math.max(0, (line || 1) - 1);
  const col = Math.max(0, (column || 1) - 1);
  return { startLine: row, startCol: col, endLine: row, endCol: col + 16 };
}

/// 1-based 행 범위를 0-based 진단 범위로 변환한다.
function lineRange(startLine, endLine) {
  return {
    startLine: Math.max(0, startLine - 1),
    startCol: 0,
    endLine: Math.max(0, endLine - 1),
    endCol: Number.MAX_SAFE_INTEGER,
  };
}

/// 한 보고서의 발견을 진단 레코드 목록으로 변환한다.
function mapReport(report) {
  const items = [];
  for (const finding of report.findings || []) {
    switch (report.report) {
      case 'dead': {
        const file = stripScheme(finding.source);
        if (!file) break;
        items.push({
          file,
          range: pointRange(finding.line, finding.column),
          message: `${finding.kind}: ${finding.reason}`,
          severity: 'warning',
        });
        break;
      }
      case 'deps':
        items.push({
          file: 'pubspec.yaml',
          range: pointRange(1, 1),
          message: `${finding.kind}: '${finding.name}' — ${finding.reason}`,
          severity: 'warning',
        });
        break;
      case 'dup':
        for (const instance of finding.instances || []) {
          const file = stripScheme(instance.source);
          if (!file) continue;
          const other = (finding.instances || []).find(
            (peer) => peer !== instance,
          );
          const otherPath = other
            ? stripScheme(other.source) || other.source
            : null;
          const elsewhere = other
            ? ` — also at ${otherPath}:${other.startLine}`
            : '';
          items.push({
            file,
            range: lineRange(instance.startLine, instance.endLine),
            message:
              `duplicate block (${finding.tokenCount} tokens)` + elsewhere,
            severity: 'information',
          });
        }
        break;
      default:
        break;
    }
  }
  return items;
}

/// 영향 보고서의 impacted/tests 항목을 진단 레코드로 변환한다.
function mapImpact(report) {
  const items = [];
  for (const item of report.impacted || []) {
    const impactedFile = stripScheme(item.source);
    if (!impactedFile) continue;
    items.push({
      file: impactedFile,
      range: pointRange(item.line, item.column),
      message:
        `impacted by change (risk: ${item.riskLevel}, depth: ${item.depth})`,
      severity: item.riskLevel === 'high' ? 'warning' : 'information',
    });
  }
  for (const item of report.tests || []) {
    const testFile = stripScheme(item.source);
    if (!testFile) continue;
    items.push({
      file: testFile,
      range: pointRange(item.line, item.column),
      message: `related test (depth: ${item.depth})`,
      severity: 'hint',
    });
  }
  return items;
}

module.exports = { mapReport, mapImpact, stripScheme, pointRange, lineRange };
