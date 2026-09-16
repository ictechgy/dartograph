// mapper의 보고서→진단 변환을 검증한다. vscode 없이 `node`로 실행한다.
'use strict';

const assert = require('assert');
const {
  mapReport,
  mapImpact,
  stripScheme,
  safeRelative,
  pointRange,
  lineRange,
} = require('../mapper');

// stripScheme: project: 접두를 벗기고 다른 스킴은 null이다.
assert.strictEqual(stripScheme('project:lib/a.dart'), 'lib/a.dart');
assert.strictEqual(stripScheme('lib/a.dart'), 'lib/a.dart');
assert.strictEqual(stripScheme('package:other/x.dart'), null);
assert.strictEqual(stripScheme(''), null);
assert.strictEqual(stripScheme(null), null);

// pointRange: 1-based 입력을 0-based로 바꾸고 누락 값은 1행 1열로 본다.
assert.deepStrictEqual(pointRange(3, 5), {
  startLine: 2,
  startCol: 4,
  endLine: 2,
  endCol: 20,
});
assert.deepStrictEqual(pointRange(undefined, undefined).startLine, 0);

// lineRange: 행 범위를 0-based로 바꾸고 뒤집힌 범위는 시작점으로 묶는다.
assert.deepStrictEqual(lineRange(2, 5), {
  startLine: 1,
  startCol: 0,
  endLine: 4,
  endCol: Number.MAX_SAFE_INTEGER,
});
assert.strictEqual(lineRange(5, 2).endLine, 4);

// safeRelative: 루트 밖 경로(절대·드라이브·..)를 거부한다.
assert.strictEqual(safeRelative('lib/a.dart'), 'lib/a.dart');
assert.strictEqual(safeRelative('../outside.dart'), null);
assert.strictEqual(safeRelative('a/../../b.dart'), null);
assert.strictEqual(safeRelative('/etc/x.dart'), null);
assert.strictEqual(safeRelative('C:/x.dart'), null);

// dead 발견: source·line·column이 진단 위치가 되고 reason이 메시지다.
const deadItems = mapReport({
  report: 'dead',
  findings: [
    {
      kind: 'declaration',
      source: 'project:lib/unused.dart',
      line: 4,
      column: 7,
      reason: 'not reachable from retained roots',
    },
    { kind: 'file', source: null, reason: 'no source' },
    {
      kind: 'declaration',
      source: 'package:dep/x.dart',
      reason: 'outside package root',
    },
    {
      kind: 'file',
      source: 'project:../outside.dart',
      reason: 'traversal attempt',
    },
  ],
});
assert.strictEqual(deadItems.length, 1);
assert.strictEqual(deadItems[0].file, 'lib/unused.dart');
assert.strictEqual(deadItems[0].severity, 'warning');
assert.strictEqual(deadItems[0].range.startLine, 3);
assert.strictEqual(deadItems[0].range.startCol, 6);
assert.ok(deadItems[0].message.includes('not reachable'));

// deps 발견: 위치 정보가 없으므로 pubspec.yaml 첫 줄에 단다.
const depsItems = mapReport({
  report: 'deps',
  findings: [
    { kind: 'undeclared-import', name: 'http', reason: 'imported but not declared' },
  ],
});
assert.strictEqual(depsItems.length, 1);
assert.strictEqual(depsItems[0].file, 'pubspec.yaml');
assert.ok(depsItems[0].message.includes("'http'"));

// dup 발견: 양쪽 인스턴스 위치에 진단을 달고 상대 위치를 메시지에 넣는다.
const dupItems = mapReport({
  report: 'dup',
  findings: [
    {
      tokenCount: 77,
      instances: [
        { source: 'project:lib/a.dart', startLine: 3, endLine: 20 },
        { source: 'project:lib/b.dart', startLine: 8, endLine: 25 },
      ],
    },
  ],
});
assert.strictEqual(dupItems.length, 2);
assert.strictEqual(dupItems[0].file, 'lib/a.dart');
assert.strictEqual(dupItems[0].severity, 'information');
assert.ok(dupItems[0].message.includes('lib/b.dart:8'));
assert.ok(dupItems[1].message.includes('lib/a.dart:3'));

// dup 인스턴스가 패키지 밖(package:)이면 그 위치는 건너뛴다.
const externalDup = mapReport({
  report: 'dup',
  findings: [
    {
      tokenCount: 50,
      instances: [
        { source: 'project:lib/a.dart', startLine: 1, endLine: 5 },
        { source: 'package:dep/x.dart', startLine: 1, endLine: 5 },
      ],
    },
  ],
});
assert.strictEqual(externalDup.length, 1);
assert.ok(externalDup[0].message.includes('package:dep/x.dart'));

// impact: source 없는 항목은 건너뛰고 risk high는 warning이다.
const impactItems = mapImpact({
  impacted: [
    { source: 'lib/x.dart', line: 2, column: 1, riskLevel: 'high', depth: 1 },
    { source: null, riskLevel: 'low', depth: 2 },
  ],
  tests: [{ source: 'test/x_test.dart', line: 1, column: 1, depth: 1 }],
});
assert.strictEqual(impactItems.length, 2);
assert.strictEqual(impactItems[0].severity, 'warning');
assert.strictEqual(impactItems[1].severity, 'hint');

// 알 수 없는 보고서 타입과 빈 findings는 빈 목록이다.
assert.deepStrictEqual(mapReport({ report: 'unknown', findings: [{}] }), []);
assert.deepStrictEqual(mapReport({}), []);

console.log('mapper.test.js: all assertions passed');
