import 'dart:convert';
import 'dart:io';

/// 액션의 인자를 NUL로 구분해 전달하며 CLI나 자식 프로세스는 실행하지 않는다.
Future<void> main() async {
  final List<String> arguments;
  try {
    arguments = parseActionArguments(
      Platform.environment['DARTOGRAPH_ARGS'] ?? '',
    );
  } on FormatException catch (error) {
    stderr.writeln('dartograph action: invalid args input: ${error.message}');
    exitCode = 64;
    return;
  }
  for (final argument in arguments) {
    stdout.add([...utf8.encode(argument), 0]);
  }
  await stdout.flush();
}

/// ASCII 공백·인용·이스케이프만 해석해 셸 확장 없이 argv 경계를 보존한다.
/// NUL은 전송 구분자이므로 인자 내용으로 허용하지 않는다.
List<String> parseActionArguments(String input) {
  if (input.contains('\u0000')) {
    throw const FormatException('NUL is not allowed in args');
  }
  final result = <String>[];
  final word = StringBuffer();
  String? quote;
  var started = false;
  var escaped = false;
  for (final character in input.split('')) {
    if (escaped) {
      word.write(character);
      escaped = false;
    } else if (character == r'\' && quote != "'") {
      escaped = true;
      started = true;
    } else if (quote != null) {
      if (character == quote) {
        quote = null;
      } else {
        word.write(character);
      }
    } else if (character == "'" || character == '"') {
      quote = character;
      started = true;
    } else if (' \t\r\n\v\f'.contains(character)) {
      if (started) {
        result.add(word.toString());
        word.clear();
        started = false;
      }
    } else {
      word.write(character);
      started = true;
    }
  }
  if (escaped) {
    throw const FormatException('dangling escape; add a character after \\');
  }
  if (quote != null) {
    throw const FormatException('unterminated quote; close the matching quote');
  }
  if (started) result.add(word.toString());
  return result;
}
