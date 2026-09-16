import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  test('bridges --events emits version 2 EventChannel facts', () async {
    final root = await Directory.systemTemp.createTemp('dartograph-events.');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/api.dart').writeAsString('''
import 'package:flutter/services.dart';
final channel = EventChannel('example/charging');
class Api {
  void listen() => channel.receiveBroadcastStream().listen((_) {});
}
''');
    final output = StringBuffer();

    final status = await runDartograph(
      ['bridges', '--events', '--format', 'json', root.path],
      output: output,
      now: () => DateTime.utc(2026, 9, 14),
    );

    expect(status, ExitStatus.success.code);
    final document = jsonDecode(output.toString()) as Map<String, Object?>;
    expect(document['format'], 'bridge-facts');
    expect(document['version'], 2);
    expect(document['transport'], 'event-channel');
    expect(document['platform'], 'dart');
    expect(document['target'], 'flutter');
    expect(document['project'], await root.resolveSymbolicLinks());
    expect(document['facts'], [
      {
        'channel': 'example/charging',
        'dynamic': false,
        'kind': 'stream-listen',
        'location': {'column': 28, 'line': 4, 'path': 'lib/api.dart'},
        'symbol': {'qualifiedName': 'Api.listen'},
      },
    ]);
  });

  test(
    'events flag rejects malformed combinations and transport mixing',
    () async {
      final root = await Directory.systemTemp.createTemp('dartograph-events.');
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/lib').create();
      await File(
        '${root.path}/lib/empty.dart',
      ).writeAsString('void main() {}\n');

      for (final arguments in [
        ['bridges', '--events', '--format', 'json'],
        ['bridges', '--events', '--events', '--format', 'json', root.path],
        ['bridges', '--events', '--format', 'text', root.path],
        ['bridges', '--events=true', '--format', 'json', root.path],
        ['bridges', '--messages', '--events', '--format', 'json', root.path],
      ]) {
        expect(
          await runDartograph(
            arguments,
            output: StringBuffer(),
            error: StringBuffer(),
          ),
          ExitStatus.usage.code,
          reason: arguments.join(' '),
        );
      }
    },
  );
}
