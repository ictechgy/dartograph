import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/analysis/reachability_analyzer.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

/// 보존·사용 간선이 빠져 살아 있는 선언이 미도달로 보고되던 회귀를 실제
/// analyzer로 고정한다. 기대값은 아래 Dart 소스의 읽기·쓰기·재정의 위치를
/// 손으로 옮긴 것이다 — 제품 helper로 정답을 계산하지 않는다.
const _source = '''
abstract class Failure {
  String get message;
}

class NetworkFailure implements Failure {
  const NetworkFailure(this.message, this.unusedDetail);
  @override
  final String message;
  final String unusedDetail;
}

class Native {
  @pragma('vm:entry-point')
  static int entryCounter = 0;
  static int plainCounter = 0;
}

class Counter {
  int _c = 0;
  int get count => _c;
  set count(int v) {
    _c = v;
    _notify();
  }

  set neverAssigned(int v) {}

  void _notify() {}
}

const _devUrl = 'https://dev';
const _prodUrl = 'https://prod';
const _unusedUrl = 'https://unused';

enum Env {
  dev(_devUrl),
  prod(_prodUrl);

  const Env(this.baseUrl);
  final String baseUrl;
}

@pragma('vm:entry-point', 'call')
void callEntry() {}

@pragma('vm:entry-point', true)
void trueEntry() {}

@pragma('vm:entry-point', false)
void disabledEntry() {}

class Model {}

class Event {}

class Unaliased {}

typedef Models = List<Model>;
typedef EventCallback = void Function(Event event);

Models loadModels() => [];
void listen(EventCallback callback) {}

void main() {
  final Failure failure = NetworkFailure('x', 'y');
  print(failure.message);
  final counter = Counter();
  counter.count = 3;
  print(Env.values.byName('dev'));
  print(loadModels().length);
  listen((_) {});
}
''';

void main() {
  late AnalyzerGraphResult result;
  const library = 'project:lib/main.dart';

  setUpAll(() async {
    final root = await Directory.systemTemp.createTemp('usage-regressions.');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/main.dart').writeAsString(_source);
    result = await AnalyzerGraphIndex(
      userCacheEnvironment: const {},
    ).index(root.path);
  });

  bool hasEdge(String source, String target, EdgeKind kind) =>
      result.graph.edges.any(
        (edge) =>
            edge.sourceId == '$library::$source' &&
            edge.targetId == '$library::$target' &&
            edge.kind == kind,
      );

  RetentionReason? rootOf(String name) =>
      result.retentionRoots['$library::$name'];

  Set<String> deadNames() {
    final reachability = ReachabilityAnalyzer().analyze(
      result.graph.snapshot(),
      roots: result.retentionRoots,
    );
    return {
      for (final finding in reachability.deadDeclarations)
        finding.id.substring('$library::'.length),
    };
  }

  test('a field that implements an inherited getter is an override', () {
    expect(rootOf('NetworkFailure.message'), RetentionReason.overrideContract);
    expect(
      hasEdge('NetworkFailure.message', 'Failure.message', EdgeKind.override),
      isTrue,
    );
    // 재정의가 아닌 필드는 계속 보존 근거가 없다.
    expect(rootOf('NetworkFailure.unusedDetail'), isNull);
  });

  test('annotations on the enclosing field declaration are read', () {
    expect(rootOf('Native.entryCounter'), RetentionReason.vmEntryPoint);
    expect(rootOf('Native.plainCounter'), isNull);
  });

  test('assigning an explicit setter uses the setter declaration', () {
    expect(hasEdge('main', 'Counter.count=', EdgeKind.reference), isTrue);
    // 기존 getter/변수 간선도 유지한다 — 보존을 좁히지 않는다.
    expect(hasEdge('main', 'Counter.count', EdgeKind.reference), isTrue);
    final dead = deadNames();
    expect(dead, isNot(contains('Counter.count=')));
    expect(dead, isNot(contains('Counter._notify')));
    expect(dead, contains('Counter.neverAssigned='));
  });

  test('vm:entry-point pragmas with a second argument are roots', () {
    expect(rootOf('callEntry'), RetentionReason.vmEntryPoint);
    expect(rootOf('trueEntry'), RetentionReason.vmEntryPoint);
    // 리터럴 false는 진입점이 아니라고 선언한 것이다.
    expect(rootOf('disabledEntry'), isNull);
  });

  test('a typedef use references the declarations in its aliased type', () {
    expect(hasEdge('loadModels', 'Model', EdgeKind.reference), isTrue);
    expect(hasEdge('listen', 'Event', EdgeKind.reference), isTrue);
    final dead = deadNames();
    expect(dead, isNot(contains('Model')));
    expect(dead, isNot(contains('Event')));
    expect(dead, contains('Unaliased'));
  });

  test('enum constant arguments stay reachable with their enum', () {
    final dead = deadNames();
    expect(dead, isNot(contains('_devUrl')));
    expect(dead, isNot(contains('_prodUrl')));
    expect(dead, contains('_unusedUrl'));
  });
}
