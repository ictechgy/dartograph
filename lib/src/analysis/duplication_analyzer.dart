import 'dart:typed_data';

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
    final windows = <Int64List>[];
    for (var s = 0; s < segments.length; s++) {
      final codes = segments[s].codes;
      final count = codes.length - minTokens + 1;
      windows.add(count <= 0 ? _noWindows : _rollingHashes(codes, minTokens));
    }
    final (:offsets, :positions, :saturated) = _windowGroups(windows);
    final seen = <String>{};
    final findings = <DuplicationFinding>[];
    for (var group = 0; group + 1 < offsets.length; group++) {
      final end = offsets[group + 1];
      for (var a = offsets[group]; a < end; a++) {
        final segmentA = positions[a] >> 32;
        final indexA = positions[a] & _indexMask;
        for (var b = a + 1; b < end; b++) {
          final segmentB = positions[b] >> 32;
          final indexB = positions[b] & _indexMask;
          final sameSegment = segmentA == segmentB;
          // 같은 세그먼트의 겹치는 윈도 쌍은 같은 텍스트의 자기 반복이다.
          if (sameSegment && indexB - indexA < minTokens) continue;
          final aHashes = windows[segmentA];
          final bHashes = windows[segmentB];
          // 뒤쪽 확장도 비겹침 상한을 지킨다 — 같은 세그먼트에서
          // back > 거리 - minTokens이면 두 블록이 토큰에서 겹친다.
          var backLimit = indexA < indexB ? indexA : indexB;
          if (sameSegment) {
            final noOverlap = indexB - indexA - minTokens;
            if (noOverlap < backLimit) backLimit = noOverlap;
          }
          var back = 0;
          while (back < backLimit &&
              aHashes[indexA - back - 1] == bHashes[indexB - back - 1]) {
            back++;
          }
          // 같은 세그먼트의 앞쪽 확장은 두 블록이 토큰에서 겹치지 않게 제한한다.
          // 겹침은 windowCount > d - minTokens + 1일 때 생기므로
          // forward ≤ 거리 - minTokens - back이어야 한다.
          var forwardLimit = aHashes.length - indexA - 1;
          final bForward = bHashes.length - indexB - 1;
          if (bForward < forwardLimit) forwardLimit = bForward;
          if (sameSegment) {
            final noOverlap = indexB - indexA - minTokens - back;
            if (noOverlap < forwardLimit) forwardLimit = noOverlap;
          }
          if (forwardLimit < 0) forwardLimit = 0;
          var forward = 0;
          while (forward < forwardLimit &&
              aHashes[indexA + forward + 1] == bHashes[indexB + forward + 1]) {
            forward++;
          }
          final startA = indexA - back;
          final startB = indexB - back;
          final windowCount = back + forward + 1;
          final signature =
              '$segmentA:$startA:$segmentB:$startB:'
              '$windowCount';
          if (!seen.add(signature)) continue;
          final tokenCount = windowCount + minTokens - 1;
          findings.add(
            DuplicationFinding(
              tokenCount: tokenCount,
              instances: [
                _instance(segments[segmentA], startA, tokenCount),
                _instance(segments[segmentB], startB, tokenCount),
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

  /// 창이 없는 세그먼트가 함께 쓰는 빈 해시 열이다.
  static final _noWindows = Int64List(0);

  /// 패킹한 위치 `(세그먼트 << 32) | 인덱스`에서 인덱스를 꺼내는 마스크다.
  static const _indexMask = 0xffffffff;

  /// 쌍을 비교할 창 해시 그룹을 해시 오름차순으로 모은다.
  ///
  /// 그룹 `g`의 위치는 `positions[offsets[g]..offsets[g + 1])`이고 세그먼트·
  /// 인덱스 오름차순이다 — 해시별 맵을 해시 순으로 돌던 순서와 같다. 위치가
  /// 2..[positionCap]개인 해시만 담고, 상한을 넘은 해시는 `saturated`로 센다.
  ///
  /// 창마다 맵 항목·리스트·레코드를 만들면 토큰당 약 160B가 든다. 대부분의
  /// 창 해시는 한 번만 나오므로 정렬한 해시 사본에서 2회 이상인 해시만 고르고
  /// 그 위치만 모은다. 사본 버퍼는 위치 버퍼로 다시 써서 최대 메모리가 창
  /// 해시 두 벌(토큰당 약 16B)을 넘지 않게 한다.
  static ({Int32List offsets, Int64List positions, int saturated})
  _windowGroups(List<Int64List> windows) {
    var total = 0;
    for (final hashes in windows) {
      total += hashes.length;
    }
    final sorted = Int64List(total);
    var cursor = 0;
    for (final hashes in windows) {
      sorted.setAll(cursor, hashes);
      cursor += hashes.length;
    }
    sorted.sort();
    final runs = _groupRuns(sorted);
    // 그룹 위치 수 ≤ 창 수이므로 정렬이 끝난 사본을 위치 버퍼로 쓴다.
    final positions = Int64List.sublistView(sorted, 0, runs.offsets.last);
    _fillPositions(windows, runs.hashes, runs.offsets, positions);
    return (
      offsets: runs.offsets,
      positions: positions,
      saturated: runs.saturated,
    );
  }

  /// 정렬된 해시에서 같은 값의 연속 구간을 그룹으로 고른다.
  ///
  /// 길이 1 구간은 버리고, [positionCap]을 넘는 구간은 `saturated`로만 센다.
  /// `hashes`는 남은 그룹의 해시(오름차순), `offsets`는 그룹별 위치 시작점과
  /// 마지막의 전체 위치 수다.
  static ({Int64List hashes, Int32List offsets, int saturated}) _groupRuns(
    Int64List sorted,
  ) {
    var count = 0;
    var saturated = 0;
    for (var start = 0, end = 0; start < sorted.length; start = end) {
      end = _runEnd(sorted, start);
      if (end - start > positionCap) {
        saturated++;
      } else if (end - start >= 2) {
        count++;
      }
    }
    final hashes = Int64List(count);
    final offsets = Int32List(count + 1);
    var group = 0;
    for (var start = 0, end = 0; start < sorted.length; start = end) {
      end = _runEnd(sorted, start);
      final size = end - start;
      if (size < 2 || size > positionCap) continue;
      hashes[group] = sorted[start];
      offsets[group + 1] = offsets[group] + size;
      group++;
    }
    return (hashes: hashes, offsets: offsets, saturated: saturated);
  }

  /// [start]에서 시작하는 같은 값 구간의 끝(배타)이다.
  static int _runEnd(Int64List sorted, int start) {
    final value = sorted[start];
    var end = start + 1;
    while (end < sorted.length && sorted[end] == value) {
      end++;
    }
    return end;
  }

  /// 그룹에 속한 창의 위치를 세그먼트·인덱스 순서로 [positions]에 채운다.
  ///
  /// [positions]가 정렬 사본과 버퍼를 공유하므로 [hashes]·[offsets]를 다
  /// 만든 뒤에만 부른다.
  static void _fillPositions(
    List<Int64List> windows,
    Int64List hashes,
    Int32List offsets,
    Int64List positions,
  ) {
    if (hashes.isEmpty) return;
    final cursors = Int32List.fromList(offsets);
    for (var s = 0; s < windows.length; s++) {
      final segmentHashes = windows[s];
      for (var i = 0; i < segmentHashes.length; i++) {
        final group = _indexOf(hashes, segmentHashes[i]);
        if (group >= 0) positions[cursors[group]++] = (s << 32) | i;
      }
    }
  }

  /// 오름차순 [sorted]에서 [value]의 인덱스를 이진 탐색한다(없으면 -1).
  static int _indexOf(Int64List sorted, int value) {
    var low = 0;
    var high = sorted.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final candidate = sorted[middle];
      if (candidate < value) {
        low = middle + 1;
      } else if (candidate > value) {
        high = middle - 1;
      } else {
        return middle;
      }
    }
    return -1;
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

  /// 연속 윈도의 결정적 롤링 다항 해시다(63bit, mod 2^63-1 아님 — 마스크 연산).
  ///
  /// 위치마다 윈도 전체를 다시 곱하지 않고 나가는 코드를 빼고 들어오는 코드를
  /// 더해 O(1)에 갱신한다 — 토큰 N개·윈도 길이 k에서 O(N·k)가 O(N+k)가 된다.
  /// 해시 충돌은 같은 윈도로 오인해 발견 쌍을 만들 수 있으므로 FNV 대신
  /// 다항식을 쓰되 품질은 동급으로 유지한다. 63bit 비음수라 [Int64List]에
  /// 그대로 담긴다 — 박싱된 정수 리스트보다 창당 메모리가 작다.
  static Int64List _rollingHashes(List<int> codes, int length) {
    const mask = 0x7fffffffffffffff;
    const base = 0x100000001b3; // FNV 소수 — 이미 균일한 토큰 코드에 충분하다.
    // base^(length-1) — 나가는 항의 계수다.
    var highFactor = 1;
    for (var i = 1; i < length; i++) {
      highFactor = (highFactor * base) & mask;
    }
    // 롤링 회귀 h[i+1] = (h[i] - out·B^{k-1})·B + in 이 성립하려면 윈도 값이
    // 순수 다항식이어야 한다 — 상수 시드는 매 단계 B가 곱해져 회귀를 깬다.
    var hash = 0;
    for (var i = 0; i < length; i++) {
      hash = (hash * base + codes[i]) & mask;
    }
    final count = codes.length - length + 1;
    final hashes = Int64List(count);
    hashes[0] = hash;
    for (var i = 1; i < count; i++) {
      hash =
          ((hash - codes[i - 1] * highFactor) * base + codes[i + length - 1]) &
          mask;
      hashes[i] = hash;
    }
    return hashes;
  }
}
