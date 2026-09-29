part of 'dartograph_cli.dart';

// isthmus http 도메인 교환 명령 `routes`(route-call 생산자)다.

/// `routes` 인자다.
typedef _RoutesOptions = ({
  String root,
  String? project,
  String? wrappers,
  String? service,
  bool includeTests,
});

/// `routes --role client`를 실행한다.
Future<int> _runRoutes(
  List<String> arguments,
  StringSink output,
  StringSink error,
  DateTime Function() now,
) async {
  final options = _parseRoutesArguments(arguments, error);
  if (options == null) return ExitStatus.usage.code;
  final List<HttpWrapperDeclaration> wrappers;
  try {
    wrappers = await _readWrappers(options.wrappers);
  } on HttpWrappersFormatException catch (invalid) {
    error.writeln(invalid.message);
    return ExitStatus.usage.code;
  } on FileSystemException {
    error.writeln(
      'The http-wrappers file could not be read; pass an existing JSON file '
      '(1 MiB max).',
    );
    return ExitStatus.usage.code;
  }
  final service = options.service;
  final conflicting = wrappers.any(
    (wrapper) =>
        wrapper.language == 'dart' &&
        service != null &&
        wrapper.service != null &&
        wrapper.service != service,
  );
  if (conflicting) {
    error.writeln(
      'A dart wrapper declares a service that differs from --service; drop one '
      'of them.',
    );
    return ExitStatus.usage.code;
  }
  return _emitRoutes(options, wrappers, output, error, now);
}

Future<int> _emitRoutes(
  _RoutesOptions options,
  List<HttpWrapperDeclaration> wrappers,
  StringSink output,
  StringSink error,
  DateTime Function() now,
) async {
  try {
    final root = Directory(options.root).absolute.resolveSymbolicLinksSync();
    final exchange = _resolveExchangeProject(root, options.project, error);
    if (exchange == null) return ExitStatus.usage.code;
    final indexed = await indexRouteCalls(
      root,
      projectRootPath: exchange.project == root ? null : exchange.project,
      wrappers: wrappers,
      includeTests: options.includeTests,
    );
    output.write(
      exportRouteFacts(
        project: exchange.project,
        generatedAt: now(),
        facts: indexed.facts,
        limitations: [...indexed.limitations, ...exchange.limitations],
        includeTests: options.includeTests,
        service: options.service,
      ),
    );
    return ExitStatus.success.code;
  } on FormatException {
    error.writeln(
      'Routes extraction failed: a source path contains control characters.',
    );
    return ExitStatus.failure.code;
  } on Exception {
    return _reportAnalysisFailure(error);
  } on StateError {
    return _reportAnalysisFailure(error);
  } on ArgumentError {
    return _reportAnalysisFailure(error);
  }
}

/// `routes` 인자를 읽는다. 잘못되면 원인을 쓰고 null이다.
_RoutesOptions? _parseRoutesArguments(
  List<String> arguments,
  StringSink error,
) {
  const valueOptions = {
    '--role',
    '--wrappers',
    '--service',
    '--format',
    '--project',
  };
  final values = <String, String>{};
  final positional = <String>[];
  var includeTests = false;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--') {
      positional.addAll(arguments.skip(index + 1));
      break;
    }
    if (argument == '--include-tests' && !includeTests) {
      includeTests = true;
    } else if (valueOptions.contains(argument) &&
        !values.containsKey(argument) &&
        index + 1 < arguments.length &&
        arguments[index + 1].isNotEmpty &&
        !arguments[index + 1].startsWith('-')) {
      values[argument] = arguments[++index];
    } else if (!argument.startsWith('-')) {
      positional.add(argument);
    } else {
      error.write(_help);
      return null;
    }
  }
  return _validateRoutes(values, positional, includeTests, error);
}

_RoutesOptions? _validateRoutes(
  Map<String, String> values,
  List<String> positional,
  bool includeTests,
  StringSink error,
) {
  final role = values['--role'];
  if (role != 'client') {
    error.writeln(
      role == null
          ? 'routes requires --role client.'
          : 'routes supports only --role client: dartograph emits client '
                'route-call facts.',
    );
    return null;
  }
  final format = values['--format'];
  final service = values['--service'];
  final invalidService =
      service != null &&
      (service.trim().isEmpty || _controlCharacters.hasMatch(service));
  if ((format != null && format != 'json') ||
      invalidService ||
      positional.length != 1) {
    error.write(_help);
    return null;
  }
  return (
    root: positional.single,
    project: values['--project'],
    wrappers: values['--wrappers'],
    service: service,
    includeTests: includeTests,
  );
}

/// isthmus가 거부하는 제어 문자다(C0·DEL·C1·U+2028·U+2029).
final _controlCharacters = RegExp(r'[\x00-\x1F\x7F-\x9F  ]');

Future<List<HttpWrapperDeclaration>> _readWrappers(String? path) async {
  if (path == null) return const [];
  final file = File(path);
  if (await file.length() > 1024 * 1024) {
    throw const HttpWrappersFormatException(
      'invalid http-wrappers v1 declaration: the file exceeds 1 MiB',
    );
  }
  return parseHttpWrappers(await file.readAsString());
}

/// 교환 문서의 `project`다. 명시적 `--project` > pub workspace 감지 > 스캔
/// 루트 순이며 `bridges`와 같은 규칙이다. 잘못된 `--project`면 원인을 쓰고
/// null이다.
({String project, List<String> limitations})? _resolveExchangeProject(
  String root,
  String? projectOption,
  StringSink error,
) {
  if (projectOption != null) {
    String resolved;
    try {
      resolved = Directory(projectOption).absolute.resolveSymbolicLinksSync();
    } on FileSystemException {
      error.writeln(_invalidBridgesProjectMessage);
      return null;
    }
    if (!p.equals(resolved, root) && !p.isWithin(resolved, root)) {
      error.writeln(_invalidBridgesProjectMessage);
      return null;
    }
    return (project: resolved, limitations: const <String>[]);
  }
  final detected = _detectPubWorkspace(root);
  return (project: detected.root ?? root, limitations: [?detected.limitation]);
}
