import 'dart:convert';
import 'dart:math';

import 'package:dartograph/src/core/path_glob.dart';
import 'package:test/test.dart';

/// PathGlob 매처의 계약이다.
///
/// 판정 의미는 예전 정규식 컴파일러와 같아야 한다. 그 컴파일러는 이 파일의
/// 오라클(`_legacyCompile`·`_legacyFullMatch`)로만 남는다 — 짧은 무작위 입력은
/// 백트래킹이 폭증하지 않아 오라클로 쓸 수 있다.
void main() {
  group('PathGlob.compile', () {
    test('matches the legacy regular expression on random input', () {
      final random = Random(20261018);
      for (var sample = 0; sample < 3000; sample++) {
        final pattern = _randomString(random, _patternAlphabet, 8);
        _expectSameMatches(
          pattern,
          () => PathGlob.compile(pattern),
          () => _legacyCompile(pattern),
          _candidatePaths(random, pattern),
        );
      }
    });

    test('keeps the legacy edge semantics', () {
      for (final (pattern, path, expected) in const [
        // 비고정 몸은 시작이나 `/` 바로 뒤에서만 시작한다.
        ('a', 'x/a', true),
        ('a', 'xa', false),
        ('a', 'a/b', true),
        ('/a', 'x/a', false),
        ('a/', 'a', false),
        ('a/', 'a/b', true),
        // `**`와 하위 경로 접미는 줄 끝 문자를 넘지 않고 `*`·`?`는 넘는다.
        ('**', 'a\nb', false),
        ('*', 'a\nb', true),
        ('?', '\n', true),
        ('?', '/', false),
        ('a', 'a/b\nc', false),
        ('a', 'x\n/a', true),
        // 부정 클래스는 `/`도 매치한다.
        ('[!a]', '/', true),
        // 클래스 안의 `\-`는 범위를 만든다(RegExp.escape가 `-`를 남겼다).
        (r'[a\-z]', 'm', true),
        (r'[a\-z]', '-', false),
        ('[]]', ']', true),
        ('[!]]', ']', false),
        ('[', '[', true),
        (r'a\*', 'a*', true),
        (r'a\*', 'ab', false),
        // 이스케이프된 끝 `/`는 디렉터리 표지가 아니라 리터럴(루트 고정)이다.
        (r'a\/', 'a/', true),
        (r'a\/', 'x/a/', false),
      ]) {
        expect(
          PathGlob.compile(pattern)!.hasMatch(path),
          expected,
          reason: '${jsonEncode(pattern)} on ${jsonEncode(path)}',
        );
      }
    });

    test('an out-of-order class range fails to compile', () {
      expect(() => PathGlob.compile('[z-a]'), throwsFormatException);
      expect(() => PathGlob.compile(r'[a\--]'), throwsFormatException);
    });

    test('repeated wildcards keep the answer on long paths', () {
      // 답이 앞쪽 배치 하나뿐인 양성이다. 백트래킹 정규식은 뒤쪽 a 배치를 모두
      // 시도하느라 수십 초를 쓴 뒤 불일치(false)로 답했다.
      final frontOnly = PathGlob.compile('${'*a' * 10}*b*')!;
      expect(frontOnly.hasMatch('${'a' * 10}b${'a' * 30}'), isTrue);
      expect(frontOnly.hasMatch('lib/${'a' * 10}b${'a' * 200}.dart'), isTrue);
      // 맞지 않는 긴 경로도 바로 끝난다. 정규식에서는 40자에 수 초가 걸렸다.
      final globstars = PathGlob.compile('${'**a' * 6}**b')!;
      expect(globstars.hasMatch('lib/${'a' * 250}.dart'), isFalse);
      expect(globstars.hasMatch('lib/${'a' * 250}b'), isTrue);
      final stars = PathGlob.compile('${'*a' * 20}*b')!;
      expect(stars.hasMatch('C${'a' * 200}'), isFalse);
      expect(stars.hasMatch('C${'a' * 200}b'), isTrue);
      final long = PathGlob.compile('${'*a' * 2000}*b')!;
      expect(long.hasMatch('lib/${'a' * 250}.dart'), isFalse);
    });
  });

  group('PathGlob.compileFullMatch', () {
    test('matches the legacy layer expression on random input', () {
      final random = Random(20261019);
      for (var sample = 0; sample < 3000; sample++) {
        final pattern = _randomString(random, _patternAlphabet, 8);
        _expectSameMatches(
          pattern,
          () => PathGlob.compileFullMatch(pattern),
          () => _legacyFullMatch(pattern),
          _candidatePaths(random, pattern),
        );
      }
    });

    test('keeps layer patterns literal outside wildcards', () {
      for (final (pattern, path, expected) in const [
        ('lib/[a].dart', 'lib/[a].dart', true),
        ('lib/[a].dart', 'lib/a.dart', false),
        (r'a\b', r'a\b', true),
        ('/x', '/x', true),
        (' a', ' a', true),
        ('a', 'a/b', false),
        ('*', 'a/b', false),
        ('**', 'a/b', true),
        ('**', 'a\nb', false),
        ('*', 'a\nb', true),
      ]) {
        expect(
          PathGlob.compileFullMatch(pattern).hasMatch(path),
          expected,
          reason: '${jsonEncode(pattern)} on ${jsonEncode(path)}',
        );
      }
    });

    test('repeated wildcards keep the answer on long candidates', () {
      final frontOnly = PathGlob.compileFullMatch('${'*a' * 10}*b*');
      expect(frontOnly.hasMatch('${'a' * 10}b${'a' * 30}'), isTrue);
      final matcher = PathGlob.compileFullMatch('${'**a' * 6}**b');
      expect(matcher.hasMatch('a' * 250), isFalse);
      expect(matcher.hasMatch('${'a' * 250}b'), isTrue);
    });
  });
}

/// 무작위 패턴에 쓰는 글자다. 와일드카드·클래스·이스케이프·줄 끝 문자와
/// 서로게이트 쌍(이모지)을 섞는다.
const _patternAlphabet = [
  'a', 'b', 'z', '/', '*', '*', '?', '[', ']', '!', '^', '-', r'\', '.', //
  '\n', '\r', '\u2028', ' ', '😀',
];

/// 무작위 경로에 쓰는 글자다.
const _pathAlphabet = [
  'a', 'b', 'z', '/', '/', '.', '-', '!', '^', ']', '[', r'\', '*', '?', //
  '\n', '\r', '\u2028', '\u2029', '\u0085', ' ', '😀',
];

String _randomString(Random random, List<String> alphabet, int maxLength) {
  final length = random.nextInt(maxLength + 1);
  return [
    for (var index = 0; index < length; index++)
      alphabet[random.nextInt(alphabet.length)],
  ].join();
}

/// 무작위 경로와, 패턴의 와일드카드를 채워 맞을 가능성이 높은 경로를 섞는다.
List<String> _candidatePaths(Random random, String pattern) => [
  for (var index = 0; index < 12; index++)
    _randomString(random, _pathAlphabet, 10),
  for (var index = 0; index < 6; index++) _filled(random, pattern),
  for (var index = 0; index < 3; index++) 'x/${_filled(random, pattern)}',
  for (var index = 0; index < 3; index++) '${_filled(random, pattern)}/y',
];

/// [pattern]의 와일드카드를 무작위 글자로 채우고 이스케이프를 푼다.
String _filled(Random random, String pattern) {
  final buffer = StringBuffer();
  for (var index = 0; index < pattern.length; index++) {
    final character = pattern[index];
    if (character == '*') {
      buffer.write(_randomString(random, _pathAlphabet, 2));
    } else if (character == '?' || character == '[') {
      buffer.write(_pathAlphabet[random.nextInt(_pathAlphabet.length)]);
    } else if (character == r'\' && index + 1 < pattern.length) {
      buffer.write(pattern[++index]);
    } else {
      buffer.write(character);
    }
  }
  return buffer.toString();
}

/// 두 컴파일러의 결과(예외·null·경로별 판정)가 같은지 본다.
void _expectSameMatches(
  String pattern,
  PathGlobMatcher? Function() compile,
  RegExp? Function() legacy,
  List<String> paths,
) {
  final reason = 'pattern ${jsonEncode(pattern)}';
  final (actual, actualError) = _attempt(compile);
  final (expected, expectedError) = _attempt(legacy);
  expect(actualError, expectedError, reason: reason);
  expect(actual == null, expected == null, reason: reason);
  if (actual == null || expected == null) return;
  for (final path in paths) {
    expect(
      actual.hasMatch(path),
      expected.hasMatch(path),
      reason: '$reason on ${jsonEncode(path)}',
    );
  }
}

/// 컴파일을 시도해 결과나 FormatException 여부를 돌려준다.
(T?, bool) _attempt<T>(T? Function() compile) {
  try {
    return (compile(), false);
  } on FormatException {
    return (null, true);
  }
}

/// 수정 전 `PathGlob.compile`을 그대로 옮긴 오라클이다.
RegExp? _legacyCompile(String pattern) {
  final trimmed = pattern.trim();
  if (trimmed.isEmpty) return null;
  var body = trimmed;
  var anchored = false;
  if (body.startsWith('/')) {
    anchored = true;
    body = body.substring(1);
  }
  final directoryOnly = _legacyEndsWithUnescapedSlash(body);
  if (directoryOnly) {
    if (body.isEmpty) return null;
    body = body.substring(0, body.length - 1);
  }
  if (body.isEmpty) return null;
  anchored = anchored || body.contains('/');
  final prefix = anchored ? '^' : r'(^|.*/)';
  final suffix = directoryOnly ? r'/.*$' : r'(/.*)?$';
  return RegExp('$prefix${_legacyGlobBody(body)}$suffix');
}

bool _legacyEndsWithUnescapedSlash(String body) {
  if (!body.endsWith('/')) return false;
  var backslashes = 0;
  for (
    var index = body.length - 2;
    index >= 0 && body[index] == r'\';
    index--
  ) {
    backslashes++;
  }
  return backslashes.isEven;
}

String _legacyGlobBody(String pattern) {
  final buffer = StringBuffer();
  var index = 0;
  while (index < pattern.length) {
    final character = pattern[index];
    if (character == r'\') {
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
      final end = _legacyClassEnd(pattern, index);
      if (end == null) {
        buffer.write(r'\[');
        index++;
      } else {
        buffer.write(_legacyCharacterClass(pattern.substring(index + 1, end)));
        index = end + 1;
      }
    } else {
      buffer.write(RegExp.escape(character));
      index++;
    }
  }
  return buffer.toString();
}

int? _legacyClassEnd(String pattern, int open) {
  var index = open + 1;
  if (index < pattern.length &&
      (pattern[index] == '!' || pattern[index] == '^')) {
    index++;
  }
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

String _legacyCharacterClass(String body) {
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
      if (character == ']' && first) {
        buffer.write(r'\]');
      } else if (character == r'\' && index + 1 == body.length) {
        buffer.write(r'\\');
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

/// 수정 전 layer_rules `_glob`을 그대로 옮긴 오라클이다.
RegExp _legacyFullMatch(String pattern) {
  final buffer = StringBuffer('^');
  for (var index = 0; index < pattern.length; index++) {
    final character = pattern[index];
    if (character == '*' &&
        index + 1 < pattern.length &&
        pattern[index + 1] == '*') {
      buffer.write('.*');
      index++;
    } else if (character == '*') {
      buffer.write('[^/]*');
    } else if (character == '?') {
      buffer.write('[^/]');
    } else {
      buffer.write(RegExp.escape(character));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}
