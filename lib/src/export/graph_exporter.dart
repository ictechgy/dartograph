import 'dart:convert';

import '../core/graph_snapshot.dart';

/// 그래프 사실을 결정론적인 교환 형식으로 직렬화한다.
abstract final class GraphExporter {
  /// 정렬된 키와 배열을 쓰는 JSON 문서를 만든다.
  static String json(
    GraphSnapshot graph, {
    Iterable<String> limitations = const [],
  }) {
    final value = <String, Object>{
      'edges': [
        for (final edge in graph.edges)
          <String, Object>{
            'kind': edge.kind.name,
            'source': edge.sourceId,
            'target': edge.targetId,
          },
      ],
      'limitations': limitations.toList()..sort(),
      'nodes': [
        for (final node in graph.nodes)
          <String, Object>{
            if (node.column != null) 'column': node.column!,
            'id': node.id,
            'isAbstract': node.isAbstract,
            'isTypeDeclaration': node.isTypeDeclaration,
            if (node.line != null) 'line': node.line!,
            if (node.sourceUri != null) 'sourceUri': node.sourceUri!,
            'synthesized': node.synthesized,
          },
      ],
    };
    return '${jsonEncode(value)}\n';
  }

  /// Graphviz가 읽는 DOT 문서를 만든다.
  static String dot(
    GraphSnapshot graph, {
    Iterable<String> limitations = const [],
  }) {
    final out = StringBuffer('digraph dartograph {\n');
    for (final limitation in limitations.toList()..sort()) {
      out.writeln('  // limitation: ${_escape(limitation)}');
    }
    for (final node in graph.nodes) {
      out.writeln(
        '  "${_escape(node.id)}"${node.synthesized ? ' [style=dashed]' : ''};',
      );
    }
    for (final edge in graph.edges) {
      out.writeln(
        '  "${_escape(edge.sourceId)}" -> "${_escape(edge.targetId)}" [label="${edge.kind.name}"];',
      );
    }
    return '${out.toString()}}\n';
  }

  /// Mermaid flowchart 문서를 안정적인 순번 ID로 만든다.
  static String mermaid(
    GraphSnapshot graph, {
    Iterable<String> limitations = const [],
  }) {
    final out = StringBuffer('flowchart LR\n');
    for (final limitation in limitations.toList()..sort()) {
      out.writeln('  %% limitation: ${_escapeMermaid(limitation)}');
    }
    final ids = <String, String>{};
    for (var index = 0; index < graph.nodes.length; index++) {
      final node = graph.nodes[index];
      ids[node.id] = 'n$index';
      out.writeln('  n$index["${_escapeMermaid(node.id)}"]');
    }
    for (final edge in graph.edges) {
      out.writeln(
        '  ${ids[edge.sourceId]} -->|${edge.kind.name}| ${ids[edge.targetId]}',
      );
    }
    return out.toString();
  }

  static String _escape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');

  /// Mermaid 라벨은 HTML 엔티티로 escape한다. DOT용 [_escape](백슬래시)는
  /// `<no-library>`·`<unnamed-extension@...>`처럼 dartograph가 스스로 만든 노드 ID를
  /// Mermaid가 HTML 태그로 오해하게 만든다.
  static String _escapeMermaid(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
