import 'dart:io';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prefix, postfix and compound property reads retain their declarations',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'compound-properties.',
      );
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/lib').create();
      await File('${root.path}/lib/main.dart').writeAsString('''
class Counter {
  int _prefix = 0;
  int _postfix = 0;
  int _compound = 0;
  int _unused = 0;
  bool step() => ++_prefix > 10;
  int post() => _postfix++;
  void add() => _compound += 2;
}
int _top = 0;
int top() => ++_top;
void main() {
  final counter = Counter();
  counter.step();
  counter.post();
  counter.add();
  top();
}
''');

      final result = await AnalyzerGraphIndex(
        userCacheEnvironment: const {},
      ).index(root.path);
      const library = 'project:lib/main.dart';
      bool reads(String source, String target) => result.graph.edges.any(
        (edge) =>
            edge.sourceId == '$library::$source' &&
            edge.targetId == '$library::$target' &&
            edge.kind == EdgeKind.reference,
      );
      // 독립 oracle은 위 Dart 소스의 읽기·쓰기 위치다. 제품 helper에서 기대
      // 간선을 만들지 않고 특히 값을 소비하는 전위 ++의 누락을 고정한다.
      expect(reads('Counter.step', 'Counter._prefix'), isTrue);
      expect(reads('Counter.post', 'Counter._postfix'), isTrue);
      expect(reads('Counter.add', 'Counter._compound'), isTrue);
      expect(reads('top', '_top'), isTrue);
      expect(
        result.graph.edges.where(
          (edge) =>
              edge.targetId == '$library::Counter._unused' &&
              edge.kind != EdgeKind.member,
        ),
        isEmpty,
      );
    },
  );
}
