import 'dart:io';

import 'package:dartograph/src/index/bridge_index.dart';
import 'package:test/test.dart';

void main() {
  test('indexes only sends on proven BasicMessageChannel receivers', () async {
    final root = await Directory.systemTemp.createTemp('bridge-messages.');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/messages.dart').writeAsString(r'''
import 'package:flutter/services.dart';

final basic = BasicMessageChannel<Object?>('same', codec);
final method = MethodChannel('same');
final arbitrary = Object();

class Api {
  void send() {
    basic.send('ok');
    method.invokeMethod('call');
    arbitrary.send('ignored');
  }
}
''');

    final result = indexBridges(root.path, messages: true);

    expect(result.facts, hasLength(1));
    expect(result.facts.single, {
      'kind': 'message-send',
      'channel': 'same',
      'dynamic': false,
      'location': {'path': 'messages.dart', 'line': 9, 'column': 11},
      'symbol': {'qualifiedName': 'Api.send'},
    });
    expect(result.facts.single.containsKey('method'), isFalse);
    expect(
      result.limitations,
      contains(startsWith('unresolved-basic-message-sends:')),
    );
    expect(
      result.limitations,
      contains(
        'unresolved-basic-message-sends: 1 send call has no proven BasicMessageChannel receiver',
      ),
    );
  });

  test(
    'resolves immutable aliases and preserves shadowing and mutation',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-messages.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/messages.dart').writeAsString(r'''
import 'package:flutter/services.dart';

final name = 'outer';
final basic = BasicMessageChannel<Object?>(name, codec);

void sends() {
  final name = 'inner';
  final local = BasicMessageChannel<Object?>(name, codec);
  local.send(null);
  basic.send(null);
}

void mutates() {
  var channel = BasicMessageChannel<Object?>('before', codec);
  channel = Object();
  channel.send(null);
}
''');

      final result = indexBridges(root.path, messages: true);
      final sends = result.facts.where(
        (fact) => fact['kind'] == 'message-send',
      );

      expect(sends.map((fact) => fact['channel']), ['inner', 'outer']);
      expect(
        result.limitations,
        contains(startsWith('unresolved-basic-message-sends:')),
      );
    },
  );

  test('updates a mutable field when reassigned through this', () async {
    final root = await Directory.systemTemp.createTemp('bridge-messages.');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/messages.dart').writeAsString(r'''
import 'package:flutter/services.dart';

class Api {
  BasicMessageChannel<Object?> channel =
      BasicMessageChannel<Object?>('before', codec);

  void send() {
    this.channel = BasicMessageChannel<Object?>('after', codec);
    channel.send(null);
  }
}
''');

    final result = indexBridges(root.path, messages: true);

    expect(result.facts, hasLength(1));
    expect(result.facts.single['channel'], 'after');
    expect(result.limitations, isEmpty);
  });

  test(
    'keeps this field assignment separate from a same-named local channel',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-messages.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/messages.dart').writeAsString(r'''
import 'package:flutter/services.dart';

class Api {
  BasicMessageChannel<Object?> channel =
      BasicMessageChannel<Object?>('field', codec);

  void send() {
    this.channel = BasicMessageChannel<Object?>('updated', codec);
    {
      final channel = BasicMessageChannel<Object?>('local', codec);
      channel.send(null);
    }
    channel.send(null);
  }
}
''');

      final result = indexBridges(root.path, messages: true);

      expect(result.facts.map((fact) => fact['channel']), ['local', 'updated']);
      expect(result.limitations, isEmpty);
    },
  );

  test('does not leak mutable field state between methods', () async {
    final root = await Directory.systemTemp.createTemp('bridge-messages.');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/messages.dart').writeAsString(r'''
import 'package:flutter/services.dart';

class Api {
  BasicMessageChannel<Object?> channel =
      BasicMessageChannel<Object?>('before', codec);

  void swap() => this.channel = BasicMessageChannel<Object?>('after', codec);
  void send() => channel.send(null);
}

class ReorderedApi {
  BasicMessageChannel<Object?> channel =
      BasicMessageChannel<Object?>('before', codec);

  void send() => channel.send(null);
  void swap() => this.channel = BasicMessageChannel<Object?>('after', codec);
}
''');

    final result = indexBridges(root.path, messages: true);

    expect(result.facts.map((fact) => fact['channel']), ['before', 'before']);
    expect(result.limitations, isEmpty);
  });

  test(
    'keeps a field send unresolved after a conditional assignment',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-messages.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/messages.dart').writeAsString(r'''
import 'package:flutter/services.dart';

class Api {
  BasicMessageChannel<Object?> channel =
      BasicMessageChannel<Object?>('before', codec);

  void send(bool condition) {
    if (condition) {
      this.channel = BasicMessageChannel<Object?>('branch', codec);
    }
    channel.send(null);
  }
}
''');

      final result = indexBridges(root.path, messages: true);

      expect(result.facts, isEmpty);
      expect(
        result.limitations,
        contains(startsWith('unresolved-basic-message-sends:')),
      );
    },
  );

  test(
    'retains dynamic interpolation and only its decoded leading prefix',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-messages.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/messages.dart').writeAsString(r'''
import 'package:flutter/services.dart';

final suffix = 'x';
final pigeonVar_channelName = 'dev.\u0065xample/${suffix}';
final channel = BasicMessageChannel<Object?>(pigeonVar_channelName, codec);

void send() => channel.send(null);
''');

      final result = indexBridges(root.path, messages: true);
      expect(result.facts, hasLength(1));
      expect(
        result.facts.single,
        containsPair('channel', 'pigeonVar_channelName'),
      );
      expect(
        result.facts.single,
        containsPair('channelPrefix', 'dev.example/'),
      );
      expect(result.facts.single['dynamic'], isTrue);
    },
  );

  test('does not report a BasicMessageChannel that is never sent', () async {
    final root = await Directory.systemTemp.createTemp('bridge-messages.');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/messages.dart').writeAsString('''
import 'package:flutter/services.dart';
final channel = BasicMessageChannel<Object?>('unused', codec);
''');

    final result = indexBridges(root.path, messages: true);
    expect(result.facts, isEmpty);
    expect(result.limitations, isEmpty);
  });

  test(
    'uses a Basic-specific dynamic name limitation in message mode',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-messages.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/messages.dart').writeAsString(r'''
import 'package:flutter/services.dart';

final method = MethodChannel(methodName);
final basic = BasicMessageChannel<Object?>(basicName, codec);
void send() => basic.send(null);
''');

      final result = indexBridges(root.path, messages: true);

      expect(
        result.limitations,
        contains(startsWith('dynamic-basic-message-channel-names:')),
      );
      expect(
        result.limitations.where(
          (limitation) => limitation.startsWith('dynamic-channel-names:'),
        ),
        isEmpty,
      );
    },
  );
}
