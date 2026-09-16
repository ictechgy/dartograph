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
  static String escapeText(String value) {
    if (!value.runes.any(_isControlRune)) return value;
    final output = StringBuffer();
    for (final rune in value.runes) {
      if (!_isControlRune(rune)) {
        output.writeCharCode(rune);
        continue;
      }
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
    return output.toString();
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
  static String mdCell(String value) =>
      escapeText(value).replaceAll('|', r'\|');

  /// Markdown code span으로 감싼다. 내용에 백틱이 있으면 구분자를 더 긴
  /// 백틱 run으로 늘린다 — span 안에서는 `\`` 이스케이프가 literal이라 쓸 수
  /// 없고, 내용이 백틱으로 시작·끝나면 공백 패딩이 필요하다(CommonMark).
  static String mdCode(String value) {
    final cell = mdCell(value);
    var longest = 0;
    for (final match in RegExp('`+').allMatches(cell)) {
      if (match.end - match.start > longest) {
        longest = match.end - match.start;
      }
    }
    if (longest == 0) return '`$cell`';
    final fence = '`' * (longest + 1);
    final padded = cell.startsWith('`') || cell.endsWith('`')
        ? ' $cell '
        : cell;
    return '$fence$padded$fence';
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
