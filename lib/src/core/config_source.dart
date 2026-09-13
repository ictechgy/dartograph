import 'dart:io';

/// 저장소가 제공하는 YAML 설정 파일의 읽기 상한이다. batch 요청 파일과 같은
/// 1 MiB 선례를 따른다 — 정상 pubspec·dartograph.yaml·layers.yaml은 이보다
/// 훨씬 작다.
const configurationSizeLimit = 1024 * 1024;

/// 설정 파일을 읽되 상한을 넘기면 [FormatException]으로 실패한다.
///
/// 호스트 저장소의 과도한 설정이 YAML 파서의 메모리·재귀 비용으로 이어지지
/// 않게 하는 fail-closed 경계다. 진단은 경로를 담지 않는 정적 문구다 —
/// 호출자의 기존 FormatException 수습(정적 메시지, 종료 코드 2)과 같은
/// 계약을 따른다. 부모 디렉터리 부재 등 읽기 실패는 그대로 전파된다.
String readConfigurationSync(File file) {
  if (file.lengthSync() > configurationSizeLimit) {
    throw const FormatException(
      'configuration file exceeds the ${configurationSizeLimit ~/ 1024} KiB limit',
    );
  }
  return file.readAsStringSync();
}

/// [readConfigurationSync]의 비동기 형태다.
Future<String> readConfiguration(File file) async {
  if (await file.length() > configurationSizeLimit) {
    throw const FormatException(
      'configuration file exceeds the ${configurationSizeLimit ~/ 1024} KiB limit',
    );
  }
  return file.readAsString();
}
