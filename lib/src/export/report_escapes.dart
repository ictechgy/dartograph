import 'dart:convert';

/// text·markdown·github-actions·sarif 리포터가 공유하는 출력 이스케이프다.
///
/// 정책 정본은 graph_exporter의 클래스 문서와 dead_reporter의 각 함수 주석을
/// 본다. 동적 값의 제어문자·파이프·경로 손상이 진단줄을 위조하지 못하게 한다.
abstract final class ReportEscapes {
  /// text 형식은 `path:line:col: severity: ...` 행 프로토콜이다. 동적 값의
  /// 개행·제어문자는 두 번째 진단줄 위조나 ANSI 주입이 되므로 githubEncode와
  /// 같은 집합(C0·DEL·C1, U+2028·2029, bidi 제어)을 가시 이스케이프로 바꾼다
  /// (정상 경로는 바이트 불변).
  static String escapeText(String value) =>
      _escapeControls(value, _isControlRune);

  /// [escapes]가 고른 rune만 가시 이스케이프로 바꾼다(없으면 원문 그대로).
  static String _escapeControls(String value, bool Function(int) escapes) {
    if (!value.runes.any(escapes)) return value;
    final output = StringBuffer();
    for (final rune in value.runes) {
      if (escapes(rune)) {
        _writeVisibleEscape(output, rune);
      } else {
        output.writeCharCode(rune);
      }
    }
    return output.toString();
  }

  /// 제어 rune 하나의 가시 이스케이프(`\n`·`\r`·`\t`·`\xNN`·`\u{…}`)다.
  ///
  /// 역슬래시 뒤는 항상 영문자다. 그래서 Markdown에서도 이스케이프로 읽히지
  /// 않고 글자 그대로 보인다(CommonMark는 구두점 앞 역슬래시만 소비한다).
  static void _writeVisibleEscape(StringBuffer output, int rune) {
    switch (rune) {
      case 0x0a:
        output.write(r'\n');
      case 0x0d:
        output.write(r'\r');
      case 0x09:
        output.write(r'\t');
      default:
        output.write(
          rune <= 0xff
              ? '\\x${rune.toRadixString(16).padLeft(2, '0')}'
              : '\\u{${rune.toRadixString(16)}}',
        );
    }
  }

  static bool _isControlRune(int rune) =>
      rune < 0x20 || // C0
      rune == 0x7f || // DEL
      (rune >= 0x80 && rune <= 0x9f) || // C1
      rune == 0x2028 ||
      rune == 0x2029 || // 줄·단락 분리
      (rune >= 0x202a && rune <= 0x202e) || // bidi 제어
      (rune >= 0x2066 && rune <= 0x2069); // bidi 격리

  /// Markdown 표 셀: 제어문자를 가시 이스케이프하고 파이프를 이스케이프한다.
  ///
  /// code span 안에 넣을 값의 재료다([mdCode]). span 밖 문구는 [mdText]를 쓴다.
  static String mdCell(String value) =>
      escapeText(value).replaceAll('|', r'\|');

  /// Markdown 자유 문구(limitation·detail·evidence·reason처럼 code span 밖 값)다.
  ///
  /// [mdCell]의 제어문자·파이프 처리에 더해, 저장소가 정한 문자열이 링크·
  /// 이미지·HTML·엔티티·code span·멘션으로 렌더링되지 않게 그 문법을 여는
  /// 최소 문자만 바꾼다.
  /// - 역슬래시·백틱·`<`·`&`, 그리고 `]` 바로 뒤의 `(`는 앞에 역슬래시를
  ///   붙인다. 인라인 링크·이미지는 `](`가 있어야 열리고, 참조 링크는 정의가
  ///   필요한데 리포트 줄은 고정 접두로 시작해 정의를 만들 수 없다.
  /// - 영숫자 앞 `@`에는 `&#8203;`(폭 없는 공백)을 붙인다. GitHub는 Markdown을
  ///   렌더링한 뒤 멘션을 연결하므로 `\@`나 `&#64;`로는 막지 못한다.
  ///
  /// `[`·`_`·`*` 같은 문자는 그대로 둔다. 그래서 `Platform.environment["X"]`처럼
  /// 정상 문구의 바이트는 바뀌지 않는다. `<`만은 정상 문구에도 나온다. runtime의
  /// 자리표시 `<computed>`는 HTML 태그로 읽혀 렌더링에서 사라지던 것이라
  /// `\<computed>`로 바뀌어 글자 그대로 보인다.
  static String mdText(String value) {
    final runes = value.runes.toList();
    final output = StringBuffer();
    for (var index = 0; index < runes.length; index++) {
      final rune = runes[index];
      if (_isControlRune(rune)) {
        _writeVisibleEscape(output, rune);
      } else if (_opensMarkdown(runes, index)) {
        output.write('\\${String.fromCharCode(rune)}');
      } else if (_opensMention(runes, index)) {
        output.write('@&#8203;');
      } else {
        output.writeCharCode(rune);
      }
    }
    return output.toString();
  }

  /// 역슬래시를 붙여야 하는 [mdText]의 문자인지 판정한다.
  static bool _opensMarkdown(List<int> runes, int index) =>
      switch (runes[index]) {
        0x5c || 0x60 || 0x3c || 0x26 || 0x7c => true, // \ ` < & |
        0x28 => index > 0 && runes[index - 1] == 0x5d, // `](`의 (
        _ => false,
      };

  /// GitHub 멘션(`@` + 영숫자)을 여는 `@`인지 판정한다.
  static bool _opensMention(List<int> runes, int index) =>
      runes[index] == 0x40 &&
      index + 1 < runes.length &&
      _isAsciiAlphanumeric(runes[index + 1]);

  static bool _isAsciiAlphanumeric(int rune) =>
      (rune >= 0x30 && rune <= 0x39) ||
      (rune >= 0x41 && rune <= 0x5a) ||
      (rune >= 0x61 && rune <= 0x7a);

  /// Markdown code span으로 감싼다. 내용에 백틱이 있으면 구분자를 더 긴
  /// 백틱 run으로 늘린다 — span 안에서는 `\`` 이스케이프가 literal이라 쓸 수
  /// 없고, 내용이 백틱으로 시작·끝나면 공백 패딩이 필요하다(CommonMark).
  static String mdCode(String value) {
    final cell = mdCell(value);
    final longest = _longestBacktickRun(cell);
    if (longest == 0) return '`$cell`';
    final fence = '`' * (longest + 1);
    final padded = cell.startsWith('`') || cell.endsWith('`')
        ? ' $cell '
        : cell;
    return '$fence$padded$fence';
  }

  /// [value]를 Markdown 펜스 코드 블록으로 만든다(끝 개행 포함).
  ///
  /// 실행한 자식의 stderr처럼 줄 구조를 지켜 보여 줄 원문용이다. 펜스는 내용의
  /// 가장 긴 백틱 run보다 1 길게(최소 3) 잡는다. 닫는 펜스는 여는 펜스 이상
  /// 길어야 하므로(CommonMark) 내용의 어떤 줄도 블록을 일찍 닫지 못한다. 개행·
  /// 탭은 두고 나머지 제어문자는 [escapeText]처럼 가시 이스케이프로 바꾼다.
  /// CR도 바꾼다 — CommonMark에서 CR은 줄 끝이라 펜스를 닫는 줄을 만들 수 있다.
  /// 백틱 run이 3 미만이고 제어문자가 없는 내용은 바이트가 그대로다.
  static String mdCodeBlock(String value, {String info = ''}) {
    final body = _escapeControls(
      value,
      (rune) => _isControlRune(rune) && rune != 0x0a && rune != 0x09,
    );
    final longest = _longestBacktickRun(body);
    final fence = '`' * (longest < 3 ? 3 : longest + 1);
    return '$fence$info\n$body\n$fence\n';
  }

  static int _longestBacktickRun(String value) {
    var longest = 0;
    for (final match in RegExp('`+').allMatches(value)) {
      if (match.end - match.start > longest) {
        longest = match.end - match.start;
      }
    }
    return longest;
  }

  /// source ID에서 `project:` 센티널을 벗겨 프로젝트 상대 경로를 남긴다.
  ///
  /// projectIdForPath는 상대 경로 앞에 항상 `project:` 센티널을 붙이므로,
  /// `project:x.dart`라는 합법 파일명의 ID는 `project:project:x.dart`가 되어 한 번
  /// 벗기면 원본 경로로 정확히 왕복한다 — 센티널 충돌은 없다. `package:`·`file:`
  /// 소스는 그대로 둔다.
  static String sourcePath(String source) => source.startsWith('project:')
      ? source.substring('project:'.length)
      : source;

  /// SARIF artifact uri. `Uri(path:)` 조립은 `\`를 `/`로 치환하고 `%41`을 기존
  /// 이스케이프로 해석해 경로를 조용히 손상·오귀속한다. 구분자(`/` — project ID는
  /// 항상 URL 구분자를 쓴다)로 분리해 세그먼트별로 인코딩하면 손실이 없고 정상
  /// 경로는 바이트가 불변이다.
  static String sarifUri(String source) => source.startsWith('project:')
      ? Uri(pathSegments: sourcePath(source).split('/')).toString()
      : source;

  /// GitHub workflow command 이스케이프. 스펙 최소집합(`%`, CR, LF + property의
  /// `:`·`,`)에 더해 C0·DEL·C1과 행 구조·시각 순서를 깨뜨릴 수 있는 문자
  /// (U+2028·2029 줄 분리, U+202A–202E·U+2066–2069 bidi 제어를 러너 로그·주석으로
  /// 흘리지 않는다. 기존 `%0D`·`%0A` 관례와 같은 대문자 hex 퍼센트 인코딩이고
  /// 정상 입력의 바이트는 불변이다.
  static String githubProperty(String value) =>
      githubEncode(value, property: true);

  /// 메시지 본문 이스케이프 — `:`와 `,`는 데이터로 인코딩하지 않는다.
  static String githubMessage(String value) =>
      githubEncode(value, property: false);

  /// 워크플로 명령의 UTF-8 퍼센트 인코딩 구현이다.
  static String githubEncode(String value, {required bool property}) {
    if (!value.runes.any((rune) => _githubNeedsEncoding(rune, property))) {
      return value;
    }
    final output = StringBuffer();
    for (final rune in value.runes) {
      if (!_githubNeedsEncoding(rune, property)) {
        output.writeCharCode(rune);
        continue;
      }
      for (final byte in utf8.encode(String.fromCharCode(rune))) {
        output.write(
          '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }
    }
    return output.toString();
  }

  static bool _githubNeedsEncoding(int rune, bool property) =>
      rune == 0x25 || // %
      rune < 0x20 || // C0 (CR·LF 포함)
      rune == 0x7f || // DEL
      (rune >= 0x80 && rune <= 0x9f) || // C1
      rune == 0x2028 ||
      rune == 0x2029 || // 줄 분리·단락 분리
      (rune >= 0x202a && rune <= 0x202e) || // bidi 제어
      (rune >= 0x2066 && rune <= 0x2069) || // bidi 격리
      (property && (rune == 0x3a || rune == 0x2c)); // : ,
}
