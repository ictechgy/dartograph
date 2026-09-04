import 'dart:io';

/// 해석된 사실을 영속 저장하는 교체 가능한 캐시 경계다.
///
/// 캐시 구현은 그래프 의미를 바꾸면 안 된다. 캐시가 없거나 꺼졌을 때 analyzer 작업만
/// 늘어날 뿐 사실은 달라지지 않아야 한다.
abstract interface class FactCache {
  /// analyzer 신원과 내용으로 만든 [key]의 직렬화된 사실을 읽는다.
  Future<String?> read(String key);

  /// analyzer 신원과 내용으로 만든 [key]에 직렬화된 [payload]를 저장한다.
  Future<void> write(String key, String payload);
}

/// 디렉터리 하나에 사실 payload를 원자적으로 저장하는 기본 캐시다.
final class FileFactCache implements FactCache {
  /// 캐시 파일을 둘 [directory]를 지정한다.
  const FileFactCache(this.directory);

  /// 분석 대상 밖의 OS 사용자 캐시에 만든 전용 디렉터리다.
  final Directory directory;

  @override
  Future<String?> read(String key) async {
    final file = _file(key);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String key, String payload) async {
    final file = _file(key);
    await directory.create(recursive: true);
    final temporary = File('${file.path}.tmp.$pid');
    try {
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  File _file(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'must be a SHA-256 hex digest');
    }
    return File('${directory.path}${Platform.pathSeparator}$key.json');
  }
}
