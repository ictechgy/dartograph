import 'dart:io';

import 'package:dartograph/src/index/http_wrappers.dart';
import 'package:dartograph/src/index/route_call_index.dart';

import '../support/route_fixture_support.dart';

/// `wrapper.location` 벡터를 실제 스캐너로 실행한다: 여러 줄에 걸친 선언된
/// 래퍼 호출이 호출식 시작 줄을 보고하는지 본다.
Future<int> probeWrapperCallLine({
  required int callStartLine,
  required int methodArgumentLine,
  required int pathArgumentLine,
}) async {
  final root = await Directory.systemTemp.createTemp('dartograph-probe');
  try {
    final lines = List.filled(pathArgumentLine + 3, '');
    lines[callStartLine - 1] = 'Future<void> caller() => request(';
    lines[methodArgumentLine - 1] = "  method: 'GET',";
    lines[pathArgumentLine - 1] = "  path: '/x',";
    lines[pathArgumentLine] = ');';
    lines[pathArgumentLine + 1] =
        'Future<void> request({required String method, '
        'required String path}) async {}';
    await writeRoutePackage(root, 'probe', {
      'lib/probe.dart': lines.join('\n'),
    });
    const wrapper = HttpWrapperDeclaration(
      position: 0,
      language: 'dart',
      kind: 'function',
      owner: 'package:probe/probe.dart',
      name: 'request',
      methodArg: WrapperArgument(label: 'method'),
      pathArg: WrapperArgument(label: 'path'),
      pathAnchor: 'root',
    );
    final result = await indexRouteCalls(root.path, wrappers: [wrapper]);
    final fact = result.facts.single;
    if (fact['method'] != 'GET') throw StateError('wrapper verb not bound');
    return (fact['location']! as Map<String, Object?>)['line']! as int;
  } finally {
    await root.delete(recursive: true);
  }
}
