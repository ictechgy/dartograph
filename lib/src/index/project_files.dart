import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config_source.dart';

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

/// 심볼릭 링크를 거쳐 닿은 디렉터리를 정규 경로마다 한 번만 열게 하는 방문
/// 기록이다.
///
/// analyzer 그래프의 분석 단위 열거와 [indexProjectFiles](캐시 키·`bridges`·
/// `schema`)가 이 규칙을 함께 쓴다. 그래야 같은 디렉터리로 가는 경로가 여럿일 때
/// 두 열거가 같은 경로를 남긴다. 두 열거 모두 항목을 이름순으로 훑는다. 그래서
/// 남는 경로가 파일 시스템의 목록 순서에 따라 갈리지 않는다.
///
/// - 지금 경로의 조상과 정규 경로가 같은 디렉터리는 링크 순환이다. 열지 않고
///   세지도 않는다. analyzer가 자기 열거에서 쓰는 스택 범위 방문 집합과 같다.
/// - 순회 시작 디렉터리에서 링크를 하나도 거치지 않고 닿은 실제 위치는 언제나 연다.
/// - 링크를 거쳐 닿은 디렉터리는 정규 경로마다 처음 한 번만 연다. 링크 자체든 링크
///   아래의 실제 하위 디렉터리든 같다. 같은 정규 경로에 다시 닿은 경로는 열지 않고
///   [skipped]에 남긴다.
///
/// 그래서 디렉터리 하나는 많아야 두 번(실제 위치와 링크 경로 하나) 열린다. 단계마다
/// 다음 단계를 두 번 가리키는 링크 트리(DAG)를 경로마다 다시 펼치면 경로 수가
/// 깊이에 지수적으로 는다. 링크 대상만 한 번씩 세면 실제 하위 디렉터리 사슬과 그
/// 사슬의 깊이마다 둔 링크로 경로 수가 링크 수의 제곱으로 는다. 이 규칙에서는 둘 다
/// 디렉터리 수에 비례한다. 실제 위치를 따로 여는 것은 분석 범위가 `lib/` 같은 경로로
/// 정해지기 때문이다. 범위 밖 실제 디렉터리를 범위 안 링크가 끌어오는 배치와
/// `lib/src`·`lib/alias -> src` 같은 별칭이 지금처럼 둘 다 분석된다.
final class LinkedDirectoryVisits {
  /// 링크를 거쳐 이미 연 디렉터리의 정규 경로다.
  final _openedThroughLinks = <String>{};

  final _skipped = <({String path, String canonical})>[];

  /// 다른 경로로 이미 연 디렉터리라서 열지 않은 경로와 그 정규 경로다(만난 순서).
  List<({String path, String canonical})> get skipped =>
      List.unmodifiable(_skipped);

  /// [path] 디렉터리를 열지 정한다. 열지 않을 경로가 중복이면 [skipped]에 남긴다.
  ///
  /// [canonical]은 [path]의 정규 경로이고, [ancestors]는 지금 경로에서 이미 연
  /// 조상 디렉터리들의 정규 경로다. 순회의 시작 디렉터리는 [ancestors]에 넣지 않는다
  /// (analyzer와 같다). [throughLink]는 순회 시작에서 [path]까지 심볼릭 링크를 하나
  /// 이상 거쳤는지다. 시작 경로 자체가 정규 경로가 아니어도(macOS의 `/var` 등) 실제
  /// 위치를 링크 경로로 오인하지 않도록, 경로 문자열 비교가 아니라 순회가 넘긴다.
  bool admits(
    String path,
    String canonical,
    Set<String> ancestors, {
    required bool throughLink,
  }) {
    if (ancestors.contains(canonical)) return false;
    if (!throughLink) return true;
    if (_openedThroughLinks.add(canonical)) return true;
    _skipped.add((path: path, canonical: canonical));
    return false;
  }
}

/// [count]개 디렉터리 경로를 중복으로 건너뛰었다는 limitation 문구다.
///
/// 경로는 싣지 않는다. 링크 트리 하나로 건너뛴 경로가 깊이만큼 늘어나 출력이
/// 커지기 때문이다. 접두사는 그래프·`runtime`·`routes`·`bridges`·`schema`가 같다.
String skippedLinkedDirectoriesLimitation(int count) =>
    'symlink-duplicate-directories: $count symlinked directory path(s) were '
    'skipped because they resolve to a directory already read through another '
    'path';

/// [directory] 아래의 파일을 심볼릭 링크까지 따라가며 돌려준다.
///
/// `followLinks: false` 목록에서 심볼릭 링크는 `Link`로 나와 `File`·`Directory`
/// 분기에 걸리지 않는다. 그런데 analyzer는 링크 경로를 그대로 분석 대상에
/// 넣으므로, 링크를 빠뜨리면 링크된 소스가 그래프에는 있고 캐시 키에는 없어
/// 대상을 수정해도 낡은 사실이 재사용된다.
///
/// 항목은 이름순으로 훑고, 디렉터리는 [LinkedDirectoryVisits]의 규칙으로 연다.
/// [linkedDirectories]를 주면 그 기록을 쓴다. 호출자는 순회가 끝난 뒤 건너뛴
/// 경로를 읽어 limitation이나 캐시 키에 싣는다.
///
/// [boundary]·[linkEscapes]가 주어지면 링크의 실제 대상이 [boundary]를 벗어날
/// 때 `displayBase + boundary 상대 경로`를 [linkEscapes]에 기록한다. 링크는
/// 계속 따라간다 — 루트 밖 대상도 analyzer가 해석하는 입력이므로 차단하면
/// 스캔 공백이 생긴다. 기록은 "저장소 콘텐츠가 루트 밖 파일을 분석 입력으로
/// 끌어왔다"는 사실을 보고서에 남기기 위한 것이다. 디렉터리 링크는 순환·중복이라
/// 열지 않아도 기록한다.
///
/// 대상이 파일도 디렉터리도 아닌데 존재하는 링크(장치·FIFO·소켓)는
/// [NonRegularFileException]으로 순회를 멈춘다(fail-closed).
/// analyzer와 구문 스캐너는 그런 대상을 EOF 없이 읽거나(메모리 소진) FIFO에서
/// 영구 대기한다. 끊어진 링크는 지금처럼 조용히 건너뛴다.
Iterable<File> indexProjectFiles(
  Directory directory, {
  bool skipHiddenDirectories = false,
  String? boundary,
  String displayBase = '',
  Set<String>? linkEscapes,
  LinkedDirectoryVisits? linkedDirectories,
}) sync* {
  final walk = _ProjectFileWalk(
    linkedDirectories ?? LinkedDirectoryVisits(),
    skipHiddenDirectories: skipHiddenDirectories,
    boundary: boundary,
    displayBase: displayBase,
    linkEscapes: linkEscapes,
  );
  yield* walk.filesIn(
    directory.path,
    directory.resolveSymbolicLinksSync(),
    throughLink: false,
  );
}

/// [indexProjectFiles] 한 번의 순회 상태다.
final class _ProjectFileWalk {
  _ProjectFileWalk(
    this._visits, {
    required this.skipHiddenDirectories,
    required this.boundary,
    required this.displayBase,
    required this.linkEscapes,
  });

  final LinkedDirectoryVisits _visits;
  final bool skipHiddenDirectories;
  final String? boundary;
  final String displayBase;
  final Set<String>? linkEscapes;

  /// 지금 경로에서 연 조상 디렉터리들의 정규 경로다.
  final _ancestors = <String>{};

  /// [directory](정규 경로 [canonical]) 아래 파일이다. 링크 자체의 경로로 재귀해
  /// analyzer가 사용하는 경로와 같은 모양을 유지한다. [throughLink]는
  /// [LinkedDirectoryVisits.admits]의 같은 이름이다.
  Iterable<File> filesIn(
    String directory,
    String canonical, {
    required bool throughLink,
  }) sync* {
    final entities = Directory(directory).listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is Directory) {
        if (_isSkippedDirectory(entity.path, skipHiddenDirectories)) continue;
        // 링크가 아닌 하위 디렉터리의 정규 경로는 부모의 정규 경로 아래 같은 이름이다.
        yield* _open(
          entity.path,
          p.join(canonical, p.basename(entity.path)),
          throughLink: throughLink,
        );
      } else if (entity is File) {
        yield entity;
      } else if (entity is Link) {
        yield* _followLink(entity);
      }
    }
  }

  Iterable<File> _followLink(Link link) sync* {
    // typeSync는 링크를 따라가므로 끊어진 링크는 notFound가 되어 제외된다.
    final type = FileSystemEntity.typeSync(link.path);
    if (type == FileSystemEntityType.file) {
      _recordLinkEscape(link, boundary, displayBase, linkEscapes);
      yield File(link.path);
    } else if (type == FileSystemEntityType.directory) {
      if (_isSkippedDirectory(link.path, skipHiddenDirectories)) return;
      final target = _resolvedLinkTarget(link);
      if (target == null) return;
      final boundary = this.boundary;
      if (boundary != null && !isPathWithinRoot(target, boundary)) {
        linkEscapes?.add(_displayPath(link.path, boundary, displayBase));
      }
      yield* _open(link.path, target, throughLink: true);
    } else if (File(link.path).existsSync()) {
      // 장치는 notFound 종류로 보고되지만 존재한다. FIFO·소켓도 여기다.
      throw const NonRegularFileException();
    }
  }

  Iterable<File> _open(
    String path,
    String canonical, {
    required bool throughLink,
  }) sync* {
    if (!_visits.admits(
      path,
      canonical,
      _ancestors,
      throughLink: throughLink,
    )) {
      return;
    }
    _ancestors.add(canonical);
    yield* filesIn(path, canonical, throughLink: throughLink);
    _ancestors.remove(canonical);
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
