import 'package:yaml/yaml.dart';

import '../core/config_source.dart';

/// 프로젝트 설정이 잘못돼 분석을 시작하지 못했다는 실패다.
///
/// 대상은 `dartograph.yaml`의 값, 분석할 패키지의 `pubspec.yaml`, 그리고
/// `--workspace` 선언이다. 이 실패는 일반 [FormatException]이었다. 그래서 CLI가
/// 원인을 알 수 없는 색인 실패(`unable to index the package`)로만 알렸고, 명령마다
/// 따로 둔 형식 오류 분기(`impact`의 변경 목록, `schema`·`routes`의 제어문자)로
/// 흘러 원인을 반대로 짚기도 했다.
///
/// [message]는 고칠 파일과 키를 짚는 문장이다(`invalid dartograph.yaml:
/// entry_points file does not exist: bin/cli.dart`). 저장소가 쓴 설정 값(경로·glob)을
/// 담을 수 있으므로 출력하는 쪽이 제어문자를 이스케이프한다.
///
/// [FormatException]을 상속해 기존 수습(종료 코드 2)과 호출자의 타입 검사를 그대로
/// 탄다([InputRejectedException]과 같은 방식). 형식 오류 분기를 따로 둔 CLI 명령은
/// 이 타입을 먼저 잡는다.
final class ProjectConfigurationException extends FormatException {
  /// 고칠 설정을 짚는 문장 [message]의 실패를 만든다.
  const ProjectConfigurationException(super.message);
}

/// 설정 파일 [file]을 해석하는 [read]를 실행한다. [read]가 낸 형식 오류는 [file]을
/// 짚는 [ProjectConfigurationException]으로 바꾼다.
///
/// [file]은 루트 기준 표시 이름이다(`dartograph.yaml`, `packages/a/pubspec.yaml`).
/// 호스트 절대 경로를 넘기지 않는다.
///
/// - 읽기 경계의 거부([InputRejectedException])는 설정 내용이 아니라 입력 자체의
///   문제라 그대로 던진다. CLI가 원인대로 따로 진단한다.
/// - 이미 [ProjectConfigurationException]이면 그대로 던진다. 안쪽에서 다른 파일을
///   짚은 실패가 바깥 파일 이름으로 덮이지 않는다.
/// - YAML 구문 오류에는 줄과 열을 붙인다. 파서 문구(`Expected node content.`)만으로는
///   어디를 고칠지 알 수 없다.
/// - UTF-8이 아닌 파일([Utf8DecodeException])도 그 파일을 짚는다. 다른 읽기 실패
///   (부재·권한)는 [FileSystemException] 그대로다.
T readProjectConfiguration<T>(String file, T Function() read) {
  try {
    return read();
  } on InputRejectedException {
    rethrow;
  } on ProjectConfigurationException {
    rethrow;
  } on FormatException catch (exception) {
    throw ProjectConfigurationException(
      'invalid $file: ${_describeFormatException(exception)}',
    );
  } on Utf8DecodeException {
    throw ProjectConfigurationException(
      'invalid $file: the file is not valid UTF-8',
    );
  }
}

/// 형식 오류 [exception]의 문구다. YAML 구문 오류면 1부터 센 줄·열을 붙인다.
///
/// [FormatException.message]만 쓴다. `toString()`과 `source`는 원문 전체를 담을 수
/// 있다.
String _describeFormatException(FormatException exception) {
  final start = exception is YamlException ? exception.span?.start : null;
  if (start == null) return exception.message;
  return '${exception.message} '
      '(line ${start.line + 1}, column ${start.column + 1})';
}
