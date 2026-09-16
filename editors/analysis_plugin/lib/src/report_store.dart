import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 한 발견의 파일 위치와 근거 메시지다. analyzer 타입에 의존하지 않는다.
final class PluginFinding {
  /// 발견을 만든다.
  const PluginFinding({
    required this.file,
    required this.line,
    required this.column,
    required this.message,
    this.endLine,
  });

  /// 패키지 루트 상대 경로다(`project:` 스킴은 벗겨져 있다).
  final String file;

  /// 1부터 시작하는 행이다. 파일 수준 발견은 1이다.
  final int line;

  /// 1부터 시작하는 열이다.
  final int column;

  /// 블록 발견의 마지막 행이다(점 진단이면 null).
  final int? endLine;

  /// 진단 본문에 실릴 근거다.
  final String message;
}

/// `dead`/`dup` JSON 보고서를 파일별 발견 목록으로 해석한다.
final class GraphReport {
  /// 보고를 만든다.
  const GraphReport({required this.dead, required this.dup});

  /// 파일 상대 경로 → dead 발견 목록이다.
  final Map<String, List<PluginFinding>> dead;

  /// 파일 상대 경로 → dup 발견 목록이다.
  final Map<String, List<PluginFinding>> dup;
}

/// `project:` 스킴을 벗긴다. 다른 스킴은 패키지 밖 위치이므로 null이다.
String? stripScheme(String? source) {
  if (source == null || source.isEmpty) return null;
  if (source.startsWith('project:')) return source.substring(8);
  return source.contains(':') ? null : source;
}

/// 루트 밖 경로를 배제한다 — 보고서 값을 파일 시스템 경로로 바로 쓰지 않는다.
String? safeRelative(String? file) {
  if (file == null || file.isEmpty) return null;
  if (file.startsWith('/') || file.startsWith('\\')) return null;
  if (RegExp(r'^[A-Za-z]:').hasMatch(file)) return null;
  if (file.split('/').contains('..')) return null;
  return file;
}

/// 문서 필드를 List로만 받는다 — 모양이 어긋난 보고서는 던지지 않고 건너뛴다.
List<Object?>? _listField(Map<Object?, Object?> map, String key) {
  final value = map[key];
  return value is List ? value : null;
}

/// 문서 필드를 String으로만 받는다.
String? _stringField(Map<Object?, Object?> map, String key) {
  final value = map[key];
  return value is String ? value : null;
}

/// 문서 필드를 int로만 받는다 — double 등 다른 수치형은 null이다.
int? _intField(Map<Object?, Object?> map, String key) {
  final value = map[key];
  return value is int ? value : null;
}

/// `dead --format json` 문서를 파일별 발견으로 변환한다.
Map<String, List<PluginFinding>> parseDead(Map<String, Object?> document) {
  final byFile = <String, List<PluginFinding>>{};
  for (final finding in _listField(document, 'findings') ?? const []) {
    if (finding is! Map) continue;
    final file = safeRelative(stripScheme(_stringField(finding, 'source')));
    if (file == null) continue;
    final line = _intField(finding, 'line') ?? 1;
    final column = _intField(finding, 'column') ?? 1;
    byFile
        .putIfAbsent(file, () => [])
        .add(
          PluginFinding(
            file: file,
            line: line < 1 ? 1 : line,
            column: column < 1 ? 1 : column,
            message: '${finding['kind']}: ${finding['reason']}',
          ),
        );
  }
  return byFile;
}

/// `dup --format json` 문서를 파일별 발견으로 변환한다.
Map<String, List<PluginFinding>> parseDup(Map<String, Object?> document) {
  final byFile = <String, List<PluginFinding>>{};
  for (final finding in _listField(document, 'findings') ?? const []) {
    if (finding is! Map) continue;
    final instances = _listField(finding, 'instances') ?? const [];
    final tokenCount = finding['tokenCount'];
    for (final instance in instances) {
      if (instance is! Map) continue;
      final file = safeRelative(stripScheme(_stringField(instance, 'source')));
      if (file == null) continue;
      final others = [
        for (final peer in instances)
          if (peer != instance && peer is Map)
            '${stripScheme(_stringField(peer, 'source')) ?? peer['source']}'
                ':${peer['startLine']}',
      ];
      // parseDead와 같이 1 미만은 1로, 뒤집힌 범위는 점으로 정규화한다 —
      // 진단 층의 getOffsetOfLine은 범위 밖 행에 RangeError를 던진다.
      final start = (_intField(instance, 'startLine') ?? 1).clamp(1, 1 << 30);
      final rawEnd = _intField(instance, 'endLine');
      byFile
          .putIfAbsent(file, () => [])
          .add(
            PluginFinding(
              file: file,
              line: start,
              column: 1,
              endLine: rawEnd != null && rawEnd >= start ? rawEnd : start,
              message:
                  'duplicate block ($tokenCount tokens)'
                  '${others.isEmpty ? '' : ' — also at ${others.join(', ')}'}',
            ),
          );
    }
  }
  return byFile;
}

/// dartograph CLI를 실행해 보고서를 적재한다. 캐시는 TTL 안에서 재사용되고
/// 만료되면 백그라운드로 갱신한다 — 분석 스레드를 막지 않기 위해 비동기다.
abstract final class ReportCache {
  static const _ttl = Duration(seconds: 30);
  static final _entries = <String, _CacheEntry>{};

  /// [root] 패키지의 최신 보고다. 첫 적재는 동기로 실행해 첫 분석 패스에서
  /// 진단을 낸다(플러그인 isolate만 막히며 증분 캐시가 비용을 줄인다).
  /// 이후는 TTL 만료 시 백그라운드 갱신을 시작하고 이전 보고를 돌려준다.
  static GraphReport? reportFor(String root) {
    final entry = _entries[root];
    if (entry != null && !entry.isStale) return entry.report;
    if (entry == null) {
      final report = _loadSync(root);
      // 실패도 짧게 캐시한다 — CLI가 계속 죽어 있을 때 파일마다 동기 실행이
      // 플러그인 isolate를 반복해서 막지 않기 위해서다.
      _entries[root] = _CacheEntry(report);
      return report;
    }
    if (!entry.loading) {
      _entries[root] = _CacheEntry.loading(entry.report);
      unawaited(_load(root));
    }
    return entry.report;
  }

  /// 테스트가 캐시와 실행 파일 지정을 비우도록 한다.
  static void clear() {
    _entries.clear();
    debugExecutable = null;
  }

  /// 테스트가 실행 파일을 지정한다 — Platform.environment는 수정할 수 없어
  /// 환경 변수 경로를 테스트에서 검증할 수 없다.
  static String? debugExecutable;

  /// 실행 파일 이름은 환경 변수로 바꿀 수 있다(테스트·커스텀 설치 경로).
  static String get _executable =>
      debugExecutable ??
      Platform.environment['DARTOGRAPH_EXECUTABLE'] ??
      'dartograph';

  static Future<void> _load(String root) async {
    final dead = await _run('dead', root);
    final dup = await _run('dup', root);
    // 두 명령이 모두 실패하면 보고 부재를 실패 상태로 짧게 남긴다 — 실패와
    // "발견 없음"을 섞지 않기 위해서다. 한쪽만 실패하면 성공한 쪽을
    // 서빙한다 — 명령이 없는 구버전 CLI(exit 64)에서도 dead 진단이
    // 동작해야 하기 때문이다.
    if (dead == null && dup == null) {
      _entries[root] = _CacheEntry(null);
      return;
    }
    _entries[root] = _CacheEntry(
      GraphReport(
        dead: dead == null ? const {} : parseDead(dead),
        dup: dup == null ? const {} : parseDup(dup),
      ),
    );
  }

  /// 첫 적재는 동기 실행이다. 두 명령 모두 실패 시 null이다.
  static GraphReport? _loadSync(String root) {
    final dead = _runSync('dead', root);
    final dup = _runSync('dup', root);
    if (dead == null && dup == null) return null;
    return GraphReport(
      dead: dead == null ? const {} : parseDead(dead),
      dup: dup == null ? const {} : parseDup(dup),
    );
  }

  static Map<String, Object?>? _runSync(String command, String root) {
    try {
      final result = Process.runSync(
        _executable,
        [
          command,
          '--format',
          'json',
          '--incremental',
          '.dartograph/cache',
          root,
        ],
        workingDirectory: root,
        stdoutEncoding: utf8,
      );
      if (result.exitCode != 0 && result.exitCode != 1) return null;
      final decoded = jsonDecode(result.stdout as String);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on ProcessException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// 한 명령을 실행해 JSON 문서를 돌려준다. 실패(실행 불가·분석 오류·파싱
  /// 실패)는 null이다 — 보고 부재를 "발견 없음"과 섞지 않기 위해 구분한다.
  static Future<Map<String, Object?>?> _run(String command, String root) async {
    try {
      final result = await Process.run(
        _executable,
        [
          command,
          '--format',
          'json',
          '--incremental',
          '.dartograph/cache',
          root,
        ],
        workingDirectory: root,
        stdoutEncoding: utf8,
      );
      // 0과 1(발견)만 정상 결과다.
      if (result.exitCode != 0 && result.exitCode != 1) return null;
      final decoded = jsonDecode(result.stdout as String);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on ProcessException {
      return null;
    } on FormatException {
      return null;
    }
  }
}

final class _CacheEntry {
  _CacheEntry(this.report) : loading = false, loadedAt = DateTime.now();

  _CacheEntry.loading(this.report)
    : loading = true,
      loadedAt = DateTime.fromMillisecondsSinceEpoch(0);

  final GraphReport? report;
  final bool loading;
  final DateTime loadedAt;

  bool get isStale =>
      loading || DateTime.now().difference(loadedAt) > ReportCache._ttl;
}
