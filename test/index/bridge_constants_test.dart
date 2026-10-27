import 'dart:io';

import 'package:dartograph/src/index/bridge_index.dart';
import 'package:test/test.dart';

void main() {
  Future<Directory> fixture(Map<String, String> sources) async {
    final root = await Directory.systemTemp.createTemp('bridge-constants.');
    addTearDown(() => root.delete(recursive: true));
    for (final entry in sources.entries) {
      final file = File('${root.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    return root;
  }

  List<Map<String, Object?>> calls(BridgeIndexResult result) =>
      result.facts.where((fact) => fact['kind'] == 'method-invoke').toList();

  test(
    'relative imports resolve Flutter app channel and method constants',
    () async {
      final root = await fixture({
        'lib/constants.dart': '''
const nativeSupportChannelName = channelAlias;
const channelAlias = 'com.example.android_hardware_smoke_test/native_support';
const methodImpellerBackend = 'impeller_backend';
''',
        'lib/main.dart': '''
import 'package:flutter/services.dart';
import 'constants.dart';
class NativeSupport {
  static const _nativeChannel = MethodChannel(nativeSupportChannelName);
  void query() => _nativeChannel.invokeMethod<String>(methodImpellerBackend);
}
''',
      });
      final result = indexBridges(root.path);
      final call = calls(result).single;
      expect(
        call['channel'],
        'com.example.android_hardware_smoke_test/native_support',
      );
      expect(call['method'], 'impeller_backend');
      expect(call['dynamic'], isFalse);
      expect(call['symbol'], {'qualifiedName': 'NativeSupport.query'});
      expect((call['location'] as Map)['path'], 'lib/main.dart');
      expect(
        result.limitations,
        contains(startsWith('flutter-services-provenance-unverified:')),
      );
      expect(indexBridges(root.path).facts, result.facts);
    },
  );

  test(
    'prefixed imports and filtered re-exports preserve declaration identity',
    () async {
      final root = await fixture({
        'names.dart':
            "const channel = 'native'; const method = 'ping'; const hidden = 'wrong';",
        'left.dart': "export 'names.dart' show channel, method;",
        'right.dart': "export 'names.dart' hide hidden;",
        'barrel.dart': "export 'left.dart'; export 'right.dart';",
        'main.dart': '''
import 'package:flutter/services.dart';
import 'barrel.dart' as names show channel, method;
final c = MethodChannel(names.channel);
void go() => c.invokeMethod(names.method);
''',
      });
      final call = calls(indexBridges(root.path)).single;
      expect(call['channel'], 'native');
      expect(call['method'], 'ping');
      expect(call['dynamic'], isFalse);
    },
  );

  test(
    'self package imports resolve only files inside the scanned source set',
    () async {
      final root = await fixture({
        'pubspec.yaml': 'name: source_app\nenvironment:\n  sdk: ^3.11.0\n',
        'lib/names.dart':
            "const channel = 'self-package'; const method = 'ping';",
        'lib/main.dart': '''
import 'package:flutter/services.dart';
import 'package:source_app/names.dart';
final c = MethodChannel(channel);
void go() => c.invokeMethod(method);
''',
      });
      final call = calls(indexBridges(root.path)).single;
      expect(call['channel'], 'self-package');
      expect(call['method'], 'ping');
      expect(call['dynamic'], isFalse);
    },
  );

  test(
    'ambiguous imports stay dynamic even when their literal values match',
    () async {
      final root = await fixture({
        'one.dart': "const channel = 'same'; const method = 'ping';",
        'two.dart': "const channel = 'same'; final method = 'ping';",
        'main.dart': '''
import 'package:flutter/services.dart';
import 'one.dart';
import 'two.dart';
final c = MethodChannel(channel);
void go() => c.invokeMethod(method);
''',
      });
      final result = indexBridges(root.path);
      final call = calls(result).single;
      expect(call['channel'], 'channel');
      expect(call['method'], 'method');
      expect(call['dynamic'], isTrue);
      expect(result.limitations, contains(startsWith('dynamic-method-names:')));
    },
  );

  test(
    'local declarations and parameters shadow imported constants and prefixes',
    () async {
      final root = await fixture({
        'names.dart': "const channel = 'import'; const method = 'ping';",
        'main.dart': '''
import 'package:flutter/services.dart';
import 'names.dart';
import 'names.dart' as names;
const channel = 'own';
final c = MethodChannel(channel);
void normal() => c.invokeMethod(method);
void parameter(String method) => c.invokeMethod(method);
void prefix(Object names) => c.invokeMethod(names.method);
class Shadow {
  final method = 'mutable';
  void go() => c.invokeMethod(method);
}
''',
      });
      final result = calls(indexBridges(root.path));
      expect(result.map((fact) => fact['channel']), everyElement('own'));
      expect(result.map((fact) => fact['dynamic']), [false, true, true, true]);
      expect(result.map((fact) => fact['method']), [
        'ping',
        'method',
        'names.method',
        'method',
      ]);
    },
  );

  test('show and hide combinators do not expose hidden names', () async {
    final root = await fixture({
      'names.dart': "const channel = 'native'; const method = 'ping';",
      'barrel.dart': "export 'names.dart' hide method;",
      'main.dart': '''
import 'package:flutter/services.dart';
import 'barrel.dart';
import 'names.dart' as names show channel hide method;
final c = MethodChannel(channel);
void go() => c.invokeMethod(names.method);
''',
    });
    final call = calls(indexBridges(root.path)).single;
    expect(call['channel'], 'native');
    expect(call['method'], 'names.method');
    expect(call['dynamic'], isTrue);
  });

  test(
    'cycles terminate without losing reachable unambiguous constants',
    () async {
      final root = await fixture({
        'one.dart':
            "export 'two.dart'; const channel = 'cyclic-export'; const a = b; const b = a;",
        'two.dart': "export 'one.dart'; const method = 'ping';",
        'main.dart': '''
import 'package:flutter/services.dart';
import 'one.dart';
final c = MethodChannel(channel);
void go() => c.invokeMethod(method);
void cycle() => c.invokeMethod(a);
''',
      });
      final result = calls(indexBridges(root.path));
      expect(result.first['channel'], 'cyclic-export');
      expect(result.first['method'], 'ping');
      expect(result.first['dynamic'], isFalse);
      expect(result.last['method'], 'a');
      expect(result.last['dynamic'], isTrue);
    },
  );

  test(
    'conditional, deferred, private and mutable names remain dynamic',
    () async {
      final root = await fixture({
        'names.dart':
            "const channel = 'native'; const method = 'ping'; const _private = 'secret'; final mutable = 'now';",
        'other.dart': "const channel = 'other';",
        'main.dart': '''
import 'package:flutter/services.dart';
import 'names.dart' if (dart.library.io) 'other.dart' show channel;
import 'names.dart' deferred as later;
import 'names.dart' as names;
final c = MethodChannel(channel);
void conditional() => c.invokeMethod('ping');
void deferred() => c.invokeMethod(later.method);
void private() => c.invokeMethod(names._private);
void mutable() => c.invokeMethod(names.mutable);
''',
      });
      final result = indexBridges(root.path);
      expect(
        calls(result).map((fact) => fact['dynamic']),
        everyElement(isTrue),
      );
      expect(calls(result).map((fact) => fact['method']), [
        'ping',
        'later.method',
        'names._private',
        'names.mutable',
      ]);
    },
  );

  test(
    'missing and out-of-scope sources remain dynamic and report incompleteness',
    () async {
      final root = await fixture({
        'names.dart': "const channel = 'outside'; const method = 'outside';",
        'selected/main.dart': '''
import 'package:flutter/services.dart';
import '../names.dart';
import 'missing.dart';
final c = MethodChannel(channel);
void go() => c.invokeMethod(method);
''',
      });
      final result = indexBridges('${root.path}/selected');
      expect(calls(result).single['dynamic'], isTrue);
      expect(
        result.limitations,
        contains(startsWith('constant-imports-unresolved:')),
      );
    },
  );

  test(
    'test mock constructors retain source evidence instead of being suppressed',
    () async {
      final root = await fixture({
        'test/widget_test.dart': '''
import 'package:flutter/services.dart';
void setUp() {
  messenger.setMockMethodCallHandler(const MethodChannel('flutter/platform_views_2'), (call) async => null);
}
''',
      });
      final result = indexBridges(root.path);
      expect(result.facts.single['channel'], 'flutter/platform_views_2');
      expect(
        (result.facts.single['location'] as Map)['path'],
        'test/widget_test.dart',
      );
    },
  );

  test(
    'observed reassignment does not resurrect a resolved imported constant',
    () async {
      final root = await fixture({
        'names.dart': "const method = 'ping';",
        'main.dart': '''
import 'package:flutter/services.dart';
import 'names.dart';
import 'names.dart' as names;
final c = MethodChannel('native');
void go() {
  c.invokeMethod(method);
  method = runtimeValue;
  c.invokeMethod(method);
  names.method = runtimeValue;
  c.invokeMethod(names.method);
}
''',
      });
      final result = calls(indexBridges(root.path));
      // 이 입력은 const 쓰기 때문에 의미 오류지만 parse-only 스캐너가 안전하게
      // 강등해야 한다. target 코드나 semantic analyzer를 실행한 근거는 아니다.
      expect(result.map((fact) => fact['dynamic']), [false, true, true]);
      expect(result.map((fact) => fact['method']), [
        'ping',
        'method',
        'names.method',
      ]);
    },
  );

  test(
    'const aliases support bounded string concatenation without execution',
    () async {
      final root = await fixture({
        'names.dart': '''
const channel = ('native/' + suffix);
const suffix = 'support';
const method = 'im' 'peller_backend';
final dynamicName = readFromNetwork();
''',
        'main.dart': '''
import 'package:flutter/services.dart';
import 'names.dart';
final c = MethodChannel(channel);
void go() => c.invokeMethod(method);
void dynamicCall() => c.invokeMethod(dynamicName);
''',
      });
      final result = calls(indexBridges(root.path));
      expect(result.first['channel'], 'native/support');
      expect(result.first['method'], 'impeller_backend');
      expect(result.first['dynamic'], isFalse);
      expect(result.last['method'], 'dynamicName');
      expect(result.last['dynamic'], isTrue);
    },
  );

  test(
    'incomplete libraries and excessive constant chains remain explicit',
    () async {
      final chain = [
        for (var index = 0; index < 100; index++)
          'const a$index = a${index + 1};',
      ].join('\n');
      final root = await fixture({
        'chain.dart': "$chain\nconst a100 = 'too-deep';",
        'broken.dart': "const method = 'broken'; void missing( {",
        'part_host.dart': "part 'part.dart'; const method = 'part-host';",
        'part.dart': "part of 'part_host.dart'; const channel = 'part';",
        'main.dart': '''
import 'package:flutter/services.dart';
import 'chain.dart';
import 'broken.dart' as broken;
import 'part_host.dart' as part;
final c = MethodChannel('native');
void deep() => c.invokeMethod(a0);
void brokenCall() => c.invokeMethod(broken.method);
void partCall() => c.invokeMethod(part.method);
''',
      });
      final result = indexBridges(root.path);
      expect(
        calls(result).map((fact) => fact['dynamic']),
        everyElement(isTrue),
      );
      expect(
        result.limitations,
        contains(startsWith('constant-resolution-limit:')),
      );
      expect(
        result.limitations,
        contains(startsWith('constant-source-parse-errors:')),
      );
      expect(
        result.limitations,
        contains(startsWith('constant-library-parts-unsupported:')),
      );
    },
  );

  test(
    'duplicate constants stay dynamic locally and through re-exports',
    () async {
      final root = await fixture({
        'duplicates.dart': '''
import 'package:flutter/services.dart';
const method = 'first';
const method = 'last';
final local = MethodChannel('local');
void go() => local.invokeMethod(method);
''',
        'barrel.dart': "export 'duplicates.dart';",
        'main.dart': '''
import 'package:flutter/services.dart';
import 'barrel.dart' as names;
final imported = MethodChannel('imported');
void go() => imported.invokeMethod(names.method);
''',
      });
      final result = indexBridges(root.path);
      expect(
        calls(result).map((fact) => fact['dynamic']),
        everyElement(isTrue),
      );
      expect(calls(result).map((fact) => fact['method']), [
        'method',
        'names.method',
      ]);
      expect(
        result.limitations,
        contains(startsWith('constant-name-conflicts:')),
      );
    },
  );

  for (final declaration in [
    "String get method => 'getter';",
    "String method() => 'function';",
    'class method {}',
  ]) {
    test('const conflicts with another declaration: $declaration', () async {
      final root = await fixture({
        'names.dart': "const method = 'const'; $declaration",
        'main.dart': '''
import 'package:flutter/services.dart';
import 'names.dart';
final c = MethodChannel('native');
void go() => c.invokeMethod(method);
''',
      });
      final result = indexBridges(root.path);
      expect(calls(result).single['method'], 'method');
      expect(calls(result).single['dynamic'], isTrue);
      expect(
        result.limitations,
        contains(startsWith('constant-name-conflicts:')),
      );
    });
  }

  test('an unrelated duplicate does not block unambiguous constants', () async {
    final root = await fixture({
      'names.dart':
          "const duplicate = 'one'; const duplicate = 'two'; const channel = 'native'; const method = 'ping';",
      'main.dart': '''
import 'package:flutter/services.dart';
import 'names.dart';
final c = MethodChannel(channel);
void go() => c.invokeMethod(method);
''',
    });
    final result = indexBridges(root.path);
    expect(calls(result).single['channel'], 'native');
    expect(calls(result).single['method'], 'ping');
    expect(calls(result).single['dynamic'], isFalse);
  });

  test(
    'a valid getter and setter pair is one nonconstant namespace name',
    () async {
      final root = await fixture({
        'names.dart': '''
String _value = 'mutable';
String get value => _value;
set value(String next) { _value = next; }
const channel = 'native';
const method = 'ping';
''',
        'main.dart': '''
import 'package:flutter/services.dart';
import 'names.dart';
final c = MethodChannel(channel);
void go() => c.invokeMethod(method);
void getter() => c.invokeMethod(value);
''',
      });
      final result = indexBridges(root.path);
      expect(calls(result).first['dynamic'], isFalse);
      expect(calls(result).last['dynamic'], isTrue);
      expect(
        result.limitations,
        isNot(contains(startsWith('constant-name-conflicts:'))),
      );
    },
  );
}
