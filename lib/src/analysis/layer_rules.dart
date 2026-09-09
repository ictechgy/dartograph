import 'package:yaml/yaml.dart';

import '../core/graph_edge.dart';
import '../core/graph_node.dart';
import '../core/graph_snapshot.dart';

/// YAML에서 읽은 레이어 정의와 허용·금지 규칙이다.
final class LayerRuleSet {
  const LayerRuleSet._(this.layers, this.rules);

  /// 먼저 일치하는 정의가 이기는 레이어 목록이다.
  final List<LayerDefinition> layers;

  /// 출발 레이어에 적용할 규칙 목록이다.
  final List<LayerRule> rules;

  /// 제한된 공개 스키마만 허용하며 YAML 문자열을 읽는다.
  factory LayerRuleSet.parse(String source) {
    final document = loadYaml(source);
    if (document is! YamlMap) {
      throw const FormatException('layer configuration must be a map');
    }
    _rejectUnknown(document, const {'layers', 'rules'}, 'configuration');
    final rawLayers = document['layers'];
    final rawRules = document['rules'];
    if (rawLayers is! YamlList) {
      throw const FormatException('layers must be a list');
    }
    if (rawRules is! YamlList) {
      throw const FormatException('rules must be a list');
    }
    final layers = rawLayers.map((value) {
      final map = _map(value, 'each layer');
      _rejectUnknown(map, const {'name', 'match'}, 'layer');
      return LayerDefinition(
        name: _string(map['name'], 'layer name'),
        patterns: _strings(map['match'], 'layer match'),
      );
    }).toList();
    final names = <String>{};
    for (final layer in layers) {
      if (!names.add(layer.name)) {
        throw FormatException('duplicate layer name: ${layer.name}');
      }
    }
    final rules = rawRules.map((value) {
      final map = _map(value, 'each rule');
      _rejectUnknown(map, const {'name', 'from', 'allow', 'deny'}, 'rule');
      final from = _string(map['from'], 'rule from');
      final hasAllow = map.containsKey('allow');
      final hasDeny = map.containsKey('deny');
      if (hasAllow == hasDeny) {
        throw const FormatException(
          'each rule requires exactly one of allow or deny',
        );
      }
      final targets = _strings(
        map[hasAllow ? 'allow' : 'deny'],
        'rule targets',
      );
      if (!names.contains(from) ||
          targets.any((target) => !names.contains(target))) {
        throw const FormatException('rules must reference declared layers');
      }
      return LayerRule(
        name: map['name'] == null
            ? hasAllow
                  ? '$from may only depend on allowed layers'
                  : '$from must not depend on ${targets.join(', ')}'
            : _string(map['name'], 'rule name'),
        from: from,
        targets: targets.toSet(),
        allow: hasAllow,
      );
    }).toList();
    return LayerRuleSet._(List.unmodifiable(layers), List.unmodifiable(rules));
  }
}

/// 문자열 후보에 glob 패턴을 적용하는 레이어다.
final class LayerDefinition {
  /// 레이어 이름과 순서가 있는 일치 패턴을 묶는다.
  const LayerDefinition({required this.name, required this.patterns});

  /// 설정에서 참조하는 안정적인 이름이다.
  final String name;

  /// 정점 ID와 소스 URI에 순서대로 적용할 glob 목록이다.
  final List<String> patterns;
}

/// 한 출발 레이어의 허용 목록 또는 금지 목록이다.
final class LayerRule {
  /// 허용 또는 금지 대상이 명시된 규칙을 만든다.
  const LayerRule({
    required this.name,
    required this.from,
    required this.targets,
    required this.allow,
  });

  /// 위반 보고에 쓰는 설명 이름이다.
  final String name;

  /// 규칙이 시작되는 레이어다.
  final String from;

  /// 허용하거나 금지할 대상 레이어다.
  final Set<String> targets;

  /// 참이면 [targets] 밖을 위반으로, 거짓이면 안을 위반으로 본다.
  final bool allow;

  /// 결정적인 JSON 필드 값을 만든다.
  Map<String, Object> toJson() => {
    'allow': allow,
    'from': from,
    'name': name,
    'targets': targets.toList()..sort(),
  };
}

/// 한 정점의 레이어 배치와 매치 근거, 그 레이어에서 출발하는 규칙이다.
final class LayerExplanation {
  /// 정점 ID와 존재 여부, 레이어 배치 근거를 묶는다.
  const LayerExplanation({
    required this.id,
    required this.known,
    required this.layer,
    required this.matchedPattern,
    required this.matchedCandidate,
    required this.rules,
  });

  /// 설명 대상 정점 ID다.
  final String id;

  /// 대상 ID가 분석 그래프에 실제로 존재하는지 나타낸다.
  final bool known;

  /// 배치된 레이어 이름이다. 어떤 레이어에도 매치되지 않으면 null이다.
  final String? layer;

  /// 배치를 결정한 glob 패턴이다. 매치되지 않으면 null이다.
  final String? matchedPattern;

  /// 패턴이 매치된 후보(정점 ID 또는 sourceUri)다. 매치되지 않으면 null이다.
  final String? matchedCandidate;

  /// [layer]에서 출발하는 규칙의 결정적 목록이다. 없으면 빈 목록이다.
  final List<LayerRule> rules;
}

/// 위반 경로와 판정에 사용된 소스·간선 근거다.
final class LayerViolation {
  /// 판정과 실제 간선·위치를 함께 보존하는 위반을 만든다.
  const LayerViolation({
    required this.ruleName,
    required this.fromLayer,
    required this.toLayer,
    required this.path,
    required this.edge,
    required this.source,
  });

  /// 위반한 규칙 이름이다.
  final String ruleName;

  /// 의존을 시작한 레이어다.
  final String fromLayer;

  /// 의존 대상 레이어다.
  final String toLayer;

  /// 현재 직접 위반을 재현하는 정점 경로다.
  final List<String> path;

  /// 위반을 입증하는 그래프 간선이다.
  final GraphEdge edge;

  /// 진단 위치를 제공하는 출발 정점이다.
  final GraphNode source;

  /// 리포터가 사용할 결정적인 값으로 바꾼다.
  Map<String, Object> toJson() => {
    'evidence': {
      if (source.column != null) 'column': source.column!,
      'edge': {
        'from': edge.sourceId,
        'kind': edge.kind.name,
        'to': edge.targetId,
      },
      if (source.line != null) 'line': source.line!,
      if (source.sourceUri != null) 'source': source.sourceUri!,
    },
    'fromLayer': fromLayer,
    'path': path,
    'rule': ruleName,
    'toLayer': toLayer,
  };
}

/// 정점을 레이어에 배치하고 사용 간선의 규칙 위반을 찾는다.
final class LayerRuleEvaluator {
  /// 파싱과 검증이 끝난 [ruleSet]의 평가기를 만든다.
  LayerRuleEvaluator(this.ruleSet);

  /// 평가할 파싱 완료 규칙이다.
  final LayerRuleSet ruleSet;

  // 패턴→RegExp 캐시: first-match 배치는 매치되지 않는 노드마다 전체 패턴을
  // 훑는데 매번 RegExp를 재컴파일했다(감사 P4 — 노드 × 레이어 × 패턴 회).
  // 컴파일 결과는 패턴 문자열이 결정하므로 캐시가 매치를 바꾸지 않는다.
  final Map<String, RegExp> _globCache = {};

  /// 각 위반에 직접 경로와 소스 위치를 붙여 결정적으로 반환한다.
  List<LayerViolation> evaluate(GraphSnapshot graph) {
    final nodes = {for (final node in graph.nodes) node.id: node};
    final assignments = <String, String?>{
      for (final node in graph.nodes) node.id: _layer(node),
    };
    final result = <LayerViolation>[];
    for (final edge in graph.edges.where((edge) => edge.kind.impliesUsage)) {
      final from = assignments[edge.sourceId];
      final to = assignments[edge.targetId];
      if (from == null || to == null || from == to) continue;
      for (final rule in ruleSet.rules.where((rule) => rule.from == from)) {
        final contains = rule.targets.contains(to);
        if ((rule.allow && contains) || (!rule.allow && !contains)) continue;
        result.add(
          LayerViolation(
            ruleName: rule.name,
            fromLayer: from,
            toLayer: to,
            path: List.unmodifiable([edge.sourceId, edge.targetId]),
            edge: edge,
            source: nodes[edge.sourceId]!,
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }

  /// [id]의 레이어 배치와 매치 근거, 그 레이어에서 출발하는 규칙을 답한다.
  ///
  /// 정점이 그래프에 없으면 `known: false`다. 있으면 어떤 레이어에도 매치되지
  /// 않을 수 있고(layer·matchedPattern·matchedCandidate가 null), 그때 출발
  /// 규칙도 빈 목록이다. 규칙은 설정 순서대로 결정적으로 실린다.
  LayerExplanation explainNode(GraphSnapshot graph, String id) {
    GraphNode? node;
    for (final candidate in graph.nodes) {
      if (candidate.id == id) {
        node = candidate;
        break;
      }
    }
    if (node == null) {
      return LayerExplanation(
        id: id,
        known: false,
        layer: null,
        matchedPattern: null,
        matchedCandidate: null,
        rules: const [],
      );
    }
    final assignment = _assignment(node);
    final layer = assignment?.layer;
    final rules = layer == null
        ? const <LayerRule>[]
        : ruleSet.rules
              .where((rule) => rule.from == layer)
              .toList(growable: false);
    return LayerExplanation(
      id: id,
      known: true,
      layer: layer,
      matchedPattern: assignment?.pattern,
      matchedCandidate: assignment?.candidate,
      rules: rules,
    );
  }

  String? _layer(GraphNode node) => _assignment(node)?.layer;

  /// first-match 레이어·패턴·후보를 찾는다. 순회는 layer→pattern→candidate로
  /// `_layer`가 예전에 `candidates.any`로 찾던 것과 같은 first-match라 배치가
  /// 바뀌지 않고, 매치된 패턴·후보만 추가로 드러낸다.
  ({String layer, String pattern, String candidate})? _assignment(
    GraphNode node,
  ) {
    final candidates = <String>[
      node.id,
      if (node.sourceUri != null) node.sourceUri!,
    ];
    for (final layer in ruleSet.layers) {
      for (final pattern in layer.patterns) {
        final regex = _globCache.putIfAbsent(pattern, () => _glob(pattern));
        for (final candidate in candidates) {
          if (regex.hasMatch(candidate)) {
            return (layer: layer.name, pattern: pattern, candidate: candidate);
          }
        }
      }
    }
    return null;
  }
}

RegExp _glob(String pattern) {
  final buffer = StringBuffer('^');
  for (var index = 0; index < pattern.length; index++) {
    final character = pattern[index];
    if (character == '*' &&
        index + 1 < pattern.length &&
        pattern[index + 1] == '*') {
      buffer.write('.*');
      index++;
    } else if (character == '*') {
      buffer.write('[^/]*');
    } else if (character == '?') {
      buffer.write('[^/]');
    } else {
      buffer.write(RegExp.escape(character));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

YamlMap _map(Object? value, String label) {
  if (value is! YamlMap) throw FormatException('$label must be a map');
  return value;
}

String _string(Object? value, String label) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$label must be a non-empty string');
  }
  return value;
}

List<String> _strings(Object? value, String label) {
  if (value is! YamlList ||
      value.any((item) => item is! String || item.isEmpty)) {
    throw FormatException('$label must be a list of strings');
  }
  return value.cast<String>().toList(growable: false);
}

void _rejectUnknown(YamlMap map, Set<String> allowed, String label) {
  for (final key in map.keys) {
    if (key is! String || !allowed.contains(key)) {
      throw FormatException('unknown $label key: $key');
    }
  }
}
