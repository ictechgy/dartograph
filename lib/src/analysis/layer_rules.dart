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
  const LayerRuleEvaluator(this.ruleSet);

  /// 평가할 파싱 완료 규칙이다.
  final LayerRuleSet ruleSet;

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

  String? _layer(GraphNode node) {
    final candidates = <String>[
      node.id,
      if (node.sourceUri != null) node.sourceUri!,
    ];
    for (final layer in ruleSet.layers) {
      for (final pattern in layer.patterns) {
        if (candidates.any((candidate) => _glob(pattern).hasMatch(candidate))) {
          return layer.name;
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
