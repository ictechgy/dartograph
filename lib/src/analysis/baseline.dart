import 'dart:convert';
import 'dart:io';

import '../core/atomic_write.dart';
import '../core/config_source.dart';
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
  /// [read]가 받아들이는 baseline 파일 크기의 상한(64 MiB)이다.
  ///
  /// baseline은 finding 수에 비례해 커지므로 설정 상한(1 MiB)과 따로 둔다.
  /// 지문 한 줄은 들여쓰기·이스케이프를 합쳐 대개 100~300바이트라, 수십만
  /// finding을 기록한 대형 모노레포 baseline도 이 안에 든다. 상한은 저장소가
  /// 커밋한 baseline 링크나 MCP 도구 인자가 장치·과대 파일을 가리켜 메모리를
  /// 채우지 않게 하는 fail-closed 경계다.
  static const sizeLimit = 64 * 1024 * 1024;

  static const _tooLarge =
      'baseline file exceeds the ${sizeLimit ~/ (1024 * 1024)} MiB limit';

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
  ///
  /// 정규 파일이 아니거나(장치·FIFO·소켓) [sizeLimit]을 넘으면 열거나 끝까지
  /// 읽기 전에 [FormatException]으로 실패한다([readBoundedFile]). 쓰는 쪽이 없는
  /// FIFO는 열기에서 영구 대기하고, 문자 장치는 길이를 0으로 보고한 채 EOF 없이
  /// 읽힌다. 부재·읽기·UTF-8 디코드 실패는 지금처럼 [FileSystemException]이다.
  static Future<Baseline> read(File file) async {
    try {
      final value = jsonDecode(
        await readBoundedFile(file, sizeLimit, tooLargeMessage: _tooLarge),
      );
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
