import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/atomic_write.dart';

/// 파일 내용의 sha256 hex다. 증분 캐시 키의 파일 부분이다.
///
/// 동기 읽기다. 호출자는 파일을 순서대로 하나씩 해싱하므로 비동기 `readAsBytes`의
/// 이벤트 루프 왕복이 이득 없이 비용만 더한다(600파일 기준 실측 41ms → 14ms).
String fileContentHash(File file) =>
    sha256.convert(file.readAsBytesSync()).toString();

/// 캐시 한 항목이다. 해석 키와 그 파일에서 추출한 사실 JSON을 함께 둔다.
final class CachedFacts {
  /// 항목을 만든다.
  const CachedFacts({required this.key, required this.facts});

  /// 이 사실이 유효한지 판단하는 해석 키다(내용 해시 + 해석 입력).
  final String key;

  /// 호출자가 정한 사실 JSON이다. 캐시는 형식을 해석하지 않는다.
  final Map<String, Object?> facts;

  /// JSON 표현이다.
  Map<String, Object?> toJson() => {'facts': facts, 'key': key};

  /// 파싱한다. 형식이 어긋나면 null이고 호출자는 캐시 미스로 처리한다.
  ///
  /// 항목 하나의 손상이 캐시 전체를 버리지 않게 한다 — 손상된 파일만 다시
  /// 해석되고 나머지는 그대로 재사용된다.
  static CachedFacts? fromJson(Object? value) {
    try {
      if (value is! Map) return null;
      final key = value['key'];
      final facts = value['facts'];
      if (key is! String || facts is! Map) return null;
      return CachedFacts(key: key, facts: Map<String, Object?>.from(facts));
    } on Object {
      return null;
    }
  }
}

/// 증분 실행 한 번의 관측값이다. 캐시 파일에는 저장하지 않는다.
///
/// 호출자가 캐시 객체를 소유하므로 실행 뒤 이 값으로 재사용·재해석 규모를
/// 확인할 수 있다(테스트와 벤치마크가 같은 값을 본다).
final class IncrementalStats {
  /// 캐시에서 사실을 재사용한 파일 수다.
  int reusedFiles = 0;

  /// 이번 실행에서 다시 해석한 파일 수다.
  int resolvedFiles = 0;

  /// 이번 실행이 캐시를 갱신하지 않았는지 여부다(쓰기 실패 또는 해석 중 입력
  /// 변경). 분석 결과는 그대로 유효하다. 쓰기 자체가 실패한 경우에만 그 사실이
  /// limitation으로 출력에 남는다 — 입력이 바뀌어 저장을 건너뛴 경우는 전체
  /// 해석 경로와 같이 조용히 넘어간다.
  bool cacheNotUpdated = false;
}

/// 파일 단위 사실 캐시다.
///
/// 설계 근거는 `doc/DECISION-incremental.md`다. 이 모듈은 해석 API에 의존하지
/// 않는다 — 키 계산·영속·역방향 폐쇄 도구만 제공하고, 무엇을 다시 해석할지는
/// 호출자(`AnalyzerGraphIndex`)가 사실 그래프 수준에서 판단한다.
///
/// 캐시는 최적화지 계약이 아니다. 파일이 없거나 손상됐거나 스키마가 다르거나
/// 읽을 수 없으면 빈 캐시로 취급해 전체 분석으로 폴백한다. 오류로 끝내지 않는다.
final class IncrementalCache {
  /// [directory]를 캐시 디렉터리로 삼는다. 없으면 쓸 때 만든다.
  IncrementalCache(this.directory, {IncrementalStats? stats})
    : stats = stats ?? IncrementalStats();

  /// 호출자가 지정한 캐시 디렉터리다(`--incremental <dir>`).
  final String directory;

  /// 이 인스턴스로 실행한 마지막 분석의 관측값이다.
  final IncrementalStats stats;

  /// 캐시 파일이다.
  File get file => File(p.join(directory, _fileName));

  /// 캐시 스키마 버전이다. 사실 JSON의 형식을 바꾸면 올린다 — 올리면 전부
  /// 미스가 되어 다음 실행이 전체 재해석으로 복구한다.
  /// v2: `_UnitFacts.complexity` 필드 추가.
  static const schemaVersion = 2;

  static const _fileName = 'facts.json';

  /// 전체 해석 키를 만든다.
  ///
  /// 도구 버전·SDK 버전·설정 지문(설정 파일·package config·의존 패키지 `lib`)을
  /// 섞는다. 하나라도 바뀌면 모든 파일 키가 바뀌어 전체 재해석으로 폴백한다 —
  /// 기존 `_cacheIdentity`와 같은 규칙이다. 호출자가 프로젝트 루트마다 캐시
  /// 디렉터리를 분리한다는 전제를 문서화한다(한 디렉터리를 서로 다른 체크아웃에
  /// 재사용하면 키가 겹칠 수 있다).
  static String resolutionKey({
    required String toolVersion,
    required String sdkVersion,
    required String configFingerprint,
  }) => _digest([
    schemaVersion.toString(),
    toolVersion,
    sdkVersion,
    configFingerprint,
  ]);

  /// 파일 하나의 캐시 키다. 캐시 맵의 키는 파일 경로이므로 키에는 내용과
  /// 해석 입력만 섞는다.
  static String keyFor({
    required String resolutionKey,
    required String contentHash,
  }) => _digest([resolutionKey, contentHash]);

  /// 역방향 폐쇄를 구한다. [seeds]와 [seeds]에 (전이적으로) 의존하는 모든
  /// 노드를 돌려준다.
  ///
  /// 노드 단위는 호출자가 정한다. 인덱스는 라이브러리 ID를 쓴다 — 파일 하나가
  /// 바뀌면 그 파일의 라이브러리 전체가 다시 해석되고, 그 라이브러리를
  /// import/export하는 라이브러리가 이어서 다시 해석된다.
  static Set<String> reverseClosure(
    Iterable<String> seeds,
    Map<String, Set<String>> reverseImports,
  ) {
    final stale = <String>{};
    final queue = <String>[...seeds];
    while (queue.isNotEmpty) {
      final node = queue.removeLast();
      if (!stale.add(node)) continue;
      queue.addAll(reverseImports[node] ?? const <String>{});
    }
    return stale;
  }

  /// 캐시를 읽는다. 없거나 손상됐으면 빈 맵을 돌려준다.
  Future<Map<String, CachedFacts>> load() async {
    try {
      if (!file.existsSync()) return const {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const {};
      if (decoded['schemaVersion'] != schemaVersion) return const {};
      final entries = decoded['entries'];
      if (entries is! Map) return const {};
      final result = <String, CachedFacts>{};
      for (final entry in entries.entries) {
        final key = entry.key;
        final parsed = CachedFacts.fromJson(entry.value);
        if (key is String && parsed != null) result[key] = parsed;
      }
      return result;
    } on Object {
      // 형식 오류·읽기 실패 모두 캐시 미스와 같다. 전체 분석이 복구 경로다.
      return const {};
    }
  }

  /// 캐시를 원자적으로 갱신한다.
  ///
  /// 교체는 임시 파일 + rename이다(append-only가 아니다). 중단돼도 이전 캐시가
  /// 남아 반쯤 갱신된 상태가 되지 않는다. 쓰지 못하면 false를 돌려주고, 호출자가
  /// 분석은 그대로 마치되 그 사실을 limitation으로 남긴다.
  Future<bool> store(Map<String, CachedFacts> entries) async {
    try {
      await Directory(directory).create(recursive: true);
      await AtomicWrite.string(
        file,
        jsonEncode({
          'entries': {
            for (final entry in entries.entries)
              entry.key: entry.value.toJson(),
          },
          'schemaVersion': schemaVersion,
        }),
      );
      return true;
    } on Object {
      return false;
    }
  }

  static String _digest(List<String> parts) =>
      sha256.convert(utf8.encode('${parts.join('\u0000')}\u0000')).toString();
}
