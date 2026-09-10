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
    bool isLibrary = false,
    bool isTypeDeclaration = false,
    bool isAbstract = false,
    bool isEnumConstant = false,
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
    if (isLibrary && (isTypeDeclaration || isAbstract || isEnumConstant)) {
      throw ArgumentError.value(
        isLibrary,
        'isLibrary',
        'is mutually exclusive with declaration flags',
      );
    }
    if (isAbstract && !isTypeDeclaration) {
      throw ArgumentError.value(
        isAbstract,
        'isAbstract',
        'requires a type declaration',
      );
    }
    if (isEnumConstant && isTypeDeclaration) {
      throw ArgumentError.value(
        isEnumConstant,
        'isEnumConstant',
        'is mutually exclusive with a type declaration',
      );
    }
    return GraphNode._(
      id: id,
      sourceUri: sourceUri,
      line: line,
      column: column,
      synthesized: synthesized,
      isLibrary: isLibrary,
      isTypeDeclaration: isTypeDeclaration,
      isAbstract: isAbstract,
      isEnumConstant: isEnumConstant,
    );
  }

  const GraphNode._({
    required this.id,
    required this.sourceUri,
    required this.line,
    required this.column,
    required this.synthesized,
    required this.isLibrary,
    required this.isTypeDeclaration,
    required this.isAbstract,
    required this.isEnumConstant,
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

  /// 라이브러리(파일) 정점인지 나타낸다. 선언 ID 모양(`<…dart>::<이름>`)에서
  /// 종류를 유추하지 않게 한다 — 파일명에 `::`·`.dart::`가 있어도(일부 플랫폼에서
  /// 합법) 분류가 흔들리지 않는다(감사 "낮음": html `::` 파일명 오분류의 근본 해결).
  final bool isLibrary;

  /// Martin 추상도 계산에서 타입 선언의 분모에 포함되는지 나타낸다.
  final bool isTypeDeclaration;

  /// 타입 선언이 추상 클래스나 추상 인터페이스인지 나타낸다.
  final bool isAbstract;

  /// enum 상수 선언인지 나타낸다. enum이 도달 가능하면 `.values`·switch·직렬화처럼
  /// 상수를 직접 참조하지 않는 소비도 있으므로, 도달성이 이 표시로 상수를 보존한다.
  final bool isEnumConstant;

  @override
  bool operator ==(Object other) =>
      other is GraphNode &&
      id == other.id &&
      sourceUri == other.sourceUri &&
      line == other.line &&
      column == other.column &&
      synthesized == other.synthesized &&
      isLibrary == other.isLibrary &&
      isTypeDeclaration == other.isTypeDeclaration &&
      isAbstract == other.isAbstract &&
      isEnumConstant == other.isEnumConstant;

  @override
  int get hashCode => Object.hash(
    id,
    sourceUri,
    line,
    column,
    synthesized,
    isLibrary,
    isTypeDeclaration,
    isAbstract,
    isEnumConstant,
  );
}
