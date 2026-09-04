/// Dart 의존성 그래프의 선언 또는 파일이다.
///
/// `part` 선언의 정체성은 호스트 라이브러리에 속하지만 진단은 part를 가리켜야 하므로
/// 정체성과 소스 근거를 분리한다.
final class GraphNode {
  /// 선택적인 소스 근거를 가진 정점을 만든다.
  factory GraphNode({
    required String id,
    String? sourceUri,
    int? line,
    int? column,
    bool synthesized = false,
  }) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (line != null && line < 1) {
      throw ArgumentError.value(line, 'line', 'must be 1-based');
    }
    if (column != null && column < 1) {
      throw ArgumentError.value(column, 'column', 'must be 1-based');
    }
    return GraphNode._(
      id: id,
      sourceUri: sourceUri,
      line: line,
      column: column,
      synthesized: synthesized,
    );
  }

  const GraphNode._({
    required this.id,
    required this.sourceUri,
    required this.line,
    required this.column,
    required this.synthesized,
  });

  /// 라이브러리 정체성과 선언 경로에서 만든 안정적인 그래프 ID다.
  final String id;

  /// 이 정점을 보고할 때 근거로 쓰는 소스 URI다.
  final String? sourceUri;

  /// 알 수 있을 때의 1부터 시작하는 소스 줄이다.
  final int? line;

  /// 알 수 있을 때의 1부터 시작하는 소스 열이다.
  final int? column;

  /// 알려진 생성 코드에서 온 정점인지 나타낸다.
  final bool synthesized;

  @override
  bool operator ==(Object other) =>
      other is GraphNode &&
      id == other.id &&
      sourceUri == other.sourceUri &&
      line == other.line &&
      column == other.column &&
      synthesized == other.synthesized;

  @override
  int get hashCode => Object.hash(id, sourceUri, line, column, synthesized);
}
