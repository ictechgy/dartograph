import 'dart:io';
import 'dart:math';

/// 대상 파일을 임시 파일에 기록한 뒤 원자적 교체로 쓰는 공용 쓰기 경계다.
///
/// 임시 이름은 PID와 무작위 접미사로 예측하기 어렵게 만들고 배타적 생성으로
/// 열어 미리 심어진 파일·심볼릭 링크를 절단하거나 관통하지 못하게 한다 —
/// 그 자리에 무엇이든 존재하면 예외로 실패한다. rename은 대상 자리의
/// 심볼릭 링크를 따라가지 않고 링크 자체를 교체하므로, 신뢰할 수 없는
/// 디렉터리에서의 `--force` 덮어쓰기가 링크 대상 파일을 오염시키지 않는다.
///
/// 보장의 경계는 문서화돼 있다. 배타적 생성의 링크 비관통은 POSIX 속성이고
/// Windows의 CREATE_NEW는 최종 성분의 링크를 따라갈 수 있으므로 접미사
/// 엔트로피가 완화 역할을 한다. 디렉터리 쓰기 권한을 가진 동시 실행
/// 공격자가 임시 파일을 치우고 링크를 심는 적극적 race는 범위 밖이며,
/// 대상까지의 경로 성분(최종 성분 제외)의 심볼릭 링크는 사용자 지정
/// 목적지의 의미로 그대로 따라간다. 부모 디렉터리는 만들지 않는다 —
/// 호출자가 필요하면 미리 만든다.
abstract final class AtomicWrite {
  /// [contents]를 [target]에 원자적으로 기록한다.
  ///
  /// 임시 파일 생성·기록·교체 중 어느 단계가 실패해도 임시 파일을 치우고
  /// 기존 대상 파일은 그대로 유지된다. [tempSuffix]는 배타적 생성 충돌을
  /// 고정해 재현하는 테스트용이다.
  static void stringSync(File target, String contents, {String? tempSuffix}) {
    final temporary = File(_temporaryPath(target, tempSuffix));
    var created = false;
    try {
      temporary.createSync(exclusive: true);
      created = true;
      temporary.writeAsStringSync(contents, flush: true);
      temporary.renameSync(target.path);
      created = false;
    } finally {
      if (created) _cleanUp(temporary);
    }
  }

  /// [contents]를 [target]에 원자적으로 기록한다(비동기).
  ///
  /// 실패 시 임시 파일을 치우고 기존 대상 파일을 유지한다는 계약은
  /// [stringSync]와 같다.
  static Future<void> string(
    File target,
    String contents, {
    String? tempSuffix,
  }) async {
    final temporary = File(_temporaryPath(target, tempSuffix));
    var created = false;
    try {
      await temporary.create(exclusive: true);
      created = true;
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(target.path);
      created = false;
    } finally {
      if (created) await _cleanUpAsync(temporary);
    }
  }

  static final Random _random = Random.secure();

  static String _temporaryPath(File target, String? tempSuffix) =>
      '${target.path}.tmp.$pid.${tempSuffix ?? _randomSuffix()}';

  static String _randomSuffix() =>
      List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join();

  /// 정리 실패가 원래 실패를 가리지 않게 한다 — 꽉 찬 디렉터리에서는 쓰기와
  /// 정리가 함께 실패하고, 사용자에게는 쓰기 실패가 진단으로 남아야 한다.
  static void _cleanUp(File temporary) {
    try {
      temporary.deleteSync();
    } on IOException {
      // Best-effort cleanup of temporary file.
    }
  }

  static Future<void> _cleanUpAsync(File temporary) async {
    try {
      await temporary.delete();
    } on IOException {
      // Best-effort cleanup of temporary file.
    }
  }
}
