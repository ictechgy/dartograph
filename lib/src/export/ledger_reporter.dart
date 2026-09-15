import 'dart:convert';

import '../core/result_ledger.dart';

/// `history`가 지원하는 출력 형식이다.
enum HistoryFormat {
  /// 사람이 읽는 한 줄 요약이다.
  text,

  /// 자동화 소비자를 위한 결정적 JSON이다.
  json,
}

/// 검증 원장 조회 결과를 형식별로 직렬화한다.
///
/// text의 동적 값에는 dead·impact와 같은 제어문자 정책을 적용한다(C0·DEL은
/// 가시 이스케이프). 원장은 도구가 쓴 값이지만 `commit`·`inputs`에 제어문자가
/// 섞이면 진단줄 위조가 가능하므로 값의 출처를 신뢰하지 않는다.
abstract final class LedgerReporter {
  /// [format]에 맞춰 [result]를 렌더링한다.
  static String render(HistoryFormat format, LedgerReadResult result) =>
      switch (format) {
        HistoryFormat.text => _text(result),
        HistoryFormat.json => _json(result),
      };

  static Map<String, Object?> _document(LedgerReadResult result) => {
    'entries': [for (final entry in result.entries) entry.toJson()],
    'limitations': [
      if (result.isDamaged) _skippedLimitation(result.skippedLines),
    ],
    'skippedLines': result.skippedLines,
    'version': 1,
  };

  static String _json(LedgerReadResult result) =>
      '${jsonEncode(_document(result))}\n';

  static String _text(LedgerReadResult result) {
    final output = StringBuffer();
    output.writeln('history: ${result.entries.length} entr(ies)');
    for (final entry in result.entries) {
      final inputs =
          (entry.inputs.entries.toList()
                ..sort((a, b) => a.key.compareTo(b.key)))
              .map((item) => '${item.key}=${item.value}')
              .join(',');
      output.writeln(
        '${entry.recordedAt.toUtc().toIso8601String()}  '
        '${_escapeText(entry.command)}  exit=${entry.exitCode}  '
        'failed=${entry.failedItems.length}  '
        'commit=${_escapeText(entry.commit ?? '-')}  '
        'inputs=${_escapeText(inputs)}',
      );
    }
    if (result.isDamaged) {
      output.writeln(_skippedLimitation(result.skippedLines));
    }
    return output.toString();
  }

  static String _skippedLimitation(int skipped) =>
      'ledger-skipped-lines: $skipped damaged line(s) were skipped on read';

  /// text의 C0·DEL 가시 이스케이프(정상 입력은 바이트 불변).
  static String _escapeText(String value) {
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
          output.write('\\x${rune.toRadixString(16).padLeft(2, '0')}');
      }
    }
    return output.toString();
  }

  static bool _isControlRune(int rune) => rune < 0x20 || rune == 0x7f;
}
