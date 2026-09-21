/// 원시 기록을 재집계할 때 적용한 사용량 판별 규칙의 식별자다.
const usageDetectionVersion = 'command-position-v1';

/// Bash 도구 입력에서 dartograph 실제 실행을 보수적으로 찾는다.
///
/// 완전한 shell parser가 아니므로 `eval`이나 동적으로 조립된 명령은
/// 해석하지 않는다. 실행한 명령의 오염 여부를 재현 가능하게 기록하는
/// 보조 판별기이며, 경로·인용 문자열·grep 텍스트를 실행으로 세지 않는다.
bool invokesDartograph(String command) {
  if (_substitutionInvokes(command)) return true;
  for (final segment in _segments(command)) {
    if (_segmentInvokes(segment)) return true;
  }
  return false;
}

List<List<String>> _segments(String command) {
  final segments = <List<String>>[];
  var current = <String>[];
  var word = StringBuffer();
  var started = false;

  void flushWord() {
    if (!started) return;
    current.add(word.toString());
    word = StringBuffer();
    started = false;
  }

  void flushSegment() {
    flushWord();
    if (current.isNotEmpty) segments.add(current);
    current = <String>[];
  }

  var i = 0;
  while (i < command.length) {
    final c = command[i];
    if (c == r'\') {
      started = true;
      if (i + 1 < command.length) {
        word.write(command[i + 1]);
        i += 2;
      } else {
        i++;
      }
      continue;
    }
    if (c == "'") {
      started = true;
      i++;
      while (i < command.length && command[i] != "'") {
        word.write(command[i++]);
      }
      if (i < command.length) i++;
      continue;
    }
    if (c == '"') {
      started = true;
      i++;
      while (i < command.length && command[i] != '"') {
        if (command[i] == r'\' && i + 1 < command.length) {
          word.write(command[i + 1]);
          i += 2;
        } else {
          word.write(command[i++]);
        }
      }
      if (i < command.length) i++;
      continue;
    }
    // 명령 치환·backtick 내부 구분자는 바깥 pipeline이 아니라 중첩 명령에 속한다.
    if (c == r'$' && i + 1 < command.length && command[i + 1] == '(') {
      started = true;
      final end = _substitutionEnd(command, i);
      word.write(command.substring(i, end));
      i = end;
      continue;
    }
    if (c == '`') {
      started = true;
      var end = i + 1;
      while (end < command.length) {
        if (command[end] == r'\') {
          end += 2;
          continue;
        }
        if (command[end] == '`') {
          end++;
          break;
        }
        end++;
      }
      final safeEnd = end > command.length ? command.length : end;
      word.write(command.substring(i, safeEnd));
      i = safeEnd;
      continue;
    }
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      if (c == '\n') {
        flushSegment();
      } else {
        flushWord();
      }
      i++;
      continue;
    }
    if (c == '#' && !started) {
      while (i < command.length && command[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == ';' || c == '|' || c == '&') {
      flushSegment();
      if (i + 1 < command.length && command[i + 1] == c) {
        i += 2;
      } else {
        i++;
      }
      continue;
    }
    started = true;
    word.write(c);
    i++;
  }
  flushSegment();
  return segments;
}

bool _segmentInvokes(List<String> tokens) {
  var i = 0;
  while (i < tokens.length) {
    final token = tokens[i];
    if (_isAssignment(token)) {
      i++;
      continue;
    }
    final commandName = _basename(token);
    if (_isInspectionCommand(commandName)) return false;
    if (_isWrapper(commandName)) {
      if (commandName == 'command' &&
          i + 1 < tokens.length &&
          (tokens[i + 1] == '-v' || tokens[i + 1] == '-V')) {
        return false;
      }
      i++;
      i = _skipWrapperValues(tokens, i, commandName);
      while (i < tokens.length && tokens[i].startsWith('-')) {
        i++;
      }
      continue;
    }
    return _isDartographCommand(tokens, i);
  }
  return false;
}

bool _isDartographCommand(List<String> tokens, int index) {
  final token = tokens[index];
  if (_basename(token) == 'dartograph') return true;
  if (_basename(token) != 'dart') return false;

  var i = index + 1;
  while (i < tokens.length && tokens[i].startsWith('-')) {
    i++;
  }
  if (i >= tokens.length) return false;
  if (tokens[i] == 'run') {
    i++;
    while (i < tokens.length && tokens[i].startsWith('-')) {
      i++;
    }
    return i < tokens.length && _isDartographEntrypoint(tokens[i]);
  }
  if (tokens[i] != 'pub' || i + 2 >= tokens.length) return false;
  if (tokens[i + 1] != 'global' || tokens[i + 2] != 'run') return false;
  i += 3;
  while (i < tokens.length && tokens[i].startsWith('-')) {
    i++;
  }
  return i < tokens.length && _isDartographEntrypoint(tokens[i]);
}

bool _isDartographEntrypoint(String token) =>
    token == 'dartograph' || token == 'dartograph:dartograph';

bool _isWrapper(String token) =>
    token == 'env' ||
    token == 'command' ||
    token == 'exec' ||
    token == 'time' ||
    token == 'timeout' ||
    token == 'sudo' ||
    token == 'nice' ||
    token == 'nohup' ||
    token == 'setsid';

bool _isInspectionCommand(String token) =>
    token == 'which' || token == 'type' || token == 'hash';

bool _isAssignment(String token) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(token);

int _skipWrapperValues(List<String> tokens, int index, String wrapper) {
  if (wrapper == 'timeout') {
    // timeout DURATION COMMAND; 흔한 값 인자를 받는 옵션도 건너뛴다.
    var i = index;
    while (i < tokens.length) {
      final token = tokens[i];
      if (token == '--') return i + 1;
      if (token.startsWith('-')) {
        i += token == '-k' || token == '--kill-after' ? 2 : 1;
        continue;
      }
      return i + 1;
    }
    return i;
  }
  if (wrapper == 'nice') {
    var i = index;
    while (i < tokens.length && tokens[i].startsWith('-')) {
      if (tokens[i] == '-n' || tokens[i] == '--adjustment') {
        i += 2;
      } else {
        i++;
      }
    }
    return i;
  }
  if (wrapper == 'env') {
    var i = index;
    while (i < tokens.length) {
      final token = tokens[i];
      if (token == '--') return i + 1;
      if (token == '-u' ||
          token == '--unset' ||
          token == '-C' ||
          token == '--chdir') {
        i += 2;
        continue;
      }
      if (token.startsWith('-')) {
        i++;
        continue;
      }
      if (_isAssignment(token)) {
        i++;
        continue;
      }
      return i;
    }
    return i;
  }
  return index;
}

String _basename(String token) {
  final slash = token.lastIndexOf('/');
  return slash < 0 ? token : token.substring(slash + 1);
}

bool _substitutionInvokes(String command) {
  var i = 0;
  var singleQuoted = false;
  var doubleQuoted = false;
  var tokenStart = true;
  while (i < command.length) {
    final c = command[i];
    if (c == r'\' && !singleQuoted) {
      i += 2;
      tokenStart = false;
      continue;
    }
    if (c == "'" && !doubleQuoted) {
      singleQuoted = !singleQuoted;
      tokenStart = false;
      i++;
      continue;
    }
    if (c == '"' && !singleQuoted) {
      doubleQuoted = !doubleQuoted;
      tokenStart = false;
      i++;
      continue;
    }
    if (singleQuoted) {
      i++;
      continue;
    }
    if (!doubleQuoted && tokenStart && c == '#') {
      while (i < command.length && command[i] != '\n') {
        i++;
      }
      continue;
    }
    if (!doubleQuoted && (c == ' ' || c == '\t' || c == '\r' || c == '\n')) {
      tokenStart = true;
      i++;
      continue;
    }
    if (!doubleQuoted && (c == ';' || c == '|' || c == '&')) {
      tokenStart = true;
      i += i + 1 < command.length && command[i + 1] == c ? 2 : 1;
      continue;
    }
    if (!singleQuoted &&
        c == r'$' &&
        i + 1 < command.length &&
        command[i + 1] == '(') {
      final end = _substitutionEnd(command, i);
      final closed =
          end > i && end <= command.length && command[end - 1] == ')';
      if (closed && invokesDartograph(command.substring(i + 2, end - 1))) {
        return true;
      }
      i = end;
      tokenStart = false;
      continue;
    }
    if (!singleQuoted && c == '`') {
      var end = i + 1;
      while (end < command.length) {
        if (command[end] == r'\') {
          end += 2;
          continue;
        }
        if (command[end] == '`') break;
        end++;
      }
      if (end < command.length &&
          invokesDartograph(command.substring(i + 1, end))) {
        return true;
      }
      i = end + 1;
      tokenStart = false;
      continue;
    }
    tokenStart = false;
    i++;
  }
  return false;
}

int _substitutionEnd(String command, int start) {
  var depth = 0;
  var singleQuoted = false;
  var doubleQuoted = false;
  var i = start;
  while (i < command.length) {
    final c = command[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    if (!doubleQuoted && c == "'") {
      singleQuoted = !singleQuoted;
      i++;
      continue;
    }
    if (!singleQuoted && c == '"') {
      doubleQuoted = !doubleQuoted;
      i++;
      continue;
    }
    if (singleQuoted || doubleQuoted) {
      i++;
      continue;
    }
    if (c == r'$' && i + 1 < command.length && command[i + 1] == '(') {
      depth++;
      i += 2;
      continue;
    }
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i + 1;
    }
    i++;
  }
  return command.length;
}
