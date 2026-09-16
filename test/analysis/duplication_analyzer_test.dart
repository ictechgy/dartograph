import 'package:dartograph/src/analysis/duplication_analyzer.dart';
import 'package:dartograph/src/core/token_segment.dart';
import 'package:test/test.dart';

void main() {
  /// 토큰 수와 시작 행으로 정규화 세그먼트를 만든다. 코드 값은 해시 버킷이라
  /// 임의 정수열이 그대로 입력이 된다.
  TokenSegment segment(String source, List<int> codes, {int startLine = 1}) =>
      TokenSegment(
        source: source,
        codes: codes,
        lines: [for (var i = 0; i < codes.length; i++) startLine + i],
      );

  test('identical token runs in two files merge into one extended block', () {
    // 두 파일 모두 [1..10] 고유 + [100..120] 공통 + 꼬리 고유 열을 가진다.
    final report = DuplicationAnalyzer().analyze([
      segment('project:lib/a.dart', [
        for (var i = 1; i <= 10; i++) i,
        ...[for (var i = 100; i <= 120; i++) i],
        900,
      ]),
      segment('project:lib/b.dart', [
        for (var i = 50; i <= 60; i++) i,
        ...[for (var i = 100; i <= 120; i++) i],
        901,
      ]),
    ], minTokens: 10);

    expect(report.findings, hasLength(1));
    final finding = report.findings.single;
    // 21개 공통 토큰이 윈도 10 경계 너머까지 확장된다.
    expect(finding.tokenCount, 21);
    expect(finding.instances.map((instance) => instance.source), [
      'project:lib/a.dart',
      'project:lib/b.dart',
    ]);
    // a는 11번 토큰(행 11)부터, b는 12번 토큰(행 12)부터 21토큰이다.
    expect(finding.instances[0].startLine, 11);
    expect(finding.instances[0].endLine, 31);
    expect(finding.instances[1].startLine, 12);
  });

  test('periodic same-segment overlap does not produce findings', () {
    // 같은 값의 짧은 연속 반복은 윈도 거리 < minTokens인 쌍만 만든다 —
    // 자기 겹침 쌍은 발견이 아니다.
    final report = DuplicationAnalyzer().analyze([
      segment('project:lib/a.dart', List.filled(15, 7)),
    ], minTokens: 10);
    expect(report.findings, isEmpty);
  });

  test('same-segment back extension never overlaps the two instances', () {
    // 주기 토큰열 `a b a b a b`: (윈도 2, 윈도 4) 쌍의 뒤쪽 확장이 비겹침
    // 상한을 넘으면 두 인스턴스가 토큰 2·3에서 겹친다 — 보고하면 안 된다.
    final report = DuplicationAnalyzer().analyze([
      segment('project:lib/a.dart', [1, 2, 1, 2, 1, 2]),
    ], minTokens: 2);
    // 공백이 아닌 발견이어야 검사가 헛돌지 않는다.
    expect(report.findings, isNotEmpty);
    for (final finding in report.findings) {
      final first = finding.instances[0];
      final second = finding.instances[1];
      // 두 인스턴스의 토큰 구간(행으로 표현)은 겹치지 않아야 한다.
      expect(
        first.endLine < second.startLine || second.endLine < first.startLine,
        isTrue,
        reason: 'instances overlap: $first vs $second',
      );
    }
  });

  test('back extension up to the boundary still reports adjacent blocks', () {
    // [9,1,2] 블록 두 개가 붙어 있다. (윈도 1, 윈도 4) 쌍은 back=1까지
    // 허용돼 [0..3)·[3..6)의 인접 블록을 만든다 — 상한이 확장을 과도하게
    // 막으면 이 발견이 사라진다.
    final report = DuplicationAnalyzer().analyze([
      segment('project:lib/a.dart', [9, 1, 2, 9, 1, 2]),
    ], minTokens: 2);
    expect(report.findings, hasLength(1));
    final finding = report.findings.single;
    expect(finding.tokenCount, 3);
    expect(finding.instances[0].endLine, 3);
    expect(finding.instances[1].startLine, 4);
  });

  test('non-overlapping same-segment repeat is reported once', () {
    // [1..10] 블록이 30 토큰 뒤에 한 번 더 나타난다.
    final report = DuplicationAnalyzer().analyze([
      segment('project:lib/a.dart', [
        for (var i = 1; i <= 10; i++) i,
        for (var i = 50; i < 70; i++) i,
        for (var i = 1; i <= 10; i++) i,
      ]),
    ], minTokens: 8);

    // 공통 구간(10토큰)이 윈도 8로 잡히고 양방향 확장으로 10토큰 블록이 된다.
    expect(report.findings, hasLength(1));
    expect(report.findings.single.tokenCount, 10);
    expect(report.findings.single.instances, hasLength(2));
    expect(report.findings.single.instances.map((i) => i.startLine), [1, 31]);
  });

  test('window hashes over the position cap are skipped with a limitation', () {
    // 같은 윈도가 positionCap+1개 위치에 나타나도록, 다른 세그먼트에
    // 분산된 동일 블록을 만든다(같은 세그먼트 자기 겹침은 아니다).
    final segments = [
      for (var i = 0; i < DuplicationAnalyzer.positionCap + 1; i++)
        segment('project:lib/f$i.dart', List.filled(10, 7)),
    ];
    final report = DuplicationAnalyzer().analyze(segments, minTokens: 10);

    expect(report.findings, isEmpty);
    expect(
      report.limitations.single,
      contains('duplication-window-saturation'),
    );
  });

  test('findings sort by token count then first location', () {
    final long = [for (var i = 1; i <= 20; i++) i];
    final short = [for (var i = 100; i <= 110; i++) i];
    final report = DuplicationAnalyzer().analyze([
      segment('project:lib/z.dart', [...long, ...short]),
      segment('project:lib/y.dart', [...short, ...long]),
    ], minTokens: 10);

    expect(report.findings, hasLength(2));
    expect(report.findings.first.tokenCount, 20);
    expect(report.findings.last.tokenCount, 11);
  });
}
