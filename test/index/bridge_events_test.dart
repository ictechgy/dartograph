import 'dart:io';

import 'package:dartograph/src/index/bridge_index.dart';
import 'package:test/test.dart';

void main() {
  test('indexes only listens on proven EventChannel receivers', () async {
    final root = await Directory.systemTemp.createTemp('bridge-events.');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/events.dart').writeAsString(r'''
import 'package:flutter/services.dart';

final events = EventChannel('charging');
final method = MethodChannel('battery');
final arbitrary = Object();

class Api {
  void listen() {
    events.receiveBroadcastStream().listen((_) {});
    method.invokeMethod('call');
    arbitrary.receiveBroadcastStream();
  }
}
''');

    final result = indexBridges(root.path, events: true);

    expect(result.facts, hasLength(1));
    expect(result.facts.single, {
      'kind': 'stream-listen',
      'channel': 'charging',
      'dynamic': false,
      'location': {'path': 'events.dart', 'line': 9, 'column': 12},
      'symbol': {'qualifiedName': 'Api.listen'},
    });
    expect(result.facts.single.containsKey('method'), isFalse);
    expect(
      result.limitations,
      contains(
        'unresolved-stream-listens: 1 receiveBroadcastStream call has '
        'no proven EventChannel receiver',
      ),
    );
  });

  test(
    'resolves EventChannel names through const, prefix, and fields',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-events.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/events.dart').writeAsString(r'''
import 'package:flutter/services.dart' as services;

const name = 'literal';
final inline = services.EventChannel('inline');

class Api {
  final field = services.EventChannel(name);
  void listen() {
    inline.receiveBroadcastStream();
    field.receiveBroadcastStream();
  }
}
''');

      final result = indexBridges(root.path, events: true);

      expect(result.facts.map((fact) => fact['channel']), [
        'inline',
        'literal',
      ]);
      expect(
        result.facts.every((fact) => fact['kind'] == 'stream-listen'),
        isTrue,
      );
      expect(result.facts.every((fact) => fact['dynamic'] == false), isTrue);
    },
  );

  test('keeps dynamic EventChannel names with their literal prefix', () async {
    final root = await Directory.systemTemp.createTemp('bridge-events.');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/events.dart').writeAsString(r'''
import 'package:flutter/services.dart';

final events = EventChannel('dev.flutter.$suffix');

void listen() {
  events.receiveBroadcastStream();
}
''');

    final result = indexBridges(root.path, events: true);

    expect(result.facts, hasLength(1));
    expect(result.facts.single['kind'], 'stream-listen');
    expect(result.facts.single['dynamic'], isTrue);
    expect(result.facts.single['channel'], "'dev.flutter.\$suffix'");
    expect(result.facts.single['channelPrefix'], 'dev.flutter.');
    expect(
      result.limitations,
      contains(startsWith('dynamic-event-channel-names: 1')),
    );
  });

  test(
    'resolves a mutable EventChannel field that is never reassigned',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-events.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/events.dart').writeAsString(r'''
import 'package:flutter/services.dart';

class Api {
  EventChannel channel = const EventChannel('charging');
  void listen() {
    channel.receiveBroadcastStream();
  }
}

class Swapped {
  EventChannel channel = const EventChannel('before');
  void swap() => this.channel = EventChannel('after');
  void listen() {
    channel.receiveBroadcastStream();
  }
}
''');

      final result = indexBridges(root.path, events: true);

      expect(result.facts, hasLength(1));
      expect(result.facts.single['channel'], 'charging');
      expect(result.facts.single['kind'], 'stream-listen');
      expect(
        result.limitations,
        contains(startsWith('unresolved-stream-listens: 1')),
      );
    },
  );

  test(
    'distrusts mutable field initials rebound by injection, cascade, or external writes',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-events.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/events.dart').writeAsString(r'''
import 'package:flutter/services.dart';

class Injected {
  EventChannel channel = const EventChannel('default');
  Injected({EventChannel? channel})
      : channel = channel ?? const EventChannel('default');
  void listen() => channel.receiveBroadcastStream();
}

class FormalInjected {
  EventChannel channel = const EventChannel('default');
  FormalInjected(this.channel);
  void listen() => channel.receiveBroadcastStream();
}

class Cascaded {
  EventChannel channel = const EventChannel('default');
  void rebind() => this..channel = EventChannel('later');
  void listen() => channel.receiveBroadcastStream();
}

class External {
  EventChannel other = const EventChannel('default');
  void listen() => other.receiveBroadcastStream();
}

void poke(External api) {
  api.other = EventChannel('later');
}

EventChannel topMutable = EventChannel('top');
void rebindTop() => topMutable = EventChannel('later');
void listenTop() => topMutable.receiveBroadcastStream();

class Stable {
  EventChannel channel = const EventChannel('charging');
  void listen() => channel.receiveBroadcastStream();
}
''');

      final result = indexBridges(root.path, events: true);

      expect(result.facts, hasLength(1));
      expect(result.facts.single['channel'], 'charging');
      expect(
        result.limitations,
        contains(startsWith('unresolved-stream-listens: 5')),
      );
    },
  );

  test('messages and events are separate documents', () async {
    final root = await Directory.systemTemp.createTemp('bridge-events.');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/empty.dart').writeAsString('void main() {}\n');

    expect(
      () => indexBridges(root.path, messages: true, events: true),
      throwsArgumentError,
    );
  });

  test(
    'EventChannel constructions stay unscanned without the events flag',
    () async {
      final root = await Directory.systemTemp.createTemp('bridge-events.');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/events.dart').writeAsString(r'''
import 'package:flutter/services.dart';

final events = EventChannel('charging');
final method = MethodChannel('battery');

void listen() {
  events.receiveBroadcastStream();
  method.invokeMethod('call');
}
''');

      final result = indexBridges(root.path);

      expect(
        result.facts.every((fact) => fact['kind'] != 'stream-listen'),
        isTrue,
      );
      expect(
        result.limitations,
        contains(startsWith('unscanned-event-channels: 1')),
      );
    },
  );
}
