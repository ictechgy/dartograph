import 'dart:io';
import 'package:dartograph/src/index/bridge_index.dart';
import 'package:test/test.dart';

void main() {
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
