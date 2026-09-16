/// 중복 탐지의 입력이 되는 정규화 토큰 열이다.
///
/// 하나의 최상위 선언(클래스·함수·변수 선언, annotation·주석 제외)의 토큰을
/// 구조 버킷 해시로 바꾼 것이다. 식별자·리터럴은 이름/값과 무관하게 같은
/// 버킷이므로 이름만 바꾼 복사본도 같은 코드 열을 만든다.
final class TokenSegment {
  /// 정규화된 토큰 열을 만든다. [codes]와 [lines]는 같은 길이여야 한다.
  const TokenSegment({
    required this.source,
    required this.codes,
    required this.lines,
  });

  /// 이 세그먼트의 `project:` source ID다.
  final String source;

  /// 토큰마다의 정규화 코드다(FNV-1a 해시).
  final List<int> codes;

  /// [codes]와 같은 길이의 각 토큰 1-based 시작 행이다.
  final List<int> lines;
}
