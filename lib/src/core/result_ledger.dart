import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 검증 원장 한 줄이다. 한 번 쓰인 줄은 다시 쓰지 않는다.
///
/// `--record <dir>`로 남기는 실행 기록 하나를 나타낸다. 시각(`recordedAt`)은
/// 관측값이므로 원장 자체는 결정적 산출물이 아니다 — 제품 출력의 결정성 계약과
/// 무관하다(USAGE의 선언된 예외와 같은 성격).
final class LedgerEntry {
  /// 항목을 만든다. [inputs]는 실행 입력의 요약이며 플래그·경로만 담는다
  /// (환경변수 값·토큰 같은 민감 값은 담지 않는다).
  const LedgerEntry({
    required this.recordedAt,
    required this.toolVersion,
    required this.command,
    required this.exitCode,
    this.commit,
    this.inputs = const {},
    this.failedItems = const [],
  });

  /// 기록 시각(UTC)이다.
  final DateTime recordedAt;

  /// 기록한 도구 버전(`toolVersion`)이다.
  final String toolVersion;

  /// 실행한 명령 이름이다(`impact`·`runtime`·`dead` 등).
  final String command;

  /// 프로세스 종료 코드다(0·1·2·64).
  final int exitCode;

  /// 관측된 커밋 SHA다. 계산하지 못했으면 null이다(추정값을 넣지 않는다).
  final String? commit;

  /// 실행 입력 요약이다(예: `{'format': 'json', 'since': 'origin/main'}`).
  final Map<String, String> inputs;

  /// 그 명령이 보고한 문제 식별자다. 문제가 없으면 빈 목록이다.
  ///
  /// 명령마다 식별자가 다르다 — `dead`는 finding ID, `cycles`는 끊을 후보
  /// 간선, `rules`는 위반 규칙·간선, `metrics`는 임계 초과 라이브러리,
  /// `runtime`은 미충족·미판정 사실, `impact`는 피영향 심볼이다. 문제를
  /// 정의하지 않는 명령(graph·query 등)은 빈 목록이다.
  final List<String> failedItems;

  /// JSON 표현이다. `inputs` 키를 사전순으로 고정해 같은 입력이 같은 byte로
  /// 직렬화되게 한다(`failedItems`는 보고 순서가 의미라 그대로 둔다).
  Map<String, Object?> toJson() => {
    'command': command,
    'commit': commit,
    'exitCode': exitCode,
    'failedItems': failedItems,
    'inputs': {
      for (final key in inputs.keys.toList()..sort()) key: inputs[key],
    },
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'toolVersion': toolVersion,
  };

  /// 파싱한다. 형식이 어긋나면 null을 돌려주고 호출자가 건너뛴 줄로 센다.
  static LedgerEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final recordedAt = DateTime.tryParse('${value['recordedAt']}');
    final command = value['command'];
    final exitCode = value['exitCode'];
    if (recordedAt == null || command is! String || exitCode is! int) {
      return null;
    }
    final inputs = <String, String>{};
    final rawInputs = value['inputs'];
    if (rawInputs is Map) {
      for (final entry in rawInputs.entries) {
        inputs['${entry.key}'] = '${entry.value}';
      }
    }
    final failedItems = <String>[];
    final rawFailed = value['failedItems'];
    if (rawFailed is List) {
      for (final item in rawFailed) {
        failedItems.add('$item');
      }
    }
    final commit = value['commit'];
    return LedgerEntry(
      recordedAt: recordedAt,
      toolVersion: '${value['toolVersion']}',
      command: command,
      exitCode: exitCode,
      commit: commit is String ? commit : null,
      inputs: inputs,
      failedItems: failedItems,
    );
  }
}

/// 원장을 읽은 결과다. 손상 줄을 숨기지 않고 함께 돌려준다.
final class LedgerReadResult {
  /// 읽기 결과를 만든다.
  const LedgerReadResult({required this.entries, required this.skippedLines});

  /// 성공적으로 파싱한 항목이다(기록 순서 그대로).
  final List<LedgerEntry> entries;

  /// 파싱하지 못해 건너뛴 줄 수다. 0이 아니면 원장이 손상되거나 쓰기가
  /// 중단된 것이다.
  final int skippedLines;

  /// 손상 여부다.
  bool get isDamaged => skippedLines > 0;
}

/// append-only JSONL 원장이다.
///
/// 파일은 `<directory>/ledger.jsonl` 하나이고, 각 줄이 [LedgerEntry] 하나다.
/// 기존 줄은 절대 수정·삭제하지 않는다 — [append]는 항상 파일 끝에만 쓴다.
final class ResultLedger {
  /// [directory]를 원장 디렉터리로 삼는다.
  ResultLedger(this.directory);

  /// 원장 디렉터리 경로다.
  final String directory;

  /// 원장 파일이다.
  File get file => File(p.join(directory, _fileName));

  static const _fileName = 'ledger.jsonl';

  /// 항목 하나를 파일 끝에 덧붙인다.
  ///
  /// `FileMode.append`는 POSIX에서 `O_APPEND`로 열리므로, 여러 프로세스가
  /// 동시에 append해도 각 줄이 서로 섞이지 않는다(줄 단위 원자성). 그래서 임시
  /// 파일 + rename을 쓰지 않는다 — rename은 **전체 파일 교체**라 append-only
  /// 계약과 맞지 않는다.
  ///
  /// 쓰기 도중 프로세스가 죽으면 마지막 줄이 잘릴 수 있다. 그 경우는 [read]가
  /// 손상 줄로 세고 건너뛴다(복구 경로). 원장은 그대로 두고 다음 append부터
  /// 정상으로 돌아오며, 지우거나 고치지 않는다.
  Future<void> append(LedgerEntry entry) async {
    await Directory(directory).create(recursive: true);
    // 앞선 쓰기가 중단돼 마지막 줄이 개행 없이 잘렸으면 먼저 개행을 넣는다.
    // 그대로 append하면 새 항목이 잘린 줄에 이어 붙어 한 줄이 되고,
    // 읽기는 그 줄을 통째로 버려 새 항목까지 잃는다. 개행을 넣으면 잘린 줄은
    // 자기 줄로 남아 손상 줄로 세어지고 새 항목은 온전한 줄로 시작한다.
    var prefix = '';
    if (file.existsSync() && file.lengthSync() > 0) {
      final reader = await file.open(mode: FileMode.read);
      try {
        reader.setPositionSync(file.lengthSync() - 1);
        if (reader.readByteSync() != 0x0a) prefix = '\n';
      } finally {
        await reader.close();
      }
    }
    final line = '$prefix${jsonEncode(entry.toJson())}\n';
    final handle = await file.open(mode: FileMode.append);
    try {
      handle.writeStringSync(line);
      handle.flushSync();
    } finally {
      await handle.close();
    }
  }

  /// 원장을 읽는다. [commit]을 주면 그 커밋의 항목만 고른다.
  ///
  /// 빈 줄은 건너뛴 줄로 세지 않는다. 파싱 실패 줄만
  /// [LedgerReadResult.skippedLines]에 들어간다 — 잘린 마지막 줄이 대표적이다.
  Future<LedgerReadResult> read({String? commit}) async {
    if (!file.existsSync()) {
      return const LedgerReadResult(entries: [], skippedLines: 0);
    }
    final entries = <LedgerEntry>[];
    var skipped = 0;
    // 원장은 append-only로 무한정 자란다 — 전체를 한 리스트로 올리지 않고
    // 줄 단위로 흘려보낸다.
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        skipped++;
        continue;
      }
      final entry = LedgerEntry.fromJson(decoded);
      if (entry == null) {
        skipped++;
        continue;
      }
      if (commit != null && entry.commit != commit) continue;
      entries.add(entry);
    }
    return LedgerReadResult(entries: entries, skippedLines: skipped);
  }
}
