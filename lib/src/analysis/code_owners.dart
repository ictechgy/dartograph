import '../core/path_glob.dart';

/// CODEOWNERS 파일을 파싱해 경로의 소유자를 찾는다.
///
/// 이 모듈은 파일을 읽지 않는다 — 호출자가 내용을 넘긴다(분석 층은 소스를
/// 직접 읽지 않는다).
///
/// 지원하는 것(gitignore류 문법 + GitLab식 `!` 부정):
/// - `#`로 시작하는 주석 줄과 빈 줄은 무시한다. 줄 끝 주석은 지원하지 않는다.
///   `\#`으로 이스케이프하면 `#`로 시작하는 패턴도 쓸 수 있다.
/// - 한 줄: `패턴 소유자...` (공백 구분). 소유자가 없으면 그 패턴은 소유권을
///   비우는 규칙이 된다.
/// - 마지막으로 일치하는 규칙이 이긴다(GitHub과 같은 순서 규칙).
/// - 패턴: `*`(슬래시 제외 임의), `**`(슬래시 포함 임의), `?`(슬래시 제외 한
///   글자), `[abc]`·`[a-z]`·`[!abc]` 문자 클래스, `\x`로 다음 글자 이스케이프.
/// - `/`로 시작하거나 중간에 `/`가 있으면 저장소 루트에 고정한다. 없으면 어떤
///   깊이에서든 이름이 맞으면 매치한다.
/// - `/`로 끝나면 디렉터리 규칙이라 그 디렉터리 아래 경로만 매치한다.
/// - `!`로 시작하는 패턴은 부정 규칙이다(GitLab 확장 — GitHub CODEOWNERS는
///   `!`를 지원하지 않는다). 소유자를 갖지 않으며, 마지막 일치 규칙이
///   부정이면 그 경로는 소유자가 없다(이전 규칙으로 되돌아가지 않는다).
final class CodeOwners {
  /// 파싱한 규칙을 파일 순서대로 보존한다.
  const CodeOwners(this.rules);

  /// 파일에 나온 순서의 규칙이다.
  final List<CodeOwnersRule> rules;

  /// 내용을 파싱한다. 규칙이 하나도 없으면 빈 원장이다(오류가 아니다).
  static CodeOwners parse(String contents) {
    final rules = <CodeOwnersRule>[];
    for (final raw in contents.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(RegExp(r'\s+'));
      final pattern = parts.first;
      final owners = parts.skip(1).toList();
      final rule = CodeOwnersRule.maybe(pattern, owners);
      if (rule != null) rules.add(rule);
    }
    return CodeOwners(rules);
  }

  /// [path](저장소 상대 POSIX 경로)의 소유자다. 일치하는 규칙이 없으면 빈 목록이다.
  ///
  /// 소유자가 빈 규칙이나 부정(`!`) 규칙이 일치하면 빈 목록을 돌려준다 —
  /// "이 경로의 소유권을 비운다"는 뜻이라 앞선 규칙의 소유자를 이어 붙이지
  /// 않는다.
  List<String> ownersOf(String path) {
    for (final rule in rules.reversed) {
      if (rule.matches(path)) return rule.owners;
    }
    return const [];
  }
}

/// CODEOWNERS 규칙 한 줄이다.
final class CodeOwnersRule {
  /// 패턴과 소유자를 담는다. [matcher]는 [pattern]을 컴파일한 것이다.
  const CodeOwnersRule._(this.pattern, this.owners, this.matcher);

  /// 원문 패턴이다(보고에 쓴다).
  final String pattern;

  /// 소유자 토큰 목록이다(`@user`, `@org/team`, 이메일). 부정 규칙은 항상 비어 있다.
  final List<String> owners;

  /// 컴파일된 패턴이다. 항상 non-null이다([maybe]가 null 매처를 거른다).
  final RegExp? matcher;

  /// [pattern]을 컴파일한다. 빈 패턴·루트 전용 `/`·몸이 비는 부정 패턴은
  /// 규칙이 될 수 없어 null이다. 부정(`!`) 규칙은 소유자를 갖지 않는다.
  static CodeOwnersRule? maybe(String pattern, List<String> owners) {
    final matcher = _compile(pattern);
    if (matcher == null) return null;
    final negated = pattern.trim().startsWith('!');
    return CodeOwnersRule._(
      pattern,
      List.unmodifiable(negated ? const <String>[] : owners),
      matcher,
    );
  }

  /// [path]가 이 규칙에 매치하는지 본다.
  bool matches(String path) => matcher!.hasMatch(path);

  static RegExp? _compile(String pattern) {
    final trimmed = pattern.trim();
    if (trimmed.isEmpty) return null;
    var body = trimmed;
    // `!` 부정 규칙이다. 이스케이프된 `\!`는 글자 그대로의 `!`다.
    if (body.startsWith('!')) {
      body = body.substring(1);
      if (body.isEmpty) return null;
    }
    return PathGlob.compile(body);
  }
}
