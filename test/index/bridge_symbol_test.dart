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
    expect(invocations.map((f) => (f['location']! as Map)['path']), [
      'channel.dart',
      'linked/channel.dart',
    ]);
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

  test(
    'a channel field declared after its use still resolves within the class',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-order.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/channel.dart').writeAsString('''
import 'package:flutter/services.dart';
class Before {
  void go() => _c.invokeMethod('ping');
  static final _c = MethodChannel('before');
}
class After {
  static final _c = MethodChannel('after');
  void go() => _c.invokeMethod('ping');
}
''');

      final result = indexBridges(root.path);

      final invocations = result.facts
          .where((f) => f['kind'] == 'method-invoke')
          .toList();
      // 선언 순서만 다른 두 클래스가 같은 모양의 fact를 낸다.
      expect(invocations, hasLength(2));
      expect(invocations.map((f) => f['channel']), ['before', 'after']);
      final unresolved = result.limitations.any(
        (s) => s.startsWith('unresolved-receiver-invocations:'),
      );
      expect(unresolved, isFalse);
    },
  );

  test(
    'a class channel field shadows a same-named top-level channel regardless of order',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-shadow.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/channel.dart').writeAsString('''
import 'package:flutter/services.dart';
final _c = MethodChannel('top');
class Shadow {
  void go() => _c.invokeMethod('ping');
  static final _c = MethodChannel('inner');
}
''');

      final result = indexBridges(root.path);

      final invocation = result.facts.singleWhere(
        (f) => f['kind'] == 'method-invoke',
      );
      // 클래스 필드가 사용처보다 뒤에 선언돼도 동명 최상위 채널을 가린다.
      expect(invocation['channel'], 'inner');
    },
  );

  test(
    'an empty channel name skips only that fact and reports a limitation',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-empty.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/channel.dart').writeAsString('''
import 'package:flutter/services.dart';
final empty = MethodChannel('');
final real = MethodChannel('real');
void go() => real.invokeMethod('ping');
''');

      final result = indexBridges(root.path);

      // 빈 이름 channel-create는 건너뛰고 정상 채널만 남는다.
      final created = result.facts
          .where((f) => f['kind'] == 'channel-create')
          .map((f) => f['channel'])
          .toList();
      expect(created, ['real']);
      // 같은 파일의 정상 method-invoke는 영향을 받지 않는다.
      expect(
        result.facts.where((f) => f['kind'] == 'method-invoke'),
        hasLength(1),
      );
      expect(
        result.limitations.any((s) => s.startsWith('empty-bridge-names:')),
        isTrue,
      );
    },
  );

  test(
    'a class channel name resolves a const string declared after it',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-const-order.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/channel.dart').writeAsString('''
import 'package:flutter/services.dart';
class C {
  static final _c = MethodChannel(_name);
  static const _name = 'chan';
  void go() => _c.invokeMethod('ping');
}
''');

      final result = indexBridges(root.path);

      final invocation = result.facts.singleWhere(
        (f) => f['kind'] == 'method-invoke',
      );
      // const가 채널 뒤에서 선언돼도 정적으로 해석된다(최상위 2패스와 대칭).
      expect(invocation['channel'], 'chan');
      expect(invocation['dynamic'], isFalse);
    },
  );

  test(
    'mixin, enum, extension and extension type bodies are prescanned too',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-bodies.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/channel.dart').writeAsString('''
import 'package:flutter/services.dart';
mixin M {
  void go() => _c.invokeMethod('m');
  static final _c = MethodChannel('mchan');
}
enum E {
  a;
  void go() => _c.invokeMethod('e');
  static final _c = MethodChannel('echan');
}
extension X on int {
  void go() => _c.invokeMethod('x');
  static final _c = MethodChannel('xchan');
}
extension type Y(int v) {
  void go() => _c.invokeMethod('y');
  static final _c = MethodChannel('ychan');
}
''');

      final result = indexBridges(root.path);

      final channels = result.facts
          .where((f) => f['kind'] == 'method-invoke')
          .map((f) => f['channel']! as String)
          .toList();
      channels.sort();
      // 네 선언 본문 모두 필드가 사용처보다 뒤에 있어도 채널을 해결한다.
      expect(channels, ['echan', 'mchan', 'xchan', 'ychan']);
    },
  );

  test(
    'a later class field shadows a top-level const of the same name',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'bridge-shadow-const.',
      );
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/channel.dart').writeAsString('''
import 'package:flutter/services.dart';
const _name = 'top';
class C {
  static final _c = MethodChannel(_name);
  static final _name = 'inner';
  void go() => _c.invokeMethod('ping');
}
''');

      final result = indexBridges(root.path);

      final invocation = result.facts.singleWhere(
        (f) => f['kind'] == 'method-invoke',
      );
      // 클래스의 final `_name`(비-const)이 1패스에서 먼저 declare되어, 2패스 해석이
      // 최상위 'top'으로 잘못 귀속하지 않고 dynamic으로 남는다.
      expect(invocation['dynamic'], isTrue);
      expect(invocation['channel'], '_name');
    },
  );

  test(
    'a non-class body resolves a const channel name declared after it',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-mixin-const.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/channel.dart').writeAsString('''
import 'package:flutter/services.dart';
mixin M {
  static final _c = MethodChannel(_n);
  static const _n = 'mconst';
  void go() => _c.invokeMethod('m');
}
''');

      final result = indexBridges(root.path);

      final invocation = result.facts.singleWhere(
        (f) => f['kind'] == 'method-invoke',
      );
      // 비클래스 본문(mixin)에서도 2패스가 const를 먼저 등록해 정적으로 해석한다.
      expect(invocation['channel'], 'mconst');
      expect(invocation['dynamic'], isFalse);
    },
  );
}
