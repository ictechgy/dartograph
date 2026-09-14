import 'dart:io';

/// dart-define 채널: 제공되지 않고 기본값도 없으므로 미충족이다.
const String corpusBaseUrl = String.fromEnvironment('RUNTIME_CORPUS_BASE_URL');

/// dart-define 채널: 기본값이 있으므로 defaulted로 판정된다.
const int corpusPort = int.fromEnvironment(
  'RUNTIME_CORPUS_PORT',
  defaultValue: 8080,
);

/// 프로세스 환경 채널: 셸 환경에 없으면 미충족이다.
String? corpusToken() => Platform.environment['RUNTIME_CORPUS_TOKEN'];

/// 전체 맵 읽기: 개별 키를 정적으로 알 수 없어 미판정으로 남는다.
Map<String, String> corpusEnvironment() => Platform.environment;

/// 계산된 키: 리터럴이 아니라 미판정으로 남는다.
String? corpusLookup(String key) => Platform.environment[key];
