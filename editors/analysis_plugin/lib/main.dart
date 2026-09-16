import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/graph_rules.dart';
import 'src/ignore_fix.dart';

/// 분석 서버가 로드하는 플러그인 진입점이다 — `plugin` 최상위 변수를 찾는다.
final plugin = DartographPlugin();

/// dartograph 그래프 발견을 진단과 quick fix로 노출하는 플러그인이다.
class DartographPlugin extends Plugin {
  @override
  String get name => 'dartograph';

  @override
  void register(PluginRegistry registry) {
    registry
      ..registerWarningRule(DeadCodeRule())
      ..registerWarningRule(DuplicateBlockRule())
      ..registerFixForRule(DeadCodeRule.code, AddDartographIgnore.new);
  }
}
