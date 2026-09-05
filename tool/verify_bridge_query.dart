import 'dart:convert';
import 'dart:io';
import 'package:dartograph/src/index/bridge_index.dart';
import 'package:dartograph/src/export/bridge_exporter.dart';

/// 설치된 isthmus에 합성 양방향 근거를 전달해 심볼과 위치의 보존을 검증한다.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/verify_bridge_query.dart <isthmus-main.js>',
    );
    exitCode = 64;
    return;
  }
  final root = await Directory.systemTemp.createTemp('bridge-query.');
  try {
    await File('${root.path}/camera.dart').writeAsString('''
import 'package:flutter/services.dart';
final channel = MethodChannel('camera');
class Camera {
  void takePhoto() => channel.invokeMethod('takePhoto');
}
''');
    final project = await root.resolveSymbolicLinks();
    final index = indexBridges(project);
    final dartFacts = File('${root.path}/dart.json');
    await dartFacts.writeAsString(
      exportBridgeFacts(
        project: project,
        generatedAt: DateTime.now().toUtc(),
        facts: index.facts,
        limitations: index.limitations,
      ),
    );
    final swiftFacts = File('${root.path}/swift.json');
    // Swift 컴파일러 실행을 대체하는 합성 교환 문서다. 실제 USR이라고 주장하지 않는다.
    final native = {
      'format': 'bridge-facts',
      'version': 1,
      'tool': {'name': 'synthetic-fixture', 'version': '1'},
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'platform': 'swift',
      'target': 'flutter',
      'project': project,
      'limitations': <String>[],
      'facts': [
        {
          'kind': 'method-handle',
          'channel': 'camera',
          'method': 'takePhoto',
          'dynamic': false,
          'symbol': {
            'qualifiedName': 'CameraHandler.handle',
            'usr': 's:fixture',
          },
          'location': {'path': 'ios/Camera.swift', 'line': 12, 'column': 3},
        },
      ],
    };
    await swiftFacts.writeAsString(jsonEncode(native));
    final result = await Process.run('node', [
      arguments.single,
      'query',
      'takePhoto',
      dartFacts.path,
      swiftFacts.path,
    ]);
    if (result.exitCode != 0) throw StateError('isthmus query failed');
    final query = jsonDecode(result.stdout as String) as Map;
    final value = query['result'] as Map;
    final caller = (value['usedBy'] as List).single as Map;
    final handler = (value['dependsOn'] as List).single as Map;
    if (query['status'] != 'found' ||
        (caller['symbol'] as Map)['qualifiedName'] != 'Camera.takePhoto' ||
        (caller['location'] as Map)['line'] != 4 ||
        (handler['symbol'] as Map)['usr'] != 's:fixture' ||
        (handler['location'] as Map)['line'] != 12) {
      throw StateError('Cross-language evidence changed');
    }
    stdout.writeln(
      'Bridge query roundtrip passed: Dart declaration and both source locations preserved.',
    );
  } finally {
    await root.delete(recursive: true);
  }
}
