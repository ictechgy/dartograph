import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  test(
    'bridges --messages emits version 2 BasicMessageChannel facts',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dartograph-messages.',
      );
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/lib').create();
      await File('${root.path}/lib/api.dart').writeAsString('''
import 'package:flutter/services.dart';
final channel = BasicMessageChannel<Object?>('example/basic', codec);
class Api {
  void read() => channel.send(null);
}
''');
      final output = StringBuffer();

      final status = await runDartograph(
        ['bridges', '--messages', '--format', 'json', root.path],
        output: output,
        now: () => DateTime.utc(2026, 9, 14),
      );

      expect(status, ExitStatus.success.code);
      final document = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(document['format'], 'bridge-facts');
      expect(document['version'], 2);
      expect(document['transport'], 'basic-message-channel');
      expect(document['platform'], 'dart');
      expect(document['target'], 'flutter');
      expect(document['project'], await root.resolveSymbolicLinks());
      expect(document['facts'], [
        {
          'channel': 'example/basic',
          'dynamic': false,
          'kind': 'message-send',
          'location': {'column': 26, 'line': 4, 'path': 'lib/api.dart'},
          'symbol': {'qualifiedName': 'Api.read'},
        },
      ]);
    },
  );

  test(
    'messages flag rejects malformed combinations and non-json format',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dartograph-messages.',
      );
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/lib').create();
      await File(
        '${root.path}/lib/empty.dart',
      ).writeAsString('void main() {}\n');

      for (final arguments in [
        ['bridges', '--messages', '--format', 'json'],
        ['bridges', '--messages', '--messages', '--format', 'json', root.path],
        ['bridges', '--messages', '--format', 'text', root.path],
        ['bridges', '--messages=true', '--format', 'json', root.path],
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
