import 'dart:collection';
import 'dart:convert';

import '../core/tool_info.dart';

/// GRAPH-EXCHANGE bridge-facts 문서를 키 정렬 JSON으로 내보낸다.
///
/// [transport]가 없으면 기존 MethodChannel 버전 1 문서를 그대로 만들고,
/// 지정하면 해당 transport의 버전 2 문서를 만든다.
String exportBridgeFacts({
  required String project,
  required DateTime generatedAt,
  required List<Map<String, Object?>> facts,
  required List<String> limitations,
  int version = 1,
  String? transport,
}) {
  final validVersionTransport =
      version == 1 && transport == null ||
      version == 2 &&
          (transport == 'basic-message-channel' ||
              transport == 'event-channel');
  if (!validVersionTransport) {
    throw ArgumentError.value(
      version,
      'version',
      'version 1 requires no transport; version 2 requires '
          'basic-message-channel or event-channel transport',
    );
  }
  final document = <String, Object?>{
    'format': 'bridge-facts',
    'version': version,
    'tool': {'name': 'dartograph', 'version': toolVersion},
    'generatedAt': DateTime.fromMillisecondsSinceEpoch(
      generatedAt.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String(),
    'platform': 'dart',
    'target': facts.isEmpty ? null : 'flutter',
    'project': project,
    'facts': facts,
    'limitations': limitations,
  };
  if (transport != null) document['transport'] = transport;
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
