import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 분석용 git 조회가 분석 대상 저장소의 설정을 따라 실행할 수 있는 명령이다.
enum HostileGitSetting {
  /// 커밋된 `.gitattributes`의 `* filter=evil`과 `.git/config`의 clean 명령.
  committedAttributes,

  /// `.git/info/attributes`의 `* filter=evil`과 clean 명령.
  infoAttributes,

  /// 점이 든 드라이버 이름(`filter.evil.name.clean`). `filter.`과 마지막
  /// `.<키>` 사이 전체가 이름이다.
  dottedDriverName,

  /// 장기 실행 `process` 드라이버.
  processDriver,

  /// `required = true`인 드라이버(git-lfs 전역 설정과 같은 모양). 명령만 비우면
  /// git이 "clean filter failed"로 실패하므로 required도 덮어야 한다.
  requiredDriver,

  /// `core.fsmonitor` 훅.
  fsmonitor,

  /// git이 index를 다시 쓸 때 실행하는 `post-index-change` 훅.
  postIndexChangeHook,

  /// 서브모듈 저장소 자신의 설정에만 있는 filter 드라이버. 상위 저장소 설정에는
  /// 그 이름이 없어 상위에서 모은 이름으로는 끌 수 없다.
  submoduleFilter,

  /// 서브모듈 저장소 설정의 `core.fsmonitor` 훅.
  submoduleFsmonitor,

  /// 서브모듈 저장소의 `post-index-change` 훅.
  submoduleHook,
}

/// 저장소 설정의 명령이 실행되면 [marker]에 줄을 남기는 git 저장소다.
final class HostileRepository {
  HostileRepository._(this.root, this.marker, this.head);

  /// 저장소이자 패키지 루트의 실 경로다.
  final String root;

  /// 저장소 설정의 명령이 실행되면 생기는 파일이다. 저장소 밖에 둔다.
  final File marker;

  /// 설정을 심기 전에 커밋한 HEAD다.
  final String head;

  /// 저장소 설정의 명령이 한 번이라도 실행됐는지다.
  bool get commandRan => marker.existsSync();

  /// 루트 기준 [relative] 경로의 절대 경로다.
  String path(String relative) => p.normalize(p.join(root, relative));
}

/// [workspace] 아래 `repo`에 [setting]을 심은 저장소를 만든다.
///
/// `lib/fx.dart`·`lib/edited.dart`를 커밋한 **뒤에** 설정을 심는다(심은 뒤 fixture
/// git이 돌면 그때 마커가 생긴다). 마지막으로 `lib/fx.dart`(서브모듈이면 그 안의
/// `a.txt`도)의 mtime을 먼 과거로 돌려 stat 정보만 낡게 한다. 그래야 git이 내용을
/// 다시 읽으며 clean filter를 부르고, index를 새로 고쳐 쓰며 훅을 부른다. 같은 초
/// 안의 시각 변경은 git이 racy 항목으로만 다시 읽어 결정적이지 않다.
Future<HostileRepository> createHostileRepository(
  Directory workspace,
  HostileGitSetting setting,
) => createRepositoryWithHostileSettings(workspace, {setting});

/// [settings]를 한 저장소에 함께 심는다(나머지는 [createHostileRepository]와 같다).
///
/// cwd를 바꿔야 하는 테스트가 실행 한 번으로 여러 설정을 덮게 한다. 속성은 경로마다
/// 드라이버 하나만 고르므로 커밋할 `.gitattributes`가 서로 다른 설정
/// ([HostileGitSetting.dottedDriverName]과 `* filter=evil`을 쓰는 설정)은 함께
/// 심지 못한다([ArgumentError]).
Future<HostileRepository> createRepositoryWithHostileSettings(
  Directory workspace,
  Set<HostileGitSetting> settings,
) async {
  final attributes = {
    for (final setting in settings) ?_committedAttributes[setting],
  };
  if (attributes.length > 1) {
    throw ArgumentError.value(settings, 'settings', 'conflicting attributes');
  }
  final base = await workspace.resolveSymbolicLinks();
  final root = p.join(base, 'repo');
  final marker = File(p.join(base, 'command-ran'));
  _writeFile(root, 'lib/fx.dart', 'class Alpha {}\n');
  _writeFile(root, 'lib/edited.dart', 'class Edited {}\n');
  if (attributes.isNotEmpty) {
    _writeFile(root, '.gitattributes', attributes.single);
  }
  await _commitAll(root);
  final submodule = settings.any(_isSubmoduleSetting)
      ? await _addSubmodule(base, root)
      : null;
  final head = (await fixtureGit(root, const ['rev-parse', 'HEAD'])).trim();
  final commands = await _markerCommands(base, marker);
  for (final setting in settings) {
    await _plant(setting, root, submodule, commands);
  }
  _makeStatStale(p.join(root, 'lib', 'fx.dart'));
  if (submodule != null) _makeStatStale(p.join(root, 'sub', 'a.txt'));
  return HostileRepository._(root, marker, head);
}

/// [workspace] 아래 `repo`에 filter 드라이버 [rawName](설정 파일에 그대로 쓰는
/// 바이트)을 심은 저장소를 만든다. `.git/info/attributes`가 모든 파일에 그
/// 드라이버를 고른다.
///
/// `=`가 든 이름이나 UTF-8이 아닌 이름처럼 `-c`로 덮을 수 없는 이름을 재현한다.
Future<HostileRepository> createRepositoryWithFilterName(
  Directory workspace,
  List<int> rawName,
) async {
  final base = await workspace.resolveSymbolicLinks();
  final root = p.join(base, 'repo');
  final marker = File(p.join(base, 'command-ran'));
  _writeFile(root, 'lib/fx.dart', 'class Alpha {}\n');
  _writeFile(root, 'lib/edited.dart', 'class Edited {}\n');
  await _commitAll(root);
  final head = (await fixtureGit(root, const ['rev-parse', 'HEAD'])).trim();
  final commands = await _markerCommands(base, marker);
  final section = [
    ...utf8.encode('[filter "'),
    ...rawName,
    ...utf8.encode('"]\n\tclean = ${commands.filter}\n'),
  ];
  File(
    p.join(root, '.git', 'config'),
  ).writeAsBytesSync(section, mode: FileMode.append);
  final attributes = File(p.join(root, '.git', 'info', 'attributes'));
  attributes.parent.createSync(recursive: true);
  attributes.writeAsBytesSync([...utf8.encode('* filter='), ...rawName, 0x0a]);
  _makeStatStale(p.join(root, 'lib', 'fx.dart'));
  return HostileRepository._(root, marker, head);
}

/// git-lfs처럼 clean filter가 커밋 내용을 바꾸는 저장소를 만든다.
///
/// fixture가 신뢰하는 filter(`tr a-z A-Z`)를 **커밋 전에** 설정해 blob은 대문자,
/// 작업 트리는 소문자다. 마지막에 `lib/fx.dart`의 stat만 낡게 한다. filter를
/// 따르는 git은 이 파일을 깨끗하다고 보지만, filter를 끈 git에는 바뀐 파일이다.
Future<HostileRepository> createNormalizedFilterRepository(
  Directory workspace,
) async {
  final base = await workspace.resolveSymbolicLinks();
  final root = p.join(base, 'repo');
  final upper = p.join(base, 'upper.sh');
  File(upper).writeAsStringSync('#!/bin/sh\ntr a-z A-Z\n');
  final chmod = await Process.run('chmod', ['+x', upper]);
  if (chmod.exitCode != 0) throw StateError('chmod failed: ${chmod.stderr}');
  _writeFile(root, 'lib/fx.dart', 'class Alpha {}\n');
  _writeFile(root, '.gitattributes', '*.dart filter=upper\n');
  await fixtureGit(root, const ['init', '-q']);
  await fixtureGit(root, ['config', 'filter.upper.clean', upper]);
  await fixtureGit(root, const ['add', '-A']);
  await fixtureGit(root, const ['commit', '-q', '-m', 'init']);
  final head = (await fixtureGit(root, const ['rev-parse', 'HEAD'])).trim();
  _makeStatStale(p.join(root, 'lib', 'fx.dart'));
  return HostileRepository._(root, File(p.join(base, 'command-ran')), head);
}

/// 테스트가 소유한 저장소에서 fixture용 git을 실행한다.
///
/// 사용자 전역·시스템 설정(훅 경로, filter, 서명 등)이 fixture를 바꾸지 않게
/// 끄고, 커밋 작성자를 고정한다. 실패하면 stderr를 담아 [StateError]를 던진다.
Future<String> fixtureGit(String directory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    [
      '-c',
      'user.name=test',
      '-c',
      'user.email=test@example.invalid',
      '-c',
      'init.defaultBranch=main',
      '-c',
      'protocol.file.allow=always',
      '-C',
      directory,
      ...arguments,
    ],
    environment: const {
      'GIT_CONFIG_GLOBAL': '/dev/null',
      'GIT_CONFIG_NOSYSTEM': '1',
    },
  );
  if (result.exitCode != 0) {
    throw StateError('fixture git ${arguments.first} failed: ${result.stderr}');
  }
  return result.stdout as String;
}

/// 저장소에 커밋되는 `.gitattributes` 내용이다(이 설정들만 커밋 전에 쓴다).
const _committedAttributes = {
  HostileGitSetting.committedAttributes: '* filter=evil\n',
  HostileGitSetting.dottedDriverName: '* filter=evil.name\n',
  HostileGitSetting.processDriver: '* filter=evil\n',
  HostileGitSetting.requiredDriver: '* filter=evil\n',
};

bool _isSubmoduleSetting(HostileGitSetting setting) => const {
  HostileGitSetting.submoduleFilter,
  HostileGitSetting.submoduleFsmonitor,
  HostileGitSetting.submoduleHook,
}.contains(setting);

/// 마커를 남기는 두 스크립트의 경로다. 설정 파일 값에서 `;`·`#`는 주석이라
/// 명령 문자열 대신 스크립트 파일 경로를 심는다.
typedef _MarkerCommands = ({String filter, String hook});

Future<_MarkerCommands> _markerCommands(String base, File marker) async {
  final filter = p.join(base, 'filter-command.sh');
  final hook = p.join(base, 'hook-command.sh');
  // filter는 내용을 그대로 돌려줘 git이 같은 내용으로 보게 한다. fsmonitor·훅은
  // 실패(1)로 끝나 git이 원래 방식으로 계속하게 한다.
  File(
    filter,
  ).writeAsStringSync("#!/bin/sh\necho ran >> '${marker.path}'\ncat\n");
  File(
    hook,
  ).writeAsStringSync("#!/bin/sh\necho ran >> '${marker.path}'\nexit 1\n");
  final chmod = await Process.run('chmod', ['+x', filter, hook]);
  if (chmod.exitCode != 0) throw StateError('chmod failed: ${chmod.stderr}');
  return (filter: filter, hook: hook);
}

Future<void> _plant(
  HostileGitSetting setting,
  String root,
  String? submodule,
  _MarkerCommands commands,
) async {
  switch (setting) {
    case HostileGitSetting.committedAttributes:
      await fixtureGit(root, ['config', 'filter.evil.clean', commands.filter]);
    case HostileGitSetting.infoAttributes:
      _writeFile(root, '.git/info/attributes', '* filter=evil\n');
      await fixtureGit(root, ['config', 'filter.evil.clean', commands.filter]);
    case HostileGitSetting.dottedDriverName:
      await fixtureGit(root, [
        'config',
        'filter.evil.name.clean',
        commands.filter,
      ]);
    case HostileGitSetting.processDriver:
      await fixtureGit(root, [
        'config',
        'filter.evil.process',
        commands.filter,
      ]);
    case HostileGitSetting.requiredDriver:
      await fixtureGit(root, ['config', 'filter.evil.clean', commands.filter]);
      await fixtureGit(root, ['config', 'filter.evil.required', 'true']);
    case HostileGitSetting.fsmonitor:
      await fixtureGit(root, ['config', 'core.fsmonitor', commands.hook]);
    case HostileGitSetting.postIndexChangeHook:
      await _plantHook(root, commands.hook);
    case HostileGitSetting.submoduleFilter:
      _writeFile(submodule!, 'info/attributes', '* filter=subonly\n');
      await fixtureGit(p.join(root, 'sub'), [
        'config',
        'filter.subonly.clean',
        commands.filter,
      ]);
    case HostileGitSetting.submoduleFsmonitor:
      await fixtureGit(p.join(root, 'sub'), [
        'config',
        'core.fsmonitor',
        commands.hook,
      ]);
    case HostileGitSetting.submoduleHook:
      await _plantHook(p.join(root, 'sub'), commands.hook);
  }
}

/// [worktree] 저장소의 `core.hooksPath`가 가리키는 곳에 post-index-change 훅을
/// 둔다. 사용자 전역 `core.hooksPath`와 무관하게 결정적이도록 저장소 설정에
/// 절대 경로로 적는다.
Future<void> _plantHook(String worktree, String hook) async {
  final gitDirectory = (await fixtureGit(worktree, const [
    'rev-parse',
    '--absolute-git-dir',
  ])).trim();
  final hooks = p.join(gitDirectory, 'dartograph-test-hooks');
  Directory(hooks).createSync(recursive: true);
  File(hook).copySync(p.join(hooks, 'post-index-change'));
  final chmod = await Process.run('chmod', [
    '+x',
    p.join(hooks, 'post-index-change'),
  ]);
  if (chmod.exitCode != 0) throw StateError('chmod failed: ${chmod.stderr}');
  await fixtureGit(worktree, ['config', 'core.hooksPath', hooks]);
}

/// [root] 아래 `sub`에 서브모듈을 더해 커밋하고 그 저장소의 git 디렉터리를 돌려준다.
Future<String> _addSubmodule(String base, String root) async {
  final child = p.join(base, 'child');
  _writeFile(child, 'a.txt', 'a\n');
  await _commitAll(child);
  await fixtureGit(root, ['submodule', 'add', '-q', child, 'sub']);
  await fixtureGit(root, ['commit', '-q', '-m', 'add submodule']);
  return (await fixtureGit(p.join(root, 'sub'), const [
    'rev-parse',
    '--absolute-git-dir',
  ])).trim();
}

Future<void> _commitAll(String root) async {
  await fixtureGit(root, const ['init', '-q']);
  await fixtureGit(root, const ['add', '-A']);
  await fixtureGit(root, const ['commit', '-q', '-m', 'init']);
}

void _writeFile(String root, String relative, String contents) {
  final file = File(p.join(root, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// 내용은 두고 mtime만 2001년으로 돌린다.
void _makeStatStale(String path) {
  File(path).setLastModifiedSync(DateTime.utc(2001));
}
