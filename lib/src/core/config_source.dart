import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 저장소가 제공하는 YAML 설정 파일의 읽기 상한이다. batch 요청 파일과 같은
/// 1 MiB 선례를 따른다 — 정상 pubspec·dartograph.yaml·layers.yaml은 이보다
/// 훨씬 작다.
const configurationSizeLimit = 1024 * 1024;

/// 정규 파일이 아닌 입력(장치·FIFO·소켓)을 거부할 때의 진단이다.
///
/// 경로를 담지 않는 정적 문구다. 크기 상한 진단과 같이 [FormatException]으로
/// 던져, 호출자의 기존 수습(정적 메시지, 종료 코드 2)을 그대로 탄다.
const nonRegularFileMessage =
    'input is not a regular file (device, FIFO, or socket)';

/// 경계 읽기가 한 번에 요청하는 바이트 수다. 상한까지 이 단위로 나눠 읽어 작은
/// 파일에 상한 크기의 버퍼를 잡지 않는다.
const _readChunkSize = 64 * 1024;

/// 설정 파일을 읽되 정규 파일이 아니거나 상한을 넘기면 [FormatException]으로
/// 실패한다.
///
/// 호스트 저장소의 과도한 설정이 YAML 파서의 메모리·재귀 비용으로 이어지지
/// 않게 하는 fail-closed 경계다. 진단은 경로를 담지 않는 정적 문구다 —
/// 호출자의 기존 FormatException 수습(정적 메시지, 종료 코드 2)과 같은
/// 계약을 따른다. 부모 디렉터리 부재 등 읽기 실패는 그대로 전파된다.
/// 경계의 세부는 [readBoundedFileSync]다.
String readConfigurationSync(File file) => readBoundedFileSync(
  file,
  configurationSizeLimit,
  tooLargeMessage: _configurationTooLarge,
);

/// [readConfigurationSync]의 비동기 형태다.
Future<String> readConfiguration(File file) => readBoundedFile(
  file,
  configurationSizeLimit,
  tooLargeMessage: _configurationTooLarge,
);

const _configurationTooLarge =
    'configuration file exceeds the ${configurationSizeLimit ~/ 1024} KiB limit';

/// 링크를 따라간 [file]이 정규 파일이면 true, 없거나 디렉터리면 false다.
///
/// 존재하지만 정규 파일이 아니면(문자·블록 장치, FIFO, 소켓) 열기 전에
/// [nonRegularFileMessage]의 [FormatException]으로 실패한다. dart:io는 문자
/// 장치를 notFound 종류로 보면서 `existsSync`는 true로 답하고 길이를 0으로
/// 보고한다. 그래서 길이 상한을 통과한 뒤 EOF 없이 읽혀 메모리를 채우거나
/// (`/dev/zero`), 쓰는 쪽이 없는 FIFO에서 영구 대기한다. 저장소는 이런 대상을
/// 가리키는 심볼릭 링크를 커밋할 수 있다.
bool regularFileExistsSync(File file) {
  final type = FileSystemEntity.typeSync(file.path);
  if (type == FileSystemEntityType.file) return true;
  // existsSync는 디렉터리·끊어진 링크·부재가 아닌 모든 항목에 true다.
  if (type != FileSystemEntityType.directory && file.existsSync()) {
    throw const FormatException(nonRegularFileMessage);
  }
  return false;
}

/// [regularFileExistsSync]의 비동기 형태다.
Future<bool> regularFileExists(File file) async {
  final type = await FileSystemEntity.type(file.path);
  if (type == FileSystemEntityType.file) return true;
  if (type != FileSystemEntityType.directory && await file.exists()) {
    throw const FormatException(nonRegularFileMessage);
  }
  return false;
}

/// 정규 파일 [file]을 [limit] 바이트까지만 읽어 UTF-8 문자열로 돌려준다.
///
/// 장치·FIFO·소켓은 열기 전에 거부한다([regularFileExistsSync]). 읽기도
/// `limit + 1` 바이트에 이르면 멈추고 [tooLargeMessage]의 [FormatException]을
/// 던진다 — 길이를 0으로 보고하는 입력이나 검사 뒤에 커진 파일도 상한을 넘겨
/// 읽히지 않는다. 부재·디렉터리·권한 문제와 UTF-8 디코드 실패는
/// [File.readAsStringSync]와 같은 [FileSystemException]이다.
String readBoundedFileSync(
  File file,
  int limit, {
  required String tooLargeMessage,
}) {
  // false(부재·디렉터리)면 아래 openSync가 기존과 같은 예외를 던진다.
  regularFileExistsSync(file);
  final handle = file.openSync();
  try {
    final bytes = BytesBuilder(copy: false);
    while (bytes.length <= limit) {
      final chunk = handle.readSync(_readChunkSize);
      if (chunk.isEmpty) break;
      bytes.add(chunk);
    }
    if (bytes.length > limit) throw FormatException(tooLargeMessage);
    return _decodeUtf8(bytes.takeBytes(), file);
  } finally {
    handle.closeSync();
  }
}

/// [readBoundedFileSync]의 비동기 형태다.
Future<String> readBoundedFile(
  File file,
  int limit, {
  required String tooLargeMessage,
}) async {
  await regularFileExists(file);
  final handle = await file.open();
  try {
    final bytes = BytesBuilder(copy: false);
    while (bytes.length <= limit) {
      final chunk = await handle.read(_readChunkSize);
      if (chunk.isEmpty) break;
      bytes.add(chunk);
    }
    if (bytes.length > limit) throw FormatException(tooLargeMessage);
    return _decodeUtf8(bytes.takeBytes(), file);
  } finally {
    await handle.close();
  }
}

/// [File.readAsStringSync]와 같은 실패 형태로 디코드한다. 호출자는 디코드
/// 실패를 설정 오류가 아니라 읽기 실패([FileSystemException])로 진단한다.
String _decodeUtf8(Uint8List bytes, File file) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw FileSystemException(
      "Failed to decode data using encoding 'utf-8'",
      file.path,
    );
  }
}
