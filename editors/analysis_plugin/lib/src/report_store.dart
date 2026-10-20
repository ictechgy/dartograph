import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

/// dartograph CLI를 실행해 보고서를 적재한다. 보고는 갱신 간격 안에서 재사용한다.
/// 간격이 지나면 패키지의 디스크 입력이 바뀌었을 때만 백그라운드로 다시 실행한다 —
/// CLI는 편집 중 버퍼가 아니라 디스크를 읽으므로, 저장이 없는 동안 다시 실행하면
/// 같은 결과를 다시 계산할 뿐이다. 분석 스레드를 막지 않도록 갱신은 비동기다.
abstract final class ReportCache {
  /// 갱신 간격의 하한이다 — 이전의 고정 TTL과 같은 30초다.
  static const _minimumRefreshInterval = Duration(seconds: 30);

  /// 갱신 간격은 직전 실행 시간의 이 배수다. 편집이 이어져도 백그라운드 CLI가
  /// 쓰는 시간이 전체의 약 1/11을 넘지 않는다.
  static const _refreshIntervalFactor = 10;

  /// 갱신 간격의 상한이다. 실행 도중 시스템이 잠들면 잰 실행 시간에 잠든 시간이
  /// 더해져, 상한이 없으면 간격이 며칠로 늘 수 있다. 리뷰가 잰 447파일 패키지의
  /// 콜드 첫 적재(약 35초, 간격 약 6분)보다 넉넉하게 둔다.
  static const _maximumRefreshInterval = Duration(minutes: 30);

  /// CLI를 함께 실행하는 루트 수의 상한이다. 루트마다 dead와 dup이 함께 뜨므로
  /// 백그라운드 CLI 프로세스는 많아야 네 개다.
  static const _maximumConcurrentRefreshes = 2;

  static final _entries = <String, _CacheEntry>{};

  /// 실행 자리를 기다리는 갱신이다(먼저 온 순서). 한 루트는 많아야 하나 들어 있다.
  static final _waitingRefreshes = Queue<Completer<void>>();

  /// 지금 실행 자리를 쥔 갱신 수다.
  static var _runningRefreshes = 0;

  /// 시작했지만 아직 끝나지 않은 백그라운드 갱신이다 — 테스트가 끝을 기다린다.
  static final _pendingRefreshes = <Future<void>>{};

  /// [root] 패키지의 최신 보고다. 첫 적재는 동기로 실행해 첫 분석 패스에서
  /// 진단을 낸다(플러그인 isolate만 막힌다). dead와 dup은 차례로 실행한다 —
  /// Dart에는 자식 프로세스 둘을 동기로 함께 기다리는 공개 API가 없다.
  /// 이후는 갱신 간격이 지나면 백그라운드 갱신을 시작하고 이전 보고를 돌려준다.
  static GraphReport? reportFor(String root) {
    final entry = _entries[root];
    if (entry == null) {
      final loaded = _loadSync(root);
      // 실패도 짧게 캐시한다 — CLI가 계속 죽어 있을 때 파일마다 동기 실행이
      // 플러그인 isolate를 반복해서 막지 않기 위해서다.
      _entries[root] = loaded;
      return loaded.report;
    }
    if (!entry.isRefreshing && entry.isDueAt(_now())) {
      _scheduleRefresh(root, entry);
    }
    return entry.report;
  }

  /// 테스트가 캐시와 주입값을 비우도록 한다. 진행 중인 갱신은 끝나도 비운 뒤의
  /// 캐시에 결과를 쓰지 않는다.
  static void clear() {
    _entries.clear();
    debugExecutable = null;
    debugNow = null;
  }

  /// 테스트가 실행 파일을 지정한다 — Platform.environment는 수정할 수 없어
  /// 환경 변수 경로를 테스트에서 검증할 수 없다.
  static String? debugExecutable;

  /// 테스트가 시계를 지정한다 — 갱신 간격과 실행 시간을 실제로 기다리지 않고
  /// 검증하기 위해서다. null이면 [DateTime.now]를 쓴다.
  static DateTime Function()? debugNow;

  /// 시작한 백그라운드 갱신이 모두 끝날 때까지 기다린다(테스트용). 기다리는
  /// 사이에 시작한 갱신도 기다린다.
  static Future<void> debugWaitForRefreshes() async {
    while (_pendingRefreshes.isNotEmpty) {
      await Future.wait(_pendingRefreshes.toList());
    }
  }

  /// 실행 파일 이름은 환경 변수로 바꿀 수 있다(테스트·커스텀 설치 경로).
  static String get _executable =>
      debugExecutable ??
      Platform.environment['DARTOGRAPH_EXECUTABLE'] ??
      'dartograph';

  /// 지금 시각이다. 테스트는 [debugNow]로 바꾼다.
  static DateTime _now() => (debugNow ?? DateTime.now)();

  /// [entry]의 갱신을 백그라운드로 시작한다. 끝날 때까지 같은 루트를 다시
  /// 넣지 않는다.
  static void _scheduleRefresh(String root, _CacheEntry entry) {
    entry.isRefreshing = true;
    late final Future<void> refresh;
    refresh = _refresh(root, entry).whenComplete(() {
      _pendingRefreshes.remove(refresh);
    });
    _pendingRefreshes.add(refresh);
  }

  /// 디스크 신호가 그대로면 CLI 없이 간격만 새로 센다. 신호가 바뀌었거나 재지
  /// 못했거나 직전 적재에 실패한 명령이 있으면 다시 적재한다 — 실패 원인(CLI
  /// 설치·버전, `pub get`)은 신호가 보지 않는 곳에 있을 수 있다.
  static Future<void> _refresh(String root, _CacheEntry entry) async {
    try {
      final signal = await _measureDiskSignal(root);
      if (entry.isComplete && signal != null && signal == entry.signal) {
        entry.checkedAt = _now();
      } else {
        await _reload(root, entry, signal);
      }
    } finally {
      entry.isRefreshing = false;
    }
  }

  /// 실행 자리를 얻어 [root]를 다시 적재하고 [entry]를 바꾼다. 비운 뒤(테스트)에는
  /// 결과를 버린다.
  static Future<void> _reload(
    String root,
    _CacheEntry entry,
    _DiskSignal? signal,
  ) async {
    await _acquireRefreshSlot();
    try {
      final reloaded = await _loadAsync(root, signal);
      if (identical(_entries[root], entry)) _entries[root] = reloaded;
    } finally {
      _releaseRefreshSlot();
    }
  }

  /// 실행 자리를 얻는다. 자리가 없으면 먼저 기다린 갱신부터 차례를 받는다.
  static Future<void> _acquireRefreshSlot() {
    if (_runningRefreshes < _maximumConcurrentRefreshes) {
      _runningRefreshes++;
      return Future.value();
    }
    final turn = Completer<void>();
    _waitingRefreshes.add(turn);
    return turn.future;
  }

  /// 실행 자리를 내준다. 기다리는 갱신이 있으면 자리를 그대로 넘긴다.
  static void _releaseRefreshSlot() {
    if (_waitingRefreshes.isEmpty) {
      _runningRefreshes--;
    } else {
      _waitingRefreshes.removeFirst().complete();
    }
  }

  /// [root]의 디스크 신호를 별도 isolate에서 잰다 — 트리 걷기가 분석 isolate를
  /// 막지 않게 한다. isolate를 띄우지 못했거나 결과 없이 끝났으면 null이고,
  /// 갱신은 변경으로 보고 진행한다.
  static Future<_DiskSignal?> _measureDiskSignal(String root) async {
    try {
      return await Isolate.run(() => _diskSignalOf(root));
    } on IsolateSpawnException {
      return null;
    } on RemoteError {
      return null;
    }
  }

  /// 첫 적재는 동기 실행이다. 디스크 신호는 CLI보다 먼저 잰다 — CLI가 읽는
  /// 동안 저장한 변경을 다음 확인이 놓치지 않게 하기 위해서다. 걷기는 stat만
  /// 하므로 동기 CLI 두 번에 견주면 짧다.
  static _CacheEntry _loadSync(String root) {
    final signal = _diskSignalOf(root);
    final startedAt = _now();
    final dead = _runSync('dead', root);
    final dup = _runSync('dup', root);
    return _entryFor(dead, dup, signal, startedAt);
  }

  /// 백그라운드 적재다. dead와 dup을 함께 실행한다.
  static Future<_CacheEntry> _loadAsync(
    String root,
    _DiskSignal? signal,
  ) async {
    final startedAt = _now();
    final documents = await Future.wait([
      _run('dead', root),
      _run('dup', root),
    ]);
    return _entryFor(documents[0], documents[1], signal, startedAt);
  }

  /// 두 명령의 결과로 캐시 항목을 만든다. [startedAt]부터 지금까지가 실행 시간이다.
  ///
  /// 두 명령이 모두 실패하면 보고 부재를 실패 상태로 짧게 남긴다 — 실패와
  /// "발견 없음"을 섞지 않기 위해서다. 한쪽만 실패하면 성공한 쪽을
  /// 서빙한다 — 명령이 없는 구버전 CLI(exit 64)에서도 dead 진단이
  /// 동작해야 하기 때문이다.
  static _CacheEntry _entryFor(
    Map<String, Object?>? dead,
    Map<String, Object?>? dup,
    _DiskSignal? signal,
    DateTime startedAt,
  ) {
    final finishedAt = _now();
    return _CacheEntry(
      report: dead == null && dup == null
          ? null
          : GraphReport(
              dead: dead == null ? const {} : parseDead(dead),
              dup: dup == null ? const {} : parseDup(dup),
            ),
      isComplete: dead != null && dup != null,
      signal: signal,
      checkedAt: finishedAt,
      refreshInterval: _refreshIntervalAfter(finishedAt.difference(startedAt)),
    );
  }

  /// 직전 실행 시간 [runTime]의 10배를 30초~30분으로 자른 갱신 간격이다.
  static Duration _refreshIntervalAfter(Duration runTime) {
    final scaled = runTime * _refreshIntervalFactor;
    if (scaled < _minimumRefreshInterval) return _minimumRefreshInterval;
    if (scaled > _maximumRefreshInterval) return _maximumRefreshInterval;
    return scaled;
  }

  /// [root]에서 [command]를 실행할 CLI 인자다. 동기·비동기 실행이 같은 인자를
  /// 쓴다.
  ///
  /// 증분 사실 캐시는 `--incremental-user-cache`로 패키지 밖 사용자 캐시에 둔다.
  /// 패키지 안 캐시 디렉터리는 저장소가 위조한 사실이나 FIFO 링크를 커밋해 둘 수
  /// 있는 자리다 — 첫 적재는 동기 실행이라, 그런 링크에서 CLI가 멈추면 플러그인
  /// isolate도 함께 멈춘다.
  static List<String> _arguments(String command, String root) => [
    command,
    '--format',
    'json',
    '--incremental-user-cache',
    root,
  ];

  static Map<String, Object?>? _runSync(String command, String root) {
    try {
      final result = Process.runSync(
        _executable,
        _arguments(command, root),
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
        _arguments(command, root),
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

/// 한 패키지 루트의 보고와 갱신 상태다.
final class _CacheEntry {
  _CacheEntry({
    required this.report,
    required this.isComplete,
    required this.signal,
    required this.checkedAt,
    required this.refreshInterval,
  });

  /// 마지막으로 적재한 보고다. 두 명령이 모두 실패했으면 null이다.
  final GraphReport? report;

  /// dead와 dup이 모두 성공했는지다. 아니면 디스크 신호와 무관하게 다시 시도한다.
  final bool isComplete;

  /// 이 보고를 만든 CLI 실행 직전의 디스크 신호다. 재지 못했으면 null이고,
  /// 다음 확인은 변경으로 본다.
  final _DiskSignal? signal;

  /// 간격을 세기 시작한 시각이다 — 적재를 마쳤거나 변경 없음을 확인한 때다.
  DateTime checkedAt;

  /// 다음 확인까지의 간격이다(직전 실행 시간에 비례한다).
  final Duration refreshInterval;

  /// 갱신이 대기 중이거나 진행 중인지다. 같은 루트를 다시 넣지 않는다.
  bool isRefreshing = false;

  /// [now]에 간격이 지났는지다.
  bool isDueAt(DateTime now) => now.difference(checkedAt) > refreshInterval;
}

/// 패키지 디스크 입력의 요약이다: 신호 파일 수, 크기 합, 가장 늦은 수정 시각,
/// 그리고 경로·크기·수정 시각을 이름순으로 섞은 지문이다. 레코드라 값으로
/// 비교된다. 지문은 이름 바꾸기처럼 크기·시각이 그대로인 목록 변화도 잡는다.
typedef _DiskSignal = ({
  int fileCount,
  int byteCount,
  int newestModified,
  int fingerprint,
});

/// 신호에서 빼는 디렉터리 이름이다. CLI 인덱스 순회가 건너뛰는 목록
/// (`lib/src/index/project_files.dart`의 `indexExcludedDirectories`)을 복제한다 —
/// 플러그인은 dartograph 패키지에 의존하지 않는다. 이름이 `.`으로 시작하는
/// 디렉터리도 뺀다(analyzer가 숨김 디렉터리를 분석하지 않는다).
const _skippedDirectoryNames = {'.dart_tool', '.git', 'build'};

/// `*.dart` 밖에서 신호에 넣는 파일 이름이다 — dead·dup 결과를 바꾸는 설정으로,
/// CLI가 결과 캐시 키에 넣는 분석 입력과 같다.
const _signalFileNames = {
  'pubspec.yaml',
  'analysis_options.yaml',
  'dartograph.yaml',
  'build.yaml',
};

/// FNV-1a 64비트의 시작값이다(네이티브 int는 64비트 2의 보수다).
const _fnvOffsetBasis = 0xcbf29ce484222325;

/// FNV-1a 64비트의 곱수다.
const _fnvPrime = 0x100000001b3;

/// 경로 구분자다. Windows는 `\`와 `/`를 모두 쓴다.
final _pathSeparator = Platform.isWindows ? RegExp(r'[\\/]') : RegExp('/');

/// 경로의 마지막 이름이다.
String _nameOf(String path) =>
    path.substring(path.lastIndexOf(_pathSeparator) + 1);

/// 신호 걷기가 들어가지도 섞지도 않는 이름인지다: 숨김 이름과
/// [_skippedDirectoryNames]다.
bool _isSkippedName(String name) =>
    name.startsWith('.') || _skippedDirectoryNames.contains(name);

/// [root] 아래 dead·dup 입력을 링크를 따라가지 않고 걸고, CLI가 읽는 패키지
/// 설정을 더해 디스크 신호를 잰다. 링크를 따라가지 않으므로 순환·공유 링크
/// 트리에서도 걷기가 끝난다.
/// 디렉터리를 읽지 못했거나 걷는 사이 파일이 사라졌으면 null이다 — 믿을 수
/// 없는 신호로 갱신을 건너뛰지 않는다.
_DiskSignal? _diskSignalOf(String root) {
  final walk = _SignalWalk();
  final pending = [root];
  try {
    while (pending.isNotEmpty) {
      if (!walk.addDirectory(pending.removeLast(), pending)) return null;
    }
    if (!walk.addPackageConfig(root)) return null;
  } on FileSystemException {
    return null;
  }
  return walk.signal;
}

/// 디스크 신호를 모으는 걷기 상태다. 지문은 FNV-1a 64비트다 — `Object.hash`는
/// isolate마다 시드가 달라, 걷기마다 새로 띄우는 isolate 사이에서 비교할 수 없다.
final class _SignalWalk {
  var _fileCount = 0;
  var _byteCount = 0;
  var _newestModified = 0;
  var _fingerprint = _fnvOffsetBasis;

  /// 지금까지 모은 신호다.
  _DiskSignal get signal => (
    fileCount: _fileCount,
    byteCount: _byteCount,
    newestModified: _newestModified,
    fingerprint: _fingerprint,
  );

  /// [directory]의 항목을 이름순으로 더하고, 내려갈 하위 디렉터리를 이름순으로
  /// 꺼내도록 [pending]에 쌓는다. 링크는 경로만 섞는다 — 생기거나 사라지면
  /// 분석 대상이 바뀐다. 걷는 사이 파일이 사라졌으면 false다.
  bool addDirectory(String directory, List<String> pending) {
    final entries = Directory(directory).listSync(followLinks: false)
      ..sort((left, right) => left.path.compareTo(right.path));
    final subdirectories = <String>[];
    for (final entry in entries) {
      final name = _nameOf(entry.path);
      if (entry is Directory) {
        if (!_isSkippedName(name)) subdirectories.add(entry.path);
      } else if (entry is Link) {
        if (!_isSkippedName(name)) _mixPath(entry.path);
      } else if (name.endsWith('.dart') || _signalFileNames.contains(name)) {
        if (!_addFile(entry.path)) return false;
      }
    }
    pending.addAll(subdirectories.reversed);
    return true;
  }

  /// CLI가 읽는 패키지 설정을 더한다: 루트의 `.dart_tool/package_config.json`,
  /// 없으면 가장 가까운 조상의 것(pub 워크스페이스 멤버)이다. `.dart_tool`은
  /// 걷지 않지만 `pub get`이 해석을 바꾸면 결과가 바뀌므로 이 파일 하나는 본다.
  /// 어디에도 없으면 더하지 않는다. 걷는 사이 사라졌으면 false다.
  bool addPackageConfig(String root) {
    final separator = Platform.pathSeparator;
    for (var directory = Directory(root); ; directory = directory.parent) {
      final config =
          '${directory.path}$separator.dart_tool${separator}package_config.json';
      if (FileSystemEntity.isFileSync(config)) return _addFile(config);
      if (directory.parent.path == directory.path) return true;
    }
  }

  /// 신호 파일 하나의 크기와 수정 시각을 더한다. 걷는 사이 사라졌으면 false다.
  bool _addFile(String path) {
    final stat = FileStat.statSync(path);
    if (stat.type == FileSystemEntityType.notFound) return false;
    final modified = stat.modified.microsecondsSinceEpoch;
    _fileCount++;
    _byteCount += stat.size;
    if (modified > _newestModified) _newestModified = modified;
    _mixPath(path);
    _mix(stat.size);
    _mix(modified);
    return true;
  }

  /// 경로의 코드 단위를 지문에 섞는다. 끝 표지를 섞어 이웃 경로와 경계가 갈린다.
  void _mixPath(String path) {
    for (final unit in path.codeUnits) {
      _mix(unit);
    }
    _mix(-1);
  }

  /// FNV-1a 한 단계다. 곱셈 넘침은 64비트에서 감긴다.
  void _mix(int value) => _fingerprint = (_fingerprint ^ value) * _fnvPrime;
}
