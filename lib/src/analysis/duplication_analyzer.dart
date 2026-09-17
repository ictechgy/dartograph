import '../core/token_segment.dart';

/// 중복 토큰 블록 한 인스턴스의 위치다.
final class DuplicateInstance {
  /// 소스 ID와 1-based 행 범위로 위치를 만든다.
  const DuplicateInstance({
    required this.source,
    required this.startLine,
    required this.endLine,
  });

  /// `project:` source ID다.
  final String source;

  /// 블록 첫 토큰이 시작되는 행이다.
  final int startLine;

  /// 블록 마지막 토큰이 시작되는 행이다.
  final int endLine;

  /// 결정적인 리포트 값으로 변환한다.
  Map<String, Object> toJson() => {
    'endLine': endLine,
    'source': source,
    'startLine': startLine,
  };
}

/// 같은 정규화 토큰 열이 두 위치에서 반복되는 검토 후보다.
///
/// 찾은 것은 "같은 토큰 구조"이지 "리팩터링해야 할 코드"의 판정이 아니다 —
/// 위치 쌍과 길이를 근거로보내고 삭제·병합 지시는 하지 않는다.
final class DuplicationFinding {
  /// 발견을 만든다. [instances]는 두 위치로, 보고 전에 정렬된다.
  const DuplicationFinding({required this.tokenCount, required this.instances});

  /// 발견 종류다. `--kinds` 필터가 다른 명령과 같은 필드를 본다.
  String get kind => 'duplicate-block';

  /// 겹치지 않게 확장된 공통 토큰 수다(윈도 크기 이상).
  final int tokenCount;

  /// 블록이 반복되는 두 위치다(소스·행 오름차순).
  final List<DuplicateInstance> instances;

  /// 결정적인 리포트 값으로 변환한다.
  Map<String, Object> toJson() => {
    'instances': [for (final instance in instances) instance.toJson()],
    'kind': 'duplicate-block',
    'tokenCount': tokenCount,
  };
}

/// 탐지 결과와 한계다.
final class DuplicationReport {
  /// 발견 목록과 관측 한계를 담는다.
  const DuplicationReport(this.findings, this.limitations);

  /// `duplicate-block` 발견이다(토큰 수 내림·위치 오름차순).
  final List<DuplicationFinding> findings;

  /// 이번 탐지가 관측한 한계다.
  final List<String> limitations;
}

/// 정규화 토큰 세그먼트에서 긴 반복 블록을 찾는다.
final class DuplicationAnalyzer {
  /// 한 윈도 해시가 이만큼의 위치를 넘으면 보일러플레이트로 보고 건너뛴다.
  ///
  /// 쌍 열거가 제곱으로 불어나는 것을 막는 상한이다. 초과분은 한계로 기록한다.
  static const positionCap = 256;

  /// 각 세그먼트에서 [minTokens] 길이 윈도를 해시해, 같은 해시를 공유하는
  /// 위치 쌍을 양방향으로 확장해 최대 공통 블록을 만든다.
  ///
  /// 한 세그먼트 안의 자기 반복은 윈도가 서로 겹치지 않는 쌍(거리 ≥
  /// [minTokens])만 비교해 주기적 토큰의 자기 포화를 걸러낸다. 서로 다른
  /// 세그먼트의 쌍은 항상 비교한다. 세 위치 이상의 반복은 위치 쌍별 발견으로
  /// 남는다 — 합쳐진 하나의 발견으로 만들지 않는다.
  DuplicationReport analyze(
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
          : List<int>.generate(
              count,
              (i) => _windowHash(codes, i, minTokens),
              growable: false,
            );
      windows.add(hashes);
      for (var i = 0; i < hashes.length; i++) {
        positions.putIfAbsent(hashes[i], () => []).add((segment: s, index: i));
      }
    }
    var saturated = 0;
    final seen = <String>{};
    final findings = <DuplicationFinding>[];
    for (final hash in positions.keys.toList()..sort()) {
      final hits = positions[hash]!;
      if (hits.length < 2) continue;
      if (hits.length > positionCap) {
        saturated++;
        continue;
      }
      for (var a = 0; a < hits.length; a++) {
        for (var b = a + 1; b < hits.length; b++) {
          final pa = hits[a];
          final pb = hits[b];
          final sameSegment = pa.segment == pb.segment;
          // 같은 세그먼트의 겹치는 윈도 쌍은 같은 텍스트의 자기 반복이다.
          if (sameSegment && pb.index - pa.index < minTokens) continue;
          final aHashes = windows[pa.segment];
          final bHashes = windows[pb.segment];
          // 뒤쪽 확장도 비겹침 상한을 지킨다 — 같은 세그먼트에서
          // back > 거리 - minTokens이면 두 블록이 토큰에서 겹친다.
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
          // 같은 세그먼트의 앞쪽 확장은 두 블록이 토큰에서 겹치지 않게 제한한다.
          // 겹침은 windowCount > d - minTokens + 1일 때 생기므로
          // forward ≤ 거리 - minTokens - back이어야 한다.
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
          findings.add(
            DuplicationFinding(
              tokenCount: tokenCount,
              instances: [
                _instance(segments[pa.segment], startA, tokenCount),
                _instance(segments[pb.segment], startB, tokenCount),
              ]..sort(_instanceOrder),
            ),
          );
        }
      }
    }
    findings.sort((a, b) {
      final order = b.tokenCount.compareTo(a.tokenCount);
      if (order != 0) return order;
      // 위치 쌍별 발견은 첫 인스턴스가 같을 수 있다([P,Q]·[P,R]) — 둘째까지
      // 비교해 전순서를 만들어 List.sort의 비안정성이 출력에 새지 않게 한다.
      final first = _instanceOrder(a.instances.first, b.instances.first);
      if (first != 0) return first;
      return _instanceOrder(a.instances.last, b.instances.last);
    });
    return DuplicationReport(findings, [
      if (saturated > 0)
        'duplication-window-saturation: $saturated repetitive window hash(es) '
            'exceeded the position cap and were skipped',
    ]);
  }

  static int _instanceOrder(DuplicateInstance a, DuplicateInstance b) {
    final order = a.source.compareTo(b.source);
    return order != 0 ? order : a.startLine.compareTo(b.startLine);
  }

  static DuplicateInstance _instance(
    TokenSegment segment,
    int start,
    int tokenCount,
  ) => DuplicateInstance(
    source: segment.source,
    startLine: segment.lines[start],
    endLine: segment.lines[start + tokenCount - 1],
  );

  /// 윈도의 결정적 FNV-1a 해시다(63bit). 토큰 코드는 이미 균일한 해시라
  /// 코드 하나당 한 번의 곱셈으로 섞는다.
  static int _windowHash(List<int> codes, int start, int length) {
    var hash = 0xcbf29ce484222325;
    for (var i = start; i < start + length; i++) {
      hash ^= codes[i];
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash;
  }
}
