import 'dart:convert';
import 'dart:io';

import '../core/atomic_write.dart';
import 'reachability_analyzer.dart';

/// 기존 코드베이스에서 이미 확인된 발견의 결정적 지문 모음이다.
final class Baseline {
  Baseline._(this.fingerprints);

  /// 현재 파일 형식이다. 모르는 형식을 조용히 적용하지 않는다.
  static const formatVersion = 1;

  /// 정렬되고 중복이 제거된 발견 지문이다.
  final List<String> fingerprints;

  /// 현재 발견을 대체 스냅샷으로 기록한다.
  factory Baseline.capture(Iterable<DeadFinding> findings) {
    final fingerprints = findings.map(_fingerprint).toSet().toList()..sort();
    return Baseline._(fingerprints);
  }

  /// 알려진 발견을 제외하고 억제 수를 함께 돌려준다.
  BaselineFilterResult filter(Iterable<DeadFinding> findings) {
    final known = fingerprints.toSet();
    final remaining = <DeadFinding>[];
    var suppressed = 0;
    for (final finding in findings) {
      if (known.contains(_fingerprint(finding))) {
        suppressed++;
      } else {
        remaining.add(finding);
      }
    }
    return BaselineFilterResult(remaining, suppressed);
  }

  static String _fingerprint(DeadFinding finding) =>
      jsonEncode({'id': finding.id, 'kind': finding.kind});
}

/// 베이스라인 적용 뒤 남은 발견과 숨겨진 수다.
final class BaselineFilterResult {
  /// 필터 결과를 만든다.
  const BaselineFilterResult(this.findings, this.suppressedCount);

  /// 새로 보고할 발견이다.
  final List<DeadFinding> findings;

  /// 정확한 지문이 일치해 억제된 발견 수다.
  final int suppressedCount;
}

/// 베이스라인 파일의 검증된 입출력 경계다.
abstract final class BaselineStore {
  /// 부모 디렉터리를 만들고 결정적 JSON을 쓴다.
  ///
  /// 임시 파일의 배타적 생성·원자적 교체·실패 시 정리는 AtomicWrite 경계가
  /// 담당하며, 이 경계는 baseline payload의 결정적 직렬화만 소유한다.
  static Future<void> write(Baseline baseline, File file) async {
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await AtomicWrite.string(
      file,
      '${encoder.convert({'fingerprints': baseline.fingerprints, 'formatVersion': Baseline.formatVersion, 'tool': 'dartograph'})}\n',
    );
  }

  /// 스키마와 모든 지문 타입을 검증한 뒤 읽는다.
  static Future<Baseline> read(File file) async {
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, Object?> ||
          value['tool'] != 'dartograph' ||
          value['formatVersion'] != Baseline.formatVersion ||
          value['fingerprints'] is! List<Object?> ||
          !(value['fingerprints']! as List<Object?>).every(
            (item) => item is String,
          )) {
        throw const FormatException('unsupported or invalid baseline format');
      }
      final fingerprints = (value['fingerprints']! as List<Object?>)
          .cast<String>();
      if (fingerprints.toSet().length != fingerprints.length) {
        throw const FormatException('baseline fingerprints must be unique');
      }
      return Baseline._(fingerprints.toList()..sort());
    } on FormatException {
      rethrow;
    }
  }
}
