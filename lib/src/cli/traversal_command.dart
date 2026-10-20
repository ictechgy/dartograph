part of 'dartograph_cli.dart';

// `impact --format language-traversal` — isthmus trace용 순회 문서다.

/// `impact --format language-traversal` 인자다.
typedef _TraversalOptions = ({
  String root,
  List<String> roots,
  String? rootsFrom,
  String? project,
  String? revision,
  DateTime? generatedAt,
  TraversalDirection direction,
});

/// `impact` 인자가 language-traversal 형식을 고르는지다.
bool _isLanguageTraversal(List<String> arguments) {
  for (var index = 0; index + 1 < arguments.length; index++) {
    if (arguments[index] == '--format' &&
        arguments[index + 1] == 'language-traversal') {
      return true;
    }
  }
  return false;
}

/// `impact --format language-traversal`을 실행한다.
Future<int> _runLanguageTraversal(
  List<String> arguments,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
  DateTime Function() now,
) async {
  final options = _parseTraversalArguments(arguments, error);
  if (options == null) return ExitStatus.usage.code;
  final List<String> roots;
  try {
    roots = await _traversalRoots(options);
  } on FormatException catch (invalid) {
    error.writeln(invalid.message);
    return ExitStatus.usage.code;
  } on FileSystemException {
    error.writeln('--roots-from could not be read; pass a file or -.');
    return ExitStatus.usage.code;
  }
  try {
    return await _emitTraversal(
      options,
      roots,
      output,
      error,
      indexPackage,
      now,
    );
  } on Exception catch (exception) {
    return _reportAnalysisFailure(error, exception);
  } on StateError {
    return _reportAnalysisFailure(error);
  } on ArgumentError {
    return _reportAnalysisFailure(error);
  }
}

Future<int> _emitTraversal(
  _TraversalOptions options,
  List<String> roots,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
  DateTime Function() now,
) async {
  final root = Directory(options.root).absolute.resolveSymbolicLinksSync();
  final exchange = _resolveExchangeProject(root, options.project, error);
  if (exchange == null) return ExitStatus.usage.code;
  final indexed = await indexPackage(root);
  final snapshot = indexed.graph.snapshot();
  final result = LanguageTraversal.traverse(snapshot, roots, options.direction);
  final observed = options.revision != null
      ? (revision: options.revision, limitation: null)
      : await _cleanGitHead(root);
  output.write(
    exportLanguageTraversal(
      result,
      LanguageTraversalMetadata(
        generatedAt: options.generatedAt ?? now(),
        project: exchange.project,
        packageRoot: root,
        graphRevision: graphRevisionOf(snapshot),
        revision: observed.revision,
      ),
      limitations: [
        ..._limitations(indexed),
        ...exchange.limitations,
        ?observed.limitation,
      ],
    ),
  );
  return result.rootNotFound ? ExitStatus.usage.code : ExitStatus.success.code;
}

_TraversalOptions? _parseTraversalArguments(
  List<String> arguments,
  StringSink error,
) {
  const valueOptions = {
    '--format',
    '--direction',
    '--roots-from',
    '--project',
    '--revision',
    '--generated-at',
  };
  final values = <String, String>{};
  final positional = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    final value = index + 1 < arguments.length ? arguments[index + 1] : null;
    if (valueOptions.contains(argument) &&
        !values.containsKey(argument) &&
        value != null &&
        (argument == '--roots-from' && value == '-' ||
            (value.isNotEmpty && !value.startsWith('-')))) {
      values[argument] = value;
      index++;
    } else if (!argument.startsWith('-')) {
      positional.add(argument);
    } else {
      error.writeln(
        'impact --format language-traversal accepts --direction, --roots-from, '
        '--project, --revision and --generated-at; $argument is not supported '
        'with this format.',
      );
      return null;
    }
  }
  return _validateTraversal(values, positional, error);
}

_TraversalOptions? _validateTraversal(
  Map<String, String> values,
  List<String> positional,
  StringSink error,
) {
  final direction = switch (values['--direction'] ?? 'dependents') {
    'dependents' => TraversalDirection.dependents,
    'dependencies' => TraversalDirection.dependencies,
    _ => null,
  };
  final generated = values['--generated-at'];
  final generatedAt = generated == null ? null : DateTime.tryParse(generated);
  final revision = values['--revision'];
  if (direction == null ||
      positional.isEmpty ||
      (generated != null && generatedAt == null)) {
    error.write(_help);
    return null;
  }
  if (revision != null && !isExchangeText(revision)) {
    error.writeln(
      '--revision must be non-empty without control characters (C0, DEL, C1, '
      'U+2028, U+2029); isthmus rejects such revisions.',
    );
    return null;
  }
  return (
    root: positional.first,
    roots: positional.skip(1).toList(),
    rootsFrom: values['--roots-from'],
    project: values['--project'],
    revision: revision,
    generatedAt: generatedAt,
    direction: direction,
  );
}

/// root 요청을 모은다. 위치 인자 뒤에 `--roots-from`의 JSON 문자열 배열이나
/// bridge-facts 문서의 `symbol.usr`(문서 순서, 중복 제거)를 붙인다.
Future<List<String>> _traversalRoots(_TraversalOptions options) async {
  final source = options.rootsFrom;
  final fromFile = source == null
      ? const <String>[]
      : parseTraversalRoots(await _readRootsSource(source));
  final roots = <String>{...options.roots, ...fromFile};
  if (roots.isEmpty) {
    throw const FormatException(
      'Provide root symbols or --roots-from (the symbol.usr of routes facts).',
    );
  }
  if (!roots.every(isExchangeText)) {
    throw const FormatException(
      'Invalid root: roots must be non-empty without control characters (C0, '
      'DEL, C1, U+2028, U+2029); pass the symbol.usr from routes facts.',
    );
  }
  if (roots.length > LanguageTraversal.maxRoots) {
    throw const FormatException('At most 10000 roots are supported.');
  }
  return roots.toList();
}

/// `--roots-from` 입력(파일 또는 `-`의 stdin)을 16 MiB까지 읽는다.
///
/// 청크를 모으다 상한을 넘는 즉시 멈춘다. 전부 읽은 뒤에야 길이를 보면 EOF가
/// 오지 않는 파이프·장치에서 상한 진단에 이르지 못하고 메모리가 먼저
/// 고갈된다. 프로세스 치환(`<(...)`)처럼 파이프인 경로도 정상 입력이다.
Future<String> _readRootsSource(String source) async {
  const limit = 16 * 1024 * 1024;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in source == '-' ? stdin : File(source).openRead()) {
    bytes.add(chunk);
    if (bytes.length > limit) {
      throw const FormatException('--roots-from exceeds 16 MiB.');
    }
  }
  return utf8.decode(bytes.takeBytes());
}

/// `--roots-from` 내용에서 root를 읽는다. JSON 문자열 배열이거나
/// bridge-facts 문서(사실의 `symbol.usr`)다.
List<String> parseTraversalRoots(String content) {
  const shape = FormatException(
    '--roots-from must be a UTF-8 JSON string array or a bridge-facts document '
    '(16 MiB max).',
  );
  final Object? value;
  try {
    value = jsonDecode(content);
  } on FormatException {
    throw shape;
  }
  if (value is List) {
    if (!value.every((item) => item is String)) throw shape;
    return value.cast<String>();
  }
  if (value is! Map<String, Object?> || value['format'] != 'bridge-facts') {
    throw shape;
  }
  final facts = value['facts'];
  if (facts is! List) throw shape;
  return [
    for (final fact in facts)
      if (fact is Map<String, Object?> &&
          fact['symbol'] is Map<String, Object?> &&
          (fact['symbol']! as Map<String, Object?>)['usr'] is String)
        (fact['symbol']! as Map<String, Object?>)['usr']! as String,
  ];
}

/// isthmus 교환 문서가 id·revision으로 받는 문자열인지다 — 비어 있지 않고
/// 제어 문자(C0·DEL·C1·U+2028·U+2029)와 짝 없는 서러게이트가 없다.
bool isExchangeText(String value) {
  if (value.trim().isEmpty || _controlCharacters.hasMatch(value)) return false;
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    final high = unit >= 0xD800 && unit <= 0xDBFF;
    final low = unit >= 0xDC00 && unit <= 0xDFFF;
    if (low) return false;
    if (!high) continue;
    final next = index + 1 < value.length ? value.codeUnitAt(index + 1) : 0;
    if (next < 0xDC00 || next > 0xDFFF) return false;
    index++;
  }
  return true;
}

/// `--revision` 없이 문서에 실을 revision과, 일부러 확인하지 않아 싣지 못한
/// 이유(`revision-unverified:` limitation)다. 둘 다 없을 수 있다.
typedef _ObservedRevision = ({String? revision, String? limitation});

/// revision도 이유도 없다. git이 없거나 저장소가 아니거나 작업 트리가 깨끗하지
/// 않으면 지금처럼 revision만 비운다 — revision이 없다는 것 자체가 신호다.
const _ObservedRevision _noRevision = (revision: null, limitation: null);

/// 작업 트리가 깨끗할 때만 git HEAD다 — 편집 중인 소스를 분석한 문서를 isthmus가
/// 현재 revision으로 믿지 않게 한다.
///
/// 모든 git 호출은 [AnalysisGit]을 지나 저장소 설정의 명령을 실행하지 않는다.
/// 그래서 filter가 정규화하던 파일(git-lfs 등)은 stat 정보가 낡으면 바뀐 것으로
/// 보이고, 그때는 깨끗하다고 주장하지 않는다(fail-safe, DECISIONS D1). 끌 수 없는
/// filter 드라이버 이름이나, promisor 원격의 fetch를 끌 수 없는 git(2.45 미만)
/// 때문에 git을 실행하지 않았으면 그 이유를 limitation으로 남긴다.
Future<_ObservedRevision> _cleanGitHead(String root) async {
  try {
    final status = await AnalysisGit.run(root, const [
      'status',
      '--porcelain',
      '--untracked-files=normal',
      '--ignore-submodules=all',
      '--',
      '.',
    ]);
    if (status.exitCode != 0 ||
        latin1.decode(status.stdout).trim().isNotEmpty) {
      return _noRevision;
    }
    return await _headUnlessSubmodules(root);
  } on ProcessException {
    return _noRevision;
  } on AnalysisGitException catch (refused) {
    return (
      revision: null,
      limitation: unverifiedRevisionNote(refused.refusal),
    );
  }
}

/// git을 실행하지 않은 [refusal]을 순회 문서의 `revision-unverified:` 이유로
/// 바꾼다.
///
/// 설정을 읽지 못한 경우는 null이다 — git이 없거나 저장소가 아닐 때처럼
/// revision이 없다는 것 자체가 신호다. 나머지는 git이 저장소 설정의 명령을 끌 수
/// 없어 일부러 실행하지 않은 경우라, 원인과 `--revision` 안내를 남긴다.
String? unverifiedRevisionNote(AnalysisGitRefusal refusal) => switch (refusal) {
  AnalysisGitRefusal.configurationUnreadable => null,
  AnalysisGitRefusal.unneutralizableFilterDriver =>
    _unneutralizableRevisionNote,
  AnalysisGitRefusal.unavoidableLazyFetch => _lazyFetchRevisionNote,
};

/// 깨끗한 작업 트리의 HEAD다. 서브모듈(index의 gitlink)이 있으면 싣지 않는다.
///
/// 서브모듈 작업 트리를 보려면 git이 그 안에서 서브모듈 저장소 자신의 설정을
/// 따르므로 보지 않았다(status의 `--ignore-submodules=all`). 그러니 깨끗함을
/// 증명할 수 없다.
Future<_ObservedRevision> _headUnlessSubmodules(String root) async {
  final index = await AnalysisGit.run(root, const [
    'ls-files',
    '--stage',
    '-z',
    '--',
    '.',
  ]);
  if (index.exitCode != 0) return _noRevision;
  final submodules = _gitlinkCount(index.stdout);
  if (submodules > 0) {
    return (revision: null, limitation: _submoduleRevisionNote(submodules));
  }
  final head = await AnalysisGit.run(root, const ['rev-parse', 'HEAD']);
  if (head.exitCode != 0) return _noRevision;
  final value = latin1.decode(head.stdout).trim();
  final valid = RegExp(r'^[0-9a-f]{40,64}$').hasMatch(value);
  return (revision: valid ? value : null, limitation: null);
}

/// `git ls-files --stage -z` 출력의 gitlink(mode 160000) 경로 수다. 충돌 중인
/// 항목은 stage마다 한 줄씩 나오므로 경로로 센다.
int _gitlinkCount(List<int> output) => {
  for (final entry in latin1.decode(output).split('\u0000'))
    if (entry.startsWith('160000 ')) entry.substring(entry.indexOf('\t') + 1),
}.length;

/// 서브모듈 때문에 revision을 싣지 않은 이유다.
String _submoduleRevisionNote(int count) =>
    'revision-unverified: the package root has $count git submodule(s); '
    'dartograph does not run git inside them (that would follow their own '
    'repository configuration, such as filter commands), so a clean HEAD '
    'cannot be confirmed; pass --revision to record the analyzed revision';

/// 끌 수 없는 filter 드라이버 이름 때문에 git을 실행하지 않은 이유다. 이름 원문은
/// 신뢰하지 않는 설정 값이라 싣지 않는다.
const _unneutralizableRevisionNote =
    'revision-unverified: the git configuration defines a filter driver whose '
    "name contains '=' or is not valid UTF-8, which git cannot be told to "
    'skip, so dartograph did not inspect the work tree; pass --revision to '
    'record the analyzed revision';

/// promisor 원격의 fetch를 끌 수 없는 git이라 git을 실행하지 않은 이유다.
const _lazyFetchRevisionNote =
    'revision-unverified: the git configuration names a promisor remote (a '
    'partial clone), and git older than 2.45 cannot be told not to fetch '
    "missing objects from it, which runs commands from the remote's settings, "
    'so dartograph did not inspect the work tree; use git 2.45 or newer, or '
    'pass --revision to record the analyzed revision';
