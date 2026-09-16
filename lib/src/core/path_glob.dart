/// gitignore류 경로 glob을 정규식으로 컴파일한다.
///
/// 지원 문법:
/// - `*`(슬래시 제외 임의), `**`(슬래시 포함 임의), `?`(슬래시 제외 한 글자)
/// - `[abc]`·`[a-z]`·`[!abc]`·`[^abc]` 문자 클래스(닫히지 않은 `[`는 리터럴)
/// - `\x`로 다음 글자를 리터럴로 이스케이프(`\#`·`\!`·`\?` 등)
/// - `/`로 시작하거나 중간에 `/`가 있으면 루트 고정이다. 없으면 어떤 깊이의
///   이름이든 매치한다.
/// - 끝의 `/`는 디렉터리 표지다 — 그 디렉터리 아래 경로만 매치한다.
///   이스케이프된 `\/`는 리터럴 슬래시라 표지가 아니다.
///
/// `!` 부정 같은 규칙 수준 의미는 여기서 다루지 않는다 — 호출자가 판단한다.
final class PathGlob {
  const PathGlob._();

  /// [pattern]을 컴파일한다. 빈 패턴·몸이 비는 패턴은 null이다.
  ///
  /// 반환된 정규식은 저장소 상대 POSIX 경로에 매치한다.
  static RegExp? compile(String pattern) {
    final trimmed = pattern.trim();
    if (trimmed.isEmpty) return null;
    var body = trimmed;
    var anchored = false;
    if (body.startsWith('/')) {
      anchored = true;
      body = body.substring(1);
    }
    final directoryOnly = _endsWithUnescapedSlash(body);
    if (directoryOnly) {
      if (body.isEmpty) return null;
      body = body.substring(0, body.length - 1);
    }
    if (body.isEmpty) return null;
    // 선행 `/`는 루트 고정을 뜻하므로 제거한 뒤에도 고정 여부에 반영한다.
    anchored = anchored || body.contains('/');
    final prefix = anchored ? '^' : r'(^|.*/)';
    final suffix = directoryOnly ? r'/.*$' : r'(/.*)?$';
    return RegExp('$prefix${_globBody(body)}$suffix');
  }

  /// 끝의 `/`가 디렉터리 표지인지 본다 — 이스케이프된 `\/`는 리터럴 슬래시다.
  static bool _endsWithUnescapedSlash(String body) {
    if (!body.endsWith('/')) return false;
    var backslashes = 0;
    for (var index = body.length - 2;
        index >= 0 && body[index] == r'\';
        index--) {
      backslashes++;
    }
    return backslashes.isEven;
  }

  static String _globBody(String pattern) {
    final buffer = StringBuffer();
    var index = 0;
    while (index < pattern.length) {
      final character = pattern[index];
      if (character == r'\') {
        // `\x`는 x를 글자 그대로 쓴다. 끝의 외로운 `\`도 리터럴이다.
        if (index + 1 < pattern.length) {
          buffer.write(RegExp.escape(pattern[index + 1]));
          index += 2;
        } else {
          buffer.write(r'\\');
          index++;
        }
      } else if (character == '*' &&
          index + 1 < pattern.length &&
          pattern[index + 1] == '*') {
        buffer.write('.*');
        index += 2;
      } else if (character == '*') {
        buffer.write('[^/]*');
        index++;
      } else if (character == '?') {
        buffer.write('[^/]');
        index++;
      } else if (character == '[') {
        final end = _classEnd(pattern, index);
        if (end == null) {
          // 닫히지 않은 `[`는 리터럴이다.
          buffer.write(r'\[');
          index++;
        } else {
          buffer.write(_characterClass(pattern.substring(index + 1, end)));
          index = end + 1;
        }
      } else {
        buffer.write(RegExp.escape(character));
        index++;
      }
    }
    return buffer.toString();
  }

  /// [open] 위치의 `[`에서 시작하는 문자 클래스의 닫는 `]` 인덱스다.
  ///
  /// `[]` 바로 뒤의 `]`는 클래스의 첫 글자로 취급하는 POSIX 관례를 따른다.
  static int? _classEnd(String pattern, int open) {
    var index = open + 1;
    if (index < pattern.length &&
        (pattern[index] == '!' || pattern[index] == '^')) {
      index++;
    }
    // 첫 위치의 `]`는 리터럴 멤버다.
    if (index < pattern.length && pattern[index] == ']') index++;
    while (index < pattern.length) {
      if (pattern[index] == r'\') {
        index += 2;
        continue;
      }
      if (pattern[index] == ']') return index;
      index++;
    }
    return null;
  }

  /// `[`와 `]` 사이의 내용을 정규식 문자 클래스로 변환한다.
  static String _characterClass(String body) {
    final buffer = StringBuffer('[');
    var index = 0;
    if (index < body.length && (body[index] == '!' || body[index] == '^')) {
      buffer.write('^');
      index++;
    }
    var first = true;
    while (index < body.length) {
      final character = body[index];
      if (character == r'\' && index + 1 < body.length) {
        buffer.write(RegExp.escape(body[index + 1]));
        index += 2;
      } else {
        // 첫 위치의 리터럴 `]`는 이스케이프해 정규식이 닫히지 않게 한다.
        if (character == ']' && first) {
          buffer.write(r'\]');
        } else {
          buffer.write(character);
        }
        index++;
      }
      first = false;
    }
    buffer.write(']');
    return buffer.toString();
  }
}
