import 'dart:io';

import 'package:dartograph/src/index/bridge_index.dart';
import 'package:test/test.dart';

void main() {
  test('reports dart:ffi imports as uncovered interop evidence', () async {
    final root = await Directory.systemTemp.createTemp('bridge-ffi.');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/ffi_side.dart').writeAsString(r'''
import 'dart:ffi';
import 'package:flutter/services.dart';

final channel = MethodChannel('battery');

class Api {
  void call() {
    channel.invokeMethod('getBatteryLevel');
  }
}
''');

    final result = indexBridges(root.path);

    expect(result.facts, isNotEmpty);
    expect(
      result.limitations,
      contains(
        'unscanned-ffi-interop: 1 Dart source file imports '
        'dart:ffi/JNI interop outside channel join coverage',
      ),
    );
  });

  test('counts FFI files even without Flutter channel imports', () async {
    final root = await Directory.systemTemp.createTemp('bridge-ffi.');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/jni_side.dart').writeAsString(r'''
import 'package:jni/jni.dart';

class Native {
  void bind() {}
}
''');

    final result = indexBridges(root.path);

    expect(result.facts, isEmpty);
    expect(
      result.limitations,
      contains(
        'unscanned-ffi-interop: 1 Dart source file imports '
        'dart:ffi/JNI interop outside channel join coverage',
      ),
    );
  });

  test('does not flag ordinary dart imports as FFI interop', () async {
    final root = await Directory.systemTemp.createTemp('bridge-ffi.');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/plain.dart').writeAsString(r'''
import 'dart:async';
import 'package:flutter/services.dart';

final channel = MethodChannel('battery');
''');

    final result = indexBridges(root.path);

    expect(
      result.limitations
          .where((limitation) => limitation.startsWith('unscanned-ffi-interop')),
      isEmpty,
    );
  });
}
