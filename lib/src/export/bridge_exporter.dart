import 'dart:collection';
import 'dart:convert';

import '../core/tool_info.dart';

/// GRAPH-EXCHANGE bridge-facts 문서를 키 정렬 JSON으로 내보낸다.
///
/// [transport]가 없으면 기존 MethodChannel 버전 1 문서를 그대로 만들고,
/// 지정하면 해당 transport의 버전 2 문서를 만든다. [target]은 사실이 있을 때
/// 싣는 조인 도메인이다 — `schema`는 `persistence` 버전 1 문서를 만든다.
String exportBridgeFacts({
  required String project,
  required DateTime generatedAt,
  required List<Map<String, Object?>> facts,
  required List<String> limitations,
  int version = 1,
  String? transport,
  String target = 'flutter',
}) {
  final validVersionTransport =
      version == 1 && transport == null ||
      version == 2 &&
          (transport == 'basic-message-channel' ||
              transport == 'event-channel');
  // persistence는 버전 1 계약에만 있다 — v2 transport 문서와 섞지 않는다.
  if (!validVersionTransport ||
      (target != 'flutter' && (target != 'persistence' || version != 1))) {
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
    'target': facts.isEmpty ? null : target,
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

/// isthmus http 도메인의 호출 측 문서(`target: "http"`, `roles: ["client"]`)를
/// 키 정렬 JSON으로 내보낸다.
///
/// 사실이 0건이어도 target을 `http`로 둔다 — roles가 있는 0건 문서는 "스캔했으나
/// 호출 없음"이다(GRAPH-EXCHANGE http 한정 예외). [includeTests]는
/// `sourceSets.tests`로 테스트 소스 스캔 여부를 선언한다. [service]는 문서 수준
/// 서비스 신원이다.
String exportRouteFacts({
  required String project,
  required DateTime generatedAt,
  required List<Map<String, Object?>> facts,
  required List<String> limitations,
  required bool includeTests,
  String? service,
}) {
  final document = <String, Object?>{
    'format': 'bridge-facts',
    'version': 1,
    'tool': {'name': 'dartograph', 'version': toolVersion},
    'generatedAt': DateTime.fromMillisecondsSinceEpoch(
      generatedAt.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String(),
    'platform': 'dart',
    'target': 'http',
    'roles': const ['client'],
    'sourceSets': {'tests': includeTests ? 'included' : 'excluded'},
    'service': ?service,
    'project': project,
    'facts': facts,
    'limitations': limitations,
  };
  return '${const JsonEncoder.withIndent('  ').convert(_sort(document))}\n';
}
