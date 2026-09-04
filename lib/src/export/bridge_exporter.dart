import 'dart:collection';
import 'dart:convert';

import '../core/tool_info.dart';

/// GRAPH-EXCHANGE 버전 1 문서를 키 정렬 JSON으로 내보낸다.
String exportBridgeFacts({
  required String project,
  required DateTime generatedAt,
  required List<Map<String, Object?>> facts,
  required List<String> limitations,
}) {
  final document = <String, Object?>{
    'format': 'bridge-facts',
    'version': 1,
    'tool': {'name': 'dartograph', 'version': toolVersion},
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'platform': 'dart',
    'target': facts.isEmpty ? null : 'flutter',
    'project': project,
    'facts': facts,
    'limitations': limitations,
  };
  return '${const JsonEncoder.withIndent('  ').convert(_sort(document))}\n';
}

Object? _sort(Object? value) {
  if (value is Map<String, Object?>) {
    return SplayTreeMap<String, Object?>.from(
      value.map((key, item) => MapEntry(key, _sort(item))),
    );
  }
  if (value is List) return value.map(_sort).toList();
  return value;
}
