import 'dart:io';

import 'package:path/path.dart' as p;

/// 인덱스 순회가 건너뛰는 디렉터리 이름이다 — analyzer 그래프와 구문 bridge
/// 스캐너가 같은 목록을 쓴다. 한쪽만 바뀌면 두 표면의 스캔 범위가 어긋난다.
const indexExcludedDirectories = {'.dart_tool', '.git', 'build'};

/// [root]에서 조상으로 올라가며 가장 가까운 `.dart_tool/package_config.json`을
/// 돌려준다 — pub 워크스페이스 멤버는 자체 설정을 두지 않고 workspace 루트의
/// 설정을 공유한다. 이 탐색은 `package:package_config`의 발견 규칙과 같아서
/// analyzer·pub이 실제로 쓰는 파일과 같은 대상을 가리킨다.
///
/// 멤버십 검사(`resolution: workspace` 선언)는 하지 않는다 — 패키지 해석은
/// 선언이 아니라 가장 가까운 package_config가 수행하는 것이 toolchain 계약이라
/// `dart analyze`·`dart test`가 이미 이 파일로 해석하는 패키지에 대해 별도의
/// "config 없음" 판정을 내리면 오히려 허위 limitation이 된다. 찾지 못하면
/// null이다.
File? nearestPackageConfigFile(String root) {
  for (var directory = Directory(root); ; directory = directory.parent) {
    final file = File(
      p.join(directory.path, '.dart_tool', 'package_config.json'),
    );
    if (file.existsSync()) return file;
    final parent = directory.parent;
    if (p.equals(parent.path, directory.path)) return null;
  }
}

/// [path]가 [root] 자체이거나 그 아래인지 플랫폼 구분자에 맞춰 확인한다.
bool isPathWithinRoot(String path, String root, {p.Context? context}) {
  final paths = context ?? p.context;
  final absolutePath = paths.normalize(paths.absolute(path));
  final absoluteRoot = paths.normalize(paths.absolute(root));
  return paths.equals(absolutePath, absoluteRoot) ||
      paths.isWithin(absoluteRoot, absolutePath);
}

/// [directory] 아래의 파일을 심볼릭 링크까지 따라가며 돌려준다.
///
/// `followLinks: false` 목록에서 심볼릭 링크는 `Link`로 나와 `File`·`Directory`
/// 분기에 걸리지 않는다. 그런데 analyzer는 링크 경로를 그대로 분석 대상에
/// 넣으므로, 링크를 빠뜨리면 링크된 소스가 그래프에는 있고 캐시 키에는 없어
/// 대상을 수정해도 낡은 사실이 재사용된다.
///
/// [boundary]·[linkEscapes]가 주어지면 링크의 실제 대상이 [boundary]를 벗어날
/// 때 `displayBase + boundary 상대 경로`를 [linkEscapes]에 기록한다. 링크는
/// 계속 따라간다 — 루트 밖 대상도 analyzer가 해석하는 입력이므로 차단하면
/// 스캔 공백이 생긴다. 기록은 "저장소 콘텐츠가 루트 밖 파일을 분석 입력으로
/// 끌어왔다"는 사실을 보고서에 남기기 위한 것이다.
Iterable<File> indexProjectFiles(
  Directory directory, {
  bool skipHiddenDirectories = false,
  String? boundary,
  String displayBase = '',
  Set<String>? linkEscapes,
}) => _projectFilesIn(
  directory,
  <String>{},
  skipHiddenDirectories: skipHiddenDirectories,
  boundary: boundary,
  displayBase: displayBase,
  linkEscapes: linkEscapes,
);

/// [visitedLinkTargets]는 이미 따라간 디렉터리 링크의 실제 경로다. 링크 순환에서
/// 무한 재귀하지 않도록 같은 대상은 한 번만 순회한다. 링크 자체의 경로로 재귀해
/// analyzer가 사용하는 경로와 같은 모양을 유지한다.
Iterable<File> _projectFilesIn(
  Directory directory,
  Set<String> visitedLinkTargets, {
  required bool skipHiddenDirectories,
  required String? boundary,
  required String displayBase,
  required Set<String>? linkEscapes,
}) sync* {
  for (final entity in directory.listSync(followLinks: false)) {
    if (entity is Directory) {
      if (_isSkippedDirectory(entity.path, skipHiddenDirectories)) {
        continue;
      }
      yield* _projectFilesIn(
        entity,
        visitedLinkTargets,
        skipHiddenDirectories: skipHiddenDirectories,
        boundary: boundary,
        displayBase: displayBase,
        linkEscapes: linkEscapes,
      );
    } else if (entity is File) {
      yield entity;
    } else if (entity is Link) {
      // typeSync는 링크를 따라가므로 끊어진 링크는 notFound가 되어 제외된다.
      final type = FileSystemEntity.typeSync(entity.path);
      if (type == FileSystemEntityType.file) {
        _recordLinkEscape(entity, boundary, displayBase, linkEscapes);
        yield File(entity.path);
      } else if (type == FileSystemEntityType.directory &&
          !_isSkippedDirectory(entity.path, skipHiddenDirectories)) {
        final target = _resolvedLinkTarget(entity);
        if (target != null &&
            boundary != null &&
            !isPathWithinRoot(target, boundary)) {
          linkEscapes?.add(_displayPath(entity.path, boundary, displayBase));
        }
        if (target != null && visitedLinkTargets.add(target)) {
          yield* _projectFilesIn(
            Directory(entity.path),
            visitedLinkTargets,
            skipHiddenDirectories: skipHiddenDirectories,
            boundary: boundary,
            displayBase: displayBase,
            linkEscapes: linkEscapes,
          );
        }
      }
    }
  }
}

/// 파일 링크의 실제 대상이 [boundary]를 벗어나면 [sink]에 표시 경로를 남긴다.
void _recordLinkEscape(
  Link link,
  String? boundary,
  String displayBase,
  Set<String>? sink,
) {
  if (boundary == null || sink == null) return;
  final target = _resolvedLinkTarget(link);
  if (target != null && !isPathWithinRoot(target, boundary)) {
    sink.add(_displayPath(link.path, boundary, displayBase));
  }
}

/// 링크 경로를 boundary 기준 posix 상대 경로(+displayBase)로 만든다. 링크 자체는
/// 항상 boundary 안에서 발견되므로 절대 경로가 출력에 새지 않는다.
String _displayPath(String linkPath, String boundary, String displayBase) =>
    '$displayBase${p.posix.joinAll(p.relative(linkPath, from: boundary).split(p.separator))}';

bool _isSkippedDirectory(String path, bool skipHiddenDirectories) {
  final name = p.basename(path);
  return indexExcludedDirectories.contains(name) ||
      (skipHiddenDirectories && name.startsWith('.'));
}

/// 디렉터리 링크의 실제 경로를 돌려주고, 해석에 실패하면 null을 돌려준다.
///
/// [FileSystemEntity.typeSync]로 종류를 확인한 뒤 실제 경로를 해석하기까지의
/// 사이에 외부 프로세스가 대상을 지우면 [FileSystemException]이 난다. 그 경우
/// 순회 전체를 실패시키지 않고 그 링크만 건너뛴다.
String? _resolvedLinkTarget(Link link) {
  try {
    return link.resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
}
