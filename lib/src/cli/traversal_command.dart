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
  } on Exception {
    return _reportAnalysisFailure(error);
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
  final revision = options.revision ?? await _cleanGitHead(root);
  output.write(
    exportLanguageTraversal(
      result,
      LanguageTraversalMetadata(
        generatedAt: options.generatedAt ?? now(),
        project: exchange.project,
        packageRoot: root,
        graphRevision: graphRevisionOf(snapshot),
        revision: revision,
      ),
      limitations: [..._limitations(indexed), ...exchange.limitations],
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

Future<String> _readRootsSource(String source) async {
  const limit = 16 * 1024 * 1024;
  final bytes = source == '-'
      ? await stdin.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))
      : await File(source).readAsBytes();
  if (bytes.length > limit) {
    throw const FormatException('--roots-from exceeds 16 MiB.');
  }
  return utf8.decode(bytes);
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

/// 작업 트리가 깨끗할 때만 git HEAD다 — 편집 중인 소스를 분석한 문서를 isthmus가
/// 현재 revision으로 믿지 않게 한다. git이 없거나 저장소가 아니면 null이다.
Future<String?> _cleanGitHead(String root) async {
  try {
    final status = await Process.run('git', [
      '-C',
      root,
      'status',
      '--porcelain',
      '--untracked-files=normal',
      '--',
      '.',
    ]);
    if (status.exitCode != 0 || (status.stdout as String).trim().isNotEmpty) {
      return null;
    }
    final head = await Process.run('git', ['-C', root, 'rev-parse', 'HEAD']);
    if (head.exitCode != 0) return null;
    final value = (head.stdout as String).trim();
    return RegExp(r'^[0-9a-f]{40,64}$').hasMatch(value) ? value : null;
  } on ProcessException {
    return null;
  }
}
