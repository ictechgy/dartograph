import 'dart:convert';

/// 큰 JSON 문서를 조각으로 [StringSink]에 넘기는 버퍼다.
///
/// 그래프 문서를 한 문자열로 만들면 원소 Map 목록·단일 문자열·인코딩 사본이
/// 출력 크기의 몇 배를 잡는다. 반대로 원소마다 sink를 부르면 stdout 같은
/// IOSink의 쓰기 호출과 인코딩 버퍼가 원소 수만큼 는다. 그래서 원소를
/// [chunkLength]자 남짓까지 모았다가 넘긴다. 조각은 원소 경계에서만 넘기므로
/// 서러게이트 쌍이 두 조각으로 갈리지 않는다.
final class JsonChunkWriter {
  /// [sink]로 조각을 넘기는 버퍼를 만든다.
  JsonChunkWriter(this._sink);

  /// 한 번에 넘기는 조각의 목표 길이(UTF-16 코드 단위)다.
  static const chunkLength = 1 << 16;

  final StringSink _sink;
  final _buffer = StringBuffer();

  /// [text]를 그대로 덧붙인다. JSON 구문 조각(괄호·키)에 쓴다.
  void write(String text) {
    _buffer.write(text);
    if (_buffer.length >= chunkLength) flush();
  }

  /// [values]를 하나씩 `jsonEncode`해 `,`로 잇는다. 괄호는 쓰지 않는다.
  ///
  /// 전체 목록을 한 번에 `jsonEncode`한 배열 본문과 바이트가 같다.
  void writeElements(Iterable<Object> values) {
    var separator = '';
    for (final value in values) {
      _buffer.write(separator);
      write(jsonEncode(value));
      separator = ',';
    }
  }

  /// 모은 조각을 sink로 넘긴다. 문서를 다 쓴 뒤 반드시 부른다.
  void flush() {
    if (_buffer.isEmpty) return;
    _sink.write(_buffer.toString());
    _buffer.clear();
  }
}
