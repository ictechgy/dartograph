import 'dart:typed_data';

/// gitignore류 경로 glob을 백트래킹 없는 매처로 컴파일한다.
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
///
/// glob은 분석 대상 저장소의 설정(dartograph.yaml·CODEOWNERS·layers.yaml)에서
/// 온다. 예전에는 Dart RegExp(백트래킹 엔진)로 컴파일해 `**a**a…**b` 같은 패턴
/// 하나가 매치마다 경로 길이의 다항식 시간을 써 분석을 멈췄다(ReDoS). 깊이
/// 되돌아가야 하는 경로에서는 수십 초 뒤 맞는 경로도 불일치로 답했다.
/// [PathGlobMatcher]는 경로를 한 번 훑어 최악 비용이 O(토큰 수 × 경로 길이)다.
///
/// 판정은 예전 정규식과 같다 — 몸 앞에 `^`(루트 고정) 또는 `(^|.*/)`, 뒤에
/// `(/.*)?$` 또는 디렉터리 표지의 `/.*$`를 붙이고 `**`→`.*`, `*`→`[^/]*`,
/// `?`→`[^/]`로 바꾼 식이다. 그 식의 세부도 계약으로 유지한다.
/// - `**`와 접미의 하위 경로(`/` 뒤)는 줄 끝 문자(`\n`·`\r`·U+2028·U+2029)를
///   넘지 않는다(`.`의 의미). `*`·`?`는 줄 끝 문자도 매치한다.
/// - 부정 클래스(`[!a]`)는 `/`와 줄 끝 문자도 매치한다. gitignore와 다르지만
///   바꾸면 기존 설정의 판정이 달라지므로 유지한다.
/// - 클래스 안의 `\-`는 리터럴이 아니라 날 `-`처럼 범위를 만든다(RegExp.escape가
///   `-`를 이스케이프하지 않았다). 역순 범위(`[z-a]`)는 [FormatException]이다.
/// - 코드 유닛(UTF-16) 단위로 비교한다 — `?` 하나는 서로게이트 쌍의 반쪽이다.
final class PathGlob {
  const PathGlob._();

  /// [pattern]을 컴파일한다. 빈 패턴·몸이 비는 패턴은 null이다.
  ///
  /// 반환된 매처는 저장소 상대 POSIX 경로에 매치한다. 역순 범위 클래스는
  /// [FormatException]이다.
  static PathGlobMatcher? compile(String pattern) {
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
    final tokens = _TokenBuilder();
    _addGlobBody(tokens, body, pattern);
    return tokens.build(
      anchored ? _Start.origin : _Start.segment,
      directoryOnly ? _End.directory : _End.subtree,
    );
  }

  /// 레이어 규칙(`layers.yaml`의 `match`) 문법으로 [pattern]을 컴파일한다.
  ///
  /// 문자열 전체에 고정해 매치한다. `**`·`*`·`?`만 와일드카드이고 나머지
  /// 글자(`[`·`\`·`/` 포함)는 모두 리터럴이다 — 트림·디렉터리 표지·이스케이프도
  /// 없다. 정점 ID와 sourceUri에 쓰는 기존 레이어 문법을 그대로 지킨다.
  static PathGlobMatcher compileFullMatch(String pattern) {
    final tokens = _TokenBuilder();
    var index = 0;
    while (index < pattern.length) {
      final unit = pattern.codeUnitAt(index);
      if (unit == _asterisk &&
          index + 1 < pattern.length &&
          pattern.codeUnitAt(index + 1) == _asterisk) {
        tokens.wildcard(_TokenKind.globstar);
        index += 2;
      } else if (unit == _asterisk) {
        tokens.wildcard(_TokenKind.star);
        index++;
      } else if (unit == _question) {
        tokens.anyButSlash();
        index++;
      } else {
        tokens.literal(unit);
        index++;
      }
    }
    return tokens.build(_Start.origin, _End.exact);
  }

  /// 끝의 `/`가 디렉터리 표지인지 본다 — 이스케이프된 `\/`는 리터럴 슬래시다.
  static bool _endsWithUnescapedSlash(String body) {
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

  /// gitignore류 몸 [body]를 토큰으로 바꾼다. [pattern]은 오류에 싣는 원문이다.
  static void _addGlobBody(_TokenBuilder tokens, String body, String pattern) {
    var index = 0;
    while (index < body.length) {
      final unit = body.codeUnitAt(index);
      if (unit == _backslash) {
        // `\x`는 x를 글자 그대로 쓴다. 끝의 외로운 `\`도 리터럴이다.
        if (index + 1 < body.length) {
          tokens.literal(body.codeUnitAt(index + 1));
          index += 2;
        } else {
          tokens.literal(_backslash);
          index++;
        }
      } else if (unit == _asterisk &&
          index + 1 < body.length &&
          body.codeUnitAt(index + 1) == _asterisk) {
        tokens.wildcard(_TokenKind.globstar);
        index += 2;
      } else if (unit == _asterisk) {
        tokens.wildcard(_TokenKind.star);
        index++;
      } else if (unit == _question) {
        tokens.anyButSlash();
        index++;
      } else if (unit == _openBracket) {
        final end = _classEnd(body, index);
        if (end == null) {
          // 닫히지 않은 `[`는 리터럴이다.
          tokens.literal(_openBracket);
          index++;
        } else {
          tokens.characterClass(
            _CharacterClass.parse(body.substring(index + 1, end), pattern),
          );
          index = end + 1;
        }
      } else {
        tokens.literal(unit);
        index++;
      }
    }
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
}

/// 컴파일된 경로 glob이다. [hasMatch]로 경로 하나를 판정한다.
///
/// 상태 k는 "앞의 토큰 k개를 맞췄다"는 뜻이다. 경로의 코드 유닛마다 가능한
/// 상태 집합을 한 번씩 진행하므로(NFA 시뮬레이션) 되돌아가는 일이 없다. 집합은
/// 늘 오름차순이고 중복이 없다 — 상태는 제자리(`*`·`**`)나 다음 상태로만
/// 움직이고 빈 매치 폐포는 연속 구간이라 정렬을 유지한 채 이어 붙일 수 있다.
final class PathGlobMatcher {
  PathGlobMatcher._(
    this._kinds,
    this._units,
    this._classes,
    this._start,
    this._end,
  ) : _closureEnds = _closureEndsOf(_kinds),
      _states = Int32List(_kinds.length + 1),
      _nextStates = Int32List(_kinds.length + 1);

  /// 토큰 종류다. 상태 k에서 다음에 맞출 토큰이 `_kinds[k]`다.
  final List<_TokenKind> _kinds;

  /// 리터럴 토큰의 코드 유닛 또는 클래스 토큰의 [_classes] 인덱스다.
  final Int32List _units;

  /// 문자 클래스 토큰의 집합이다.
  final List<_CharacterClass> _classes;

  /// 몸이 시작할 수 있는 위치다.
  final _Start _start;

  /// 몸이 끝난 위치에서 받아들일 접미다.
  final _End _end;

  /// 상태 k에서 빈 문자열로 닿는 마지막 상태다(연속 와일드카드를 건넌다).
  final Int32List _closureEnds;

  // 상태 집합 버퍼다. 매치마다 할당하지 않으려고 매처에 둔다 — [hasMatch]는
  // 동기이고 사용자 코드를 부르지 않아 같은 isolate 안에서 겹쳐 실행되지 않는다.
  final Int32List _states;
  final Int32List _nextStates;

  /// [path] 전체가 glob에 맞는지 본다(예전 `RegExp.hasMatch`와 같은 판정).
  bool hasMatch(String path) {
    final accept = _kinds.length;
    final length = path.length;
    final segmentStarts = _start == _Start.segment;
    var states = _states;
    var nextStates = _nextStates;
    var count = _seed(states);
    var lastLineBreak = _unknownLineBreak;
    var position = 0;
    while (true) {
      // 몸을 다 맞췄으면 접미를 본다 — 경로 끝(`$`)이거나, 디렉터리·하위 경로
      // 접미면 `/` 뒤에 줄 끝 문자가 없는 하위 경로(`/.*$`)여야 한다.
      if (states[count - 1] == accept) {
        if (position == length) {
          if (_end != _End.directory) return true;
        } else if (_end != _End.exact && path.codeUnitAt(position) == _slash) {
          if (lastLineBreak == _unknownLineBreak) {
            lastLineBreak = _lastLineBreakOf(path);
          }
          if (lastLineBreak < position) return true;
        }
      }
      if (position == length) return false;
      final unit = path.codeUnitAt(position);
      // `/` 다음 위치는 비고정 몸이 새로 시작할 수 있는 자리다(`(^|.*/)`).
      var nextCount = segmentStarts && unit == _slash ? _seed(nextStates) : 0;
      for (var index = 0; index < count; index++) {
        final state = states[index];
        if (state == accept || !_accepts(state, unit)) continue;
        final target = _kinds[state].isWildcard ? state : state + 1;
        final last = nextCount == 0 ? -1 : nextStates[nextCount - 1];
        final end = _closureEnds[target];
        for (
          var next = target > last ? target : last + 1;
          next <= end;
          next++
        ) {
          nextStates[nextCount++] = next;
        }
      }
      position++;
      if (nextCount == 0) {
        // 살아 있는 상태가 없다 — 고정 패턴은 실패이고, 비고정 패턴은 다음
        // `/` 뒤에서 다시 시작한다.
        if (!segmentStarts) return false;
        final slash = path.indexOf('/', position);
        if (slash < 0) return false;
        position = slash + 1;
        nextCount = _seed(nextStates);
      }
      final previous = states;
      states = nextStates;
      nextStates = previous;
      count = nextCount;
    }
  }

  /// 상태 0과 그 빈 매치 폐포를 [states] 앞에 쓰고 개수를 돌려준다.
  int _seed(Int32List states) {
    final end = _closureEnds[0];
    for (var state = 0; state <= end; state++) {
      states[state] = state;
    }
    return end + 1;
  }

  /// 상태 [state]의 토큰이 코드 유닛 [unit]을 소비할 수 있는지 본다.
  bool _accepts(int state, int unit) => switch (_kinds[state]) {
    _TokenKind.literal => _units[state] == unit,
    _TokenKind.anyButSlash || _TokenKind.star => unit != _slash,
    _TokenKind.characterClass => _classes[_units[state]].contains(unit),
    _TokenKind.globstar => !_isLineBreak(unit),
  };

  /// 상태마다 빈 문자열로 닿는 마지막 상태를 뒤에서부터 계산한다.
  static Int32List _closureEndsOf(List<_TokenKind> kinds) {
    final ends = Int32List(kinds.length + 1);
    ends[kinds.length] = kinds.length;
    for (var state = kinds.length - 1; state >= 0; state--) {
      ends[state] = kinds[state].isWildcard ? ends[state + 1] : state;
    }
    return ends;
  }

  /// [path]의 마지막 줄 끝 문자 위치다. 없으면 -1이다.
  static int _lastLineBreakOf(String path) {
    for (var index = path.length - 1; index >= 0; index--) {
      if (_isLineBreak(path.codeUnitAt(index))) return index;
    }
    return -1;
  }

  /// 정규식 `.`가 매치하지 않는 줄 끝 문자인지 본다.
  static bool _isLineBreak(int unit) =>
      unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029;
}

/// 토큰을 모아 [PathGlobMatcher]를 만든다.
final class _TokenBuilder {
  final List<_TokenKind> _kinds = [];
  final List<int> _units = [];
  final List<_CharacterClass> _classes = [];

  /// 코드 유닛 [unit] 하나와 같아야 하는 토큰이다.
  void literal(int unit) {
    _kinds.add(_TokenKind.literal);
    _units.add(unit);
  }

  /// `?` 토큰이다.
  void anyButSlash() {
    _kinds.add(_TokenKind.anyButSlash);
    _units.add(0);
  }

  /// 문자 클래스 토큰이다.
  void characterClass(_CharacterClass value) {
    _kinds.add(_TokenKind.characterClass);
    _units.add(_classes.length);
    _classes.add(value);
  }

  /// `*`·`**` 토큰이다. 같은 와일드카드가 바로 이어지면 하나로 접는다.
  ///
  /// `.*.*`와 `.*`는 같은 언어라 판정이 바뀌지 않는다. 접으면 연속한 와일드카드가
  /// 많아도 빈 매치 폐포가 토큰 두 개를 넘지 않는다.
  void wildcard(_TokenKind kind) {
    if (_kinds.isNotEmpty && _kinds.last == kind) return;
    _kinds.add(kind);
    _units.add(0);
  }

  PathGlobMatcher build(_Start start, _End end) => PathGlobMatcher._(
    List.unmodifiable(_kinds),
    Int32List.fromList(_units),
    List.unmodifiable(_classes),
    start,
    end,
  );
}

/// glob 토큰 종류다.
enum _TokenKind {
  /// 코드 유닛 하나와 같아야 한다.
  literal,

  /// `?`: `/`가 아닌 코드 유닛 하나.
  anyButSlash,

  /// `[...]`: 클래스에 드는 코드 유닛 하나.
  characterClass,

  /// `*`: `/`가 아닌 코드 유닛 0개 이상.
  star,

  /// `**`: 줄 끝 문자가 아닌 코드 유닛 0개 이상(`/` 포함).
  globstar;

  /// 0개 이상을 소비하는 토큰인지 나타낸다.
  bool get isWildcard => this == star || this == globstar;
}

/// 몸이 시작할 수 있는 위치다.
enum _Start {
  /// 경로의 시작에서만(`^`).
  origin,

  /// 경로의 시작 또는 `/` 바로 뒤(`(^|.*/)`).
  segment,
}

/// 몸이 끝난 위치에서 받아들이는 접미다.
enum _End {
  /// 경로의 끝에서만(`$`).
  exact,

  /// 경로의 끝 또는 `/` 뒤 하위 경로(`(/.*)?$`).
  subtree,

  /// `/` 뒤 하위 경로만(`/.*$`, 디렉터리 표지).
  directory,
}

/// `[`와 `]` 사이를 해석한 문자 클래스다. 코드 유닛 범위의 합집합이고 부정이면
/// 그 여집합이다.
final class _CharacterClass {
  const _CharacterClass._(this._negated, this._bounds);

  /// 클래스 몸 [body]를 해석한다. [pattern]은 오류에 싣는 원문이다.
  ///
  /// 예전 구현이 만든 정규식 클래스와 같은 집합이다. 원자는 `\x`의 x 또는 날
  /// 글자이고, 두 원자 사이의 날 `-`가 범위다. RegExp.escape는 `-`를 이스케이프하지
  /// 않았으므로 `\-`도 날 `-`로 센다. 역순 범위는 정규식 컴파일처럼
  /// [FormatException]이다.
  factory _CharacterClass.parse(String body, String pattern) {
    var index = 0;
    var negated = false;
    if (index < body.length && (body[index] == '!' || body[index] == '^')) {
      negated = true;
      index++;
    }
    final atoms = <int>[];
    final rangeDashes = <bool>[];
    while (index < body.length) {
      final unit = body.codeUnitAt(index);
      if (unit == _backslash && index + 1 < body.length) {
        final escaped = body.codeUnitAt(index + 1);
        atoms.add(escaped);
        rangeDashes.add(escaped == _dash);
        index += 2;
      } else {
        // 첫 위치의 `]`와 말미의 외로운 `\`도 여기서 리터럴 원자가 된다.
        atoms.add(unit);
        rangeDashes.add(unit == _dash);
        index++;
      }
    }
    final bounds = <int>[];
    var atom = 0;
    while (atom < atoms.length) {
      final low = atoms[atom];
      if (atom + 2 < atoms.length && rangeDashes[atom + 1]) {
        final high = atoms[atom + 2];
        if (low > high) {
          throw FormatException(
            'Range out of order in character class',
            pattern,
          );
        }
        bounds
          ..add(low)
          ..add(high);
        atom += 3;
      } else {
        bounds
          ..add(low)
          ..add(low);
        atom++;
      }
    }
    return _CharacterClass._(negated, Int32List.fromList(bounds));
  }

  final bool _negated;

  /// `[low0, high0, low1, high1, …]` 닫힌 범위 목록이다.
  final Int32List _bounds;

  /// [unit]이 클래스에 드는지 본다.
  bool contains(int unit) {
    for (var index = 0; index < _bounds.length; index += 2) {
      if (unit >= _bounds[index] && unit <= _bounds[index + 1]) {
        return !_negated;
      }
    }
    return _negated;
  }
}

/// [PathGlobMatcher.hasMatch]가 아직 줄 끝 문자 위치를 찾지 않았다는 표지다.
const _unknownLineBreak = -2;

const _slash = 0x2F;
const _backslash = 0x5C;
const _asterisk = 0x2A;
const _question = 0x3F;
const _openBracket = 0x5B;
const _dash = 0x2D;
