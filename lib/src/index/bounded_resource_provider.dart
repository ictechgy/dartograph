import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' show Context;

import '../core/config_source.dart';

/// 분석 입력 하나에서 읽을 수 있는 최대 바이트 수다.
///
/// 정상 Dart 소스는 가장 큰 생성 파일도 수 MB다(pub 캐시에서 본 생성 API
/// 클라이언트가 5.5 MB, 아이콘 표가 3.5 MB). 64 MiB는 그 열 배를 넘어 정상
/// 입력을 거부하지 않는다. 그러면서도 링크나 절대 경로 import로 끌어온 가상
/// 파일과 큰 호스트 파일이 메모리를 소진하기 전에 멈춘다. 가상 파일은
/// `/proc/self/pagemap`처럼 길이를 0으로 보고하면서 끝없이 읽히는 파일이다.
/// analyzer 읽기 경계([BoundedResourceProvider]), 직접 읽는 곳
/// ([readAnalysisInputBytesSync]: 구문 스캐너·증분 해시·Flutter 출처 확인),
/// 캐시 키가 같은 상한을 쓴다.
const analysisReadLimit = 64 * _mebibyte;

const _mebibyte = 1024 * 1024;

/// 길이를 모르는 파일을 나눠 읽는 단위다.
const _readChunkSize = 64 * 1024;

/// [limit]바이트 상한을 넘은 분석 입력의 거부다. 문구에 경로를 담지 않는다.
InputTooLargeException analysisInputTooLarge([int limit = analysisReadLimit]) =>
    InputTooLargeException(
      limit % _mebibyte == 0
          ? 'analysis input exceeds the ${limit ~/ _mebibyte} MiB read limit'
          : 'analysis input exceeds the $limit-byte read limit',
    );

/// 분석 입력 [file]을 analyzer 읽기 경계([BoundedResourceProvider])와 같은
/// 규칙으로 읽는다.
///
/// analyzer를 거치지 않고 분석 입력을 직접 읽는 곳(구문 스캐너·증분 해시·
/// Flutter 출처 확인)이 쓴다. 그래야 같은 입력이 경로마다 다르게 다뤄지지
/// 않는다.
/// - 링크를 따라간 대상이 장치·FIFO·소켓이면 열기 전에
///   [NonRegularFileException]이다.
/// - [analysisReadLimit]을 넘으면 읽기 전에(길이를 0으로 보고하는 파일은 상한까지
///   읽은 뒤) [InputTooLargeException]이다.
/// - 부재·디렉터리·권한 실패는 [io.File.readAsBytesSync]와 같은
///   [io.FileSystemException]이다.
Uint8List readAnalysisInputBytesSync(io.File file) {
  // false(부재·디렉터리)면 아래 전체 읽기가 원래 실패를 그대로 낸다.
  if (!regularFileExistsSync(file)) return file.readAsBytesSync();
  final length = file.lengthSync();
  if (length > analysisReadLimit) throw analysisInputTooLarge();
  return length > 0
      ? file.readAsBytesSync()
      : readUnknownLengthSync(file, analysisReadLimit);
}

/// [readAnalysisInputBytesSync]로 읽은 분석 입력의 UTF-8 문자열이다.
///
/// 디코드 실패는 [io.File.readAsStringSync]와 같은 [io.FileSystemException]이다.
/// 호출자의 기존 '읽을 수 없는 파일' 수습이 그대로 적용된다.
String readAnalysisInputSync(io.File file) {
  final bytes = readAnalysisInputBytesSync(file);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw io.FileSystemException(
      "Failed to decode data using encoding 'utf-8'",
      file.path,
    );
  }
}

/// 길이를 0으로 보고하는 정규 [file]을 [limit]바이트까지 나눠 읽는다.
///
/// dart:io의 전체 읽기는 길이가 0이면 EOF까지 읽는다. 빈 파일은 바로 끝나지만
/// 가상 파일은 끝없이 읽힌다. [limit]을 넘으면 [analysisInputTooLarge]를 던진다.
/// 열기·읽기 실패는 dart:io의 [io.FileSystemException]이다.
Uint8List readUnknownLengthSync(io.File file, int limit) {
  final handle = file.openSync();
  try {
    final bytes = BytesBuilder(copy: false);
    while (bytes.length <= limit) {
      final chunk = handle.readSync(_readChunkSize);
      if (chunk.isEmpty) return bytes.takeBytes();
      bytes.add(chunk);
    }
    throw analysisInputTooLarge(limit);
  } finally {
    handle.closeSync();
  }
}

/// analyzer가 파일 내용을 읽는 바로 그 지점에서 비정규 입력과 상한 초과를
/// 거부하는 [ResourceProvider]다.
///
/// 분석 전 사전 열거는 analyzer가 실제로 여는 파일을 다 덮지 못한다. import와
/// part는 숨김 디렉터리 안 파일, 열거가 건너뛰는 디렉터리(`build` 등) 안 파일,
/// 루트 밖 절대 경로(`/dev/zero`)를 가리킬 수 있다. 읽을 수 없는 디렉터리
/// 하나가 열거를 끊으면 남은 링크도 검사하지 못한다. 그래서 analyzer가 쓰는
/// 파일 시스템을 감싸, 내용을 읽는 모든 호출에서 확인한다.
///
/// - 링크를 따라간 대상이 존재하지만 정규 파일이 아니면(장치·FIFO·소켓) 열지
///   않는다. FIFO는 여는 순간 영구 대기하고 장치는 EOF 없이 읽힌다.
/// - 정규 파일은 [readLimit]까지만 읽는다. 길이를 0으로 보고하는 파일은 나눠
///   읽다가 상한에서 멈춘다.
///
/// 거부는 analyzer의 [FileSystemException]으로 알린다. analyzer는 대개 이를
/// 읽을 수 없는 파일로 다루고 계속 진행하므로, 멈추거나 메모리를 소진하지
/// 않는다. 대신 첫 거부를 기록해 두고 호출자가 [throwIfRejected]로 분석 실패
/// (종료 코드 2)로 바꾼다. 그대로 두면 결과가 '파일 없음'으로 조용히 달라진다.
///
/// 목록·경로·쓰기·감시는 [PhysicalResourceProvider]에 그대로 맡긴다. analyzer가
/// 돌려받은 자원을 다시 탐색해도 경계를 벗어나지 않도록, 이 provider가 돌려주는
/// 파일·폴더는 모두 감싼 자원이다.
final class BoundedResourceProvider implements ResourceProvider {
  /// 실제 파일 시스템을 감싼다. [readLimit]은 테스트가 줄일 때만 지정한다.
  BoundedResourceProvider({this.readLimit = analysisReadLimit});

  /// 파일 하나에서 읽을 수 있는 최대 바이트 수다.
  final int readLimit;

  final ResourceProvider _base = PhysicalResourceProvider.INSTANCE;

  /// 이 provider가 처음 거부한 읽기다. 없으면 null이다.
  InputRejectedException? _rejection;

  /// 이 provider가 거부한 읽기가 있었으면 첫 거부를 던진다.
  ///
  /// analyzer는 컨텍스트를 만들 때와 해석을 요청받았을 때만 파일을 읽는다
  /// (백그라운드 분석에 파일을 더하지 않는다). 그래서 그 두 호출 뒤에 부르면
  /// 결과를 쓰기 전에 모든 거부가 드러난다.
  void throwIfRejected() {
    final rejection = _rejection;
    if (rejection != null) throw rejection;
  }

  @override
  Context get pathContext => _base.pathContext;

  @override
  File getFile(String path) => _BoundedFile(this, _base.getFile(path));

  @override
  Folder getFolder(String path) => _BoundedFolder(this, _base.getFolder(path));

  @override
  Link getLink(String path) => _base.getLink(path);

  @override
  Resource getResource(String path) => _wrap(_base.getResource(path));

  @override
  Folder? getStateLocation(String pluginId) {
    final folder = _base.getStateLocation(pluginId);
    return folder == null ? null : _BoundedFolder(this, folder);
  }

  /// [resource]를 이 provider의 자원으로 감싼다.
  Resource _wrap(Resource resource) => switch (resource) {
    File() => _BoundedFile(this, resource),
    Folder() => _BoundedFolder(this, resource),
    _ => resource,
  };

  /// 경계를 지난 [file]의 바이트다.
  Uint8List _readBytes(File file) =>
      _admits(file) ? file.readAsBytesSync() : _readUnknownLength(file.path);

  /// 경계를 지난 [file]의 UTF-8 문자열이다.
  String _readString(File file) {
    if (_admits(file)) return file.readAsStringSync();
    final bytes = _readUnknownLength(file.path);
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // 감싼 구현(dart:io readAsStringSync)과 같은 실패 모양이다.
      throw FileSystemException(
        file.path,
        "Failed to decode data using encoding 'utf-8'",
      );
    }
  }

  /// [file]을 감싼 구현으로 그대로 읽어도 되는지 확인한다.
  ///
  /// 부재·디렉터리는 true다 — 감싼 구현이 analyzer가 원래 받던 실패를 낸다.
  /// 길이를 아는 정규 파일도 true다. dart:io는 그 길이만큼만 읽는다. 길이를 0으로
  /// 보고하는 정규 파일은 false다. 빈 파일이거나, 읽어 봐야 크기를 아는 가상
  /// 파일이라 상한까지 나눠 읽어야 한다. Windows에는 그런 가상 파일이 없어
  /// 감싼 구현의 장치 이름(CON·NUL 등) 검사를 그대로 거치게 맡긴다. 비정규
  /// 입력과 상한 초과는 거부를 기록하고 analyzer의 실패를 던진다.
  bool _admits(File file) {
    final path = file.path;
    final bool regular;
    try {
      regular = regularFileExistsSync(io.File(path));
    } on NonRegularFileException catch (rejection) {
      throw _reject(rejection, path);
    }
    if (!regular) return true;
    final length = file.lengthSync;
    if (length > readLimit) {
      throw _reject(analysisInputTooLarge(readLimit), path);
    }
    return length > 0 || io.Platform.isWindows;
  }

  /// 길이를 0으로 보고하는 정규 파일 [path]를 상한까지 읽는다.
  Uint8List _readUnknownLength(String path) {
    try {
      return readUnknownLengthSync(io.File(path), readLimit);
    } on InputTooLargeException catch (rejection) {
      throw _reject(rejection, path);
    } on io.FileSystemException catch (exception) {
      throw FileSystemException(path, exception.message);
    }
  }

  /// 첫 거부를 기록하고 analyzer에 던질 실패를 만든다.
  FileSystemException _reject(InputRejectedException rejection, String path) {
    _rejection ??= rejection;
    return FileSystemException(path, rejection.message);
  }
}

/// [BoundedResourceProvider]의 파일이다. 내용 읽기만 경계를 지나고 나머지는
/// 감싼 파일에 맡긴다.
final class _BoundedFile implements File {
  _BoundedFile(this._provider, this._file);

  final BoundedResourceProvider _provider;
  final File _file;

  @override
  bool get exists => _file.exists;

  @override
  int get hashCode => path.hashCode;

  @override
  int get lengthSync => _file.lengthSync;

  @override
  int get modificationStamp => _file.modificationStamp;

  @override
  Folder get parent => _BoundedFolder(_provider, _file.parent);

  @override
  String get path => _file.path;

  @override
  ResourceProvider get provider => _provider;

  @override
  String get shortName => _file.shortName;

  @override
  bool operator ==(Object other) => other is _BoundedFile && other.path == path;

  @override
  File copyTo(Folder parentFolder) {
    // 감싼 파일의 copyTo는 경계 없이 읽는다. 같은 절차를 경계 읽기로 밟는다.
    parentFolder.create();
    final destination = parentFolder.getFile(shortName);
    destination.writeAsBytesSync(readAsBytesSync());
    return destination;
  }

  @override
  void delete() => _file.delete();

  @override
  bool isOrContains(String path) => _file.isOrContains(path);

  @override
  Uint8List readAsBytesSync() => _provider._readBytes(_file);

  @override
  String readAsStringSync() => _provider._readString(_file);

  @override
  File renameSync(String newPath) =>
      _BoundedFile(_provider, _file.renameSync(newPath));

  @override
  Resource resolveSymbolicLinksSync() =>
      _provider._wrap(_file.resolveSymbolicLinksSync());

  @override
  String toString() => _file.toString();

  @override
  Uri toUri() => _file.toUri();

  @override
  ResourceWatcher watch() => _file.watch();

  @override
  void writeAsBytesSync(List<int> bytes) => _file.writeAsBytesSync(bytes);

  @override
  void writeAsStringSync(String content) => _file.writeAsStringSync(content);
}

/// [BoundedResourceProvider]의 폴더다. 돌려주는 자원을 모두 감싸 analyzer의
/// 탐색이 경계 밖 파일 객체를 얻지 못하게 한다.
final class _BoundedFolder implements Folder {
  _BoundedFolder(this._provider, this._folder);

  final BoundedResourceProvider _provider;
  final Folder _folder;

  @override
  bool get exists => _folder.exists;

  @override
  int get hashCode => path.hashCode;

  @override
  bool get isRoot => _folder.isRoot;

  @override
  Folder get parent => _BoundedFolder(_provider, _folder.parent);

  @override
  String get path => _folder.path;

  @override
  ResourceProvider get provider => _provider;

  @override
  String get shortName => _folder.shortName;

  @override
  bool operator ==(Object other) =>
      other is _BoundedFolder && other.path == path;

  @override
  String canonicalizePath(String path) => _folder.canonicalizePath(path);

  @override
  bool contains(String path) => _folder.contains(path);

  @override
  Folder copyTo(Folder parentFolder) {
    // 감싼 폴더의 copyTo는 자식 파일을 경계 없이 읽는다.
    final destination = parentFolder.getFolder(shortName);
    destination.create();
    for (final child in getChildren()) {
      child.copyTo(destination);
    }
    return destination;
  }

  @override
  void create() => _folder.create();

  @override
  void delete() => _folder.delete();

  @override
  Resource getChild(String relPath) =>
      _provider._wrap(_folder.getChild(relPath));

  @Deprecated('Use getFile instead.')
  @override
  File getChildAssumingFile(String relPath) => getFile(relPath);

  @Deprecated('Use getFolder instead.')
  @override
  Folder getChildAssumingFolder(String relPath) => getFolder(relPath);

  @override
  List<Resource> getChildren() => [
    for (final child in _folder.getChildren()) _provider._wrap(child),
  ];

  @override
  File getFile(String relPath) =>
      _BoundedFile(_provider, _folder.getFile(relPath));

  @override
  Folder getFolder(String relPath) =>
      _BoundedFolder(_provider, _folder.getFolder(relPath));

  @override
  bool isOrContains(String path) => _folder.isOrContains(path);

  @override
  Resource resolveSymbolicLinksSync() =>
      _provider._wrap(_folder.resolveSymbolicLinksSync());

  @override
  String toString() => _folder.toString();

  @override
  Uri toUri() => _folder.toUri();

  @override
  ResourceWatcher watch() => _folder.watch();
}
