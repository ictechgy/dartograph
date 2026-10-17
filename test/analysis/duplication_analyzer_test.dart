import 'dart:convert';
import 'dart:math';

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

  test('three-way duplicates break ties on the second instance', () {
    // 같은 블록이 세 파일에 있으면 [f,g]·[f,h]는 첫 인스턴스가 같다 —
    // 둘째 인스턴스까지 비교해 실행과 무관한 순서를 보장해야 한다.
    final block = [for (var i = 1; i <= 12; i++) i];
    final report = DuplicationAnalyzer().analyze([
      segment('project:lib/f.dart', block),
      segment('project:lib/h.dart', block),
      segment('project:lib/g.dart', block),
    ], minTokens: 10);

    expect(report.findings, hasLength(3));
    expect(
      report.findings
          .map((finding) => finding.instances.map((i) => i.source).toList())
          .toList(),
      [
        ['project:lib/f.dart', 'project:lib/g.dart'],
        ['project:lib/f.dart', 'project:lib/h.dart'],
        ['project:lib/g.dart', 'project:lib/h.dart'],
      ],
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

  test('random inputs match the legacy implementation byte for byte', () {
    // 창 위치 표현을 바꿔도 발견·순서·포화 한계는 그대로여야 한다. 작은
    // 알파벳의 주기 열, 같은 세그먼트 반복, 붙은 사본(겹침 경계), 포화
    // 버킷 바로 뒤의 공통 블록을 섞어 기존 구현(오라클)과 바이트로 비교한다.
    final random = Random(20261018);
    for (var trial = 0; trial < 800; trial++) {
      final minTokens = 2 + random.nextInt(8);
      final segments = _randomSegments(random, minTokens: minTokens);
      final report = DuplicationAnalyzer().analyze(
        segments,
        minTokens: minTokens,
      );
      final expected = _legacyAnalyze(segments, minTokens: minTokens);
      expect(
        jsonEncode([for (final finding in report.findings) finding.toJson()]),
        jsonEncode(expected.findings),
        reason: 'trial $trial (minTokens $minTokens)',
      );
      expect(report.limitations, expected.limitations, reason: 'trial $trial');
    }
  });
}

/// 차등 테스트 입력이다. 파일마다 세그먼트 여러 개가 행을 이어 가며(실제
/// 최상위 선언처럼) 한 행에 토큰 여러 개를 둔다 — 시작 행이 같은 동점 발견이
/// 생겨야 정렬 전순서까지 비교된다.
List<TokenSegment> _randomSegments(Random random, {required int minTokens}) {
  final alphabet = 1 + random.nextInt(4);
  List<int> noise(int length) => [
    for (var i = 0; i < length; i++) random.nextInt(alphabet),
  ];
  final shared = noise(4 + random.nextInt(37));
  // 포화 버킷: 상수 창이 두 세그먼트에 걸쳐 positionCap을 넘게 나오고, 그
  // 바로 뒤에 공통 블록이 온다 — 앞 창 쌍이 열거되지 않는 경계다.
  final saturating = random.nextInt(6) == 0
      ? [
          ...List.filled(
            DuplicationAnalyzer.positionCap ~/ 2 + minTokens + 4,
            99,
          ),
          ...shared,
        ]
      : const <int>[];
  final segments = <TokenSegment>[];
  for (var file = 0; file < 1 + random.nextInt(3); file++) {
    var line = 1;
    for (
      var declaration = 0;
      declaration < 1 + random.nextInt(3);
      declaration++
    ) {
      final codes = <int>[if (segments.length < 2) ...saturating];
      for (var part = 0; part < 1 + random.nextInt(4); part++) {
        if (random.nextBool()) codes.addAll(shared);
        codes.addAll(noise(random.nextInt(16)));
      }
      final lines = <int>[];
      for (var i = 0; i < codes.length; i++) {
        lines.add(line);
        if (random.nextInt(3) == 0) line++;
      }
      line++;
      segments.add(
        TokenSegment(
          source: 'project:lib/f$file.dart',
          codes: codes,
          lines: lines,
        ),
      );
    }
  }
  return segments;
}

/// 오라클의 인스턴스 값이다(제품 타입을 쓰지 않는다).
typedef _LegacyInstance = ({String source, int startLine, int endLine});

/// 오라클의 발견 값이다.
typedef _LegacyFinding = ({int tokenCount, List<_LegacyInstance> instances});

/// 창마다 레코드를 만들어 해시별 맵에 모으던 기존 `analyze`를 그대로 옮긴
/// 오라클이다. 발견은 제품 `toJson`과 같은 키 순서의 JSON 값으로 돌려준다.
({List<Map<String, Object>> findings, List<String> limitations}) _legacyAnalyze(
  List<TokenSegment> segments, {
  required int minTokens,
}) {
  final windows = <List<int>>[];
  final positions = <int, List<({int index, int segment})>>{};
  for (var s = 0; s < segments.length; s++) {
    final codes = segments[s].codes;
    final count = codes.length - minTokens + 1;
    final hashes = count <= 0
        ? const <int>[]
        : _legacyRollingHashes(codes, minTokens);
    windows.add(hashes);
    for (var i = 0; i < hashes.length; i++) {
      positions.putIfAbsent(hashes[i], () => []).add((segment: s, index: i));
    }
  }
  var saturated = 0;
  final seen = <String>{};
  final findings = <_LegacyFinding>[];
  for (final hash in positions.keys.toList()..sort()) {
    final hits = positions[hash]!;
    if (hits.length < 2) continue;
    if (hits.length > DuplicationAnalyzer.positionCap) {
      saturated++;
      continue;
    }
    for (var a = 0; a < hits.length; a++) {
      for (var b = a + 1; b < hits.length; b++) {
        final pa = hits[a];
        final pb = hits[b];
        final sameSegment = pa.segment == pb.segment;
        if (sameSegment && pb.index - pa.index < minTokens) continue;
        final aHashes = windows[pa.segment];
        final bHashes = windows[pb.segment];
        var backLimit = pa.index < pb.index ? pa.index : pb.index;
        if (sameSegment) {
          final noOverlap = pb.index - pa.index - minTokens;
          if (noOverlap < backLimit) backLimit = noOverlap;
        }
        var back = 0;
        while (back < backLimit &&
            aHashes[pa.index - back - 1] == bHashes[pb.index - back - 1]) {
          back++;
        }
        var forwardLimit = aHashes.length - pa.index - 1;
        final bForward = bHashes.length - pb.index - 1;
        if (bForward < forwardLimit) forwardLimit = bForward;
        if (sameSegment) {
          final noOverlap = pb.index - pa.index - minTokens - back;
          if (noOverlap < forwardLimit) forwardLimit = noOverlap;
        }
        if (forwardLimit < 0) forwardLimit = 0;
        var forward = 0;
        while (forward < forwardLimit &&
            aHashes[pa.index + forward + 1] ==
                bHashes[pb.index + forward + 1]) {
          forward++;
        }
        final startA = pa.index - back;
        final startB = pb.index - back;
        final windowCount = back + forward + 1;
        final signature =
            '${pa.segment}:$startA:${pb.segment}:$startB:'
            '$windowCount';
        if (!seen.add(signature)) continue;
        final tokenCount = windowCount + minTokens - 1;
        findings.add((
          tokenCount: tokenCount,
          instances: [
            _legacyInstance(segments[pa.segment], startA, tokenCount),
            _legacyInstance(segments[pb.segment], startB, tokenCount),
          ]..sort(_legacyInstanceOrder),
        ));
      }
    }
  }
  findings.sort((a, b) {
    final order = b.tokenCount.compareTo(a.tokenCount);
    if (order != 0) return order;
    final first = _legacyInstanceOrder(a.instances.first, b.instances.first);
    if (first != 0) return first;
    return _legacyInstanceOrder(a.instances.last, b.instances.last);
  });
  return (
    findings: [
      for (final finding in findings)
        {
          'instances': [
            for (final instance in finding.instances)
              {
                'endLine': instance.endLine,
                'source': instance.source,
                'startLine': instance.startLine,
              },
          ],
          'kind': 'duplicate-block',
          'tokenCount': finding.tokenCount,
        },
    ],
    limitations: [
      if (saturated > 0)
        'duplication-window-saturation: $saturated repetitive window hash(es) '
            'exceeded the position cap and were skipped',
    ],
  );
}

/// 기존 구현의 인스턴스 순서(소스·시작 행)다.
int _legacyInstanceOrder(_LegacyInstance a, _LegacyInstance b) {
  final order = a.source.compareTo(b.source);
  return order != 0 ? order : a.startLine.compareTo(b.startLine);
}

/// 기존 구현의 인스턴스 위치 계산이다.
_LegacyInstance _legacyInstance(
  TokenSegment segment,
  int start,
  int tokenCount,
) => (
  source: segment.source,
  startLine: segment.lines[start],
  endLine: segment.lines[start + tokenCount - 1],
);

/// 기존 구현의 롤링 창 해시다(63bit 마스크).
List<int> _legacyRollingHashes(List<int> codes, int length) {
  const mask = 0x7fffffffffffffff;
  const base = 0x100000001b3;
  var highFactor = 1;
  for (var i = 1; i < length; i++) {
    highFactor = (highFactor * base) & mask;
  }
  var hash = 0;
  for (var i = 0; i < length; i++) {
    hash = (hash * base + codes[i]) & mask;
  }
  final count = codes.length - length + 1;
  final hashes = List<int>.filled(count, 0);
  hashes[0] = hash;
  for (var i = 1; i < count; i++) {
    hash =
        ((hash - codes[i - 1] * highFactor) * base + codes[i + length - 1]) &
        mask;
    hashes[i] = hash;
  }
  return hashes;
}
