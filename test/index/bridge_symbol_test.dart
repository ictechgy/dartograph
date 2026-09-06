import 'dart:io';
import 'package:dartograph/src/index/bridge_index.dart';
import 'package:test/test.dart';

void main() {
  test('linked Dart sources are scanned for bridge facts', () async {
    final workspace = await Directory.systemTemp.createTemp('bridge-symlink.');
    addTearDown(() => workspace.delete(recursive: true));
    // 링크 대상을 패키지 루트 밖에 두어 링크 자체를 건너뛰면 사실이 사라지게 한다.
    final outside = Directory('${workspace.path}/outside');
    final root = Directory('${workspace.path}/package');
    await outside.create();
    await root.create();
    await File('${outside.path}/channel.dart').writeAsString('''
import 'package:flutter/services.dart';
final channel = MethodChannel('camera');
class Camera {
  void takePhoto() => channel.invokeMethod('takePhoto');
}
''');
    await Link('${root.path}/channel.dart').create('../outside/channel.dart');
    // 디렉터리 링크와 순환 가드도 같은 픽스처에서 고정한다.
    await Link('${root.path}/linked').create('../outside');
    await Link('${outside.path}/self').create('../outside');

    final result = indexBridges(root.path);

    final invocations = result.facts
        .where((f) => f['kind'] == 'method-invoke')
        .toList();
    // 파일 링크(channel.dart)와 디렉터리 링크(linked/) 양쪽에서 사실이 나온다.
    // 순환 링크(outside/self)는 한 번만 따라가므로 경로가 늘어나지 않는다.
    expect(
      invocations.map((f) => (f['location']! as Map)['path']),
      ['channel.dart', 'linked/channel.dart'],
    );
    for (final invocation in invocations) {
      expect(invocation['channel'], 'camera');
      expect(invocation['method'], 'takePhoto');
    }
  });

  test(
    'unsupported enclosing constructors retain location and report missing symbol',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-symbol.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/channel.dart').writeAsString('''
import 'package:flutter/services.dart';
final channel = MethodChannel('camera');
class Camera { Camera() { channel.invokeMethod('takePhoto'); } }
''');
      final result = indexBridges(root.path);
      expect(
        result.facts.where((f) => f['kind'] == 'method-invoke'),
        hasLength(1),
      );
      expect(
        result.limitations.any((s) => s.startsWith('missing-caller-symbols:')),
        isTrue,
      );
    },
  );
  test(
    'bridge invocation carries its enclosing Dart declaration without inventing a USR',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-symbol.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/channel.dart').writeAsString('''
import 'package:flutter/services.dart';
final channel = MethodChannel('camera');
class Camera {
  void takePhoto() => channel.invokeMethod('takePhoto');
}
''');
      final result = indexBridges(root.path);
      final invocation = result.facts.singleWhere(
        (f) => f['kind'] == 'method-invoke',
      );
      expect(invocation['symbol'], {'qualifiedName': 'Camera.takePhoto'});
      expect((invocation['location'] as Map)['line'], 4);
    },
  );
}
