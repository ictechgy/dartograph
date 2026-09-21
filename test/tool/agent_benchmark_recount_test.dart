import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'recount preserves raw evidence and fails on missing transcripts',
    () async {
      final root = Directory.systemTemp.createTempSync('benchmark-recount.');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(p.join(root.path, 'transcripts')).createSync();
      final summary = File(p.join(root.path, 'summary.jsonl'));
      final originals = [
        for (final arm in ['without', 'with'])
          {
            'task': 'fixture',
            'arm': arm,
            'model': 'a/b',
            'run': 0,
            'dartographCalls': arm == 'with' ? 2 : 1,
            'contaminated': arm == 'without',
            'usedDartograph': true,
            'correct': true,
            'costUsd': 0.25,
          },
      ];
      final raw = '${originals.map(jsonEncode).join('\n')}\n';
      summary.writeAsStringSync(raw);
      final transcriptText = <String, String>{};
      for (final arm in ['without', 'with']) {
        final file = File(
          p.join(root.path, 'transcripts', 'fixture-$arm-a%2Fb-0.jsonl'),
        );
        final event = {
          'type': 'assistant',
          'message': {
            'content': [
              {
                'type': 'tool_use',
                'name': 'Bash',
                'input': {
                  'command':
                      'grep windowWidth /tmp/dartograph-benchmark/lib/main.dart',
                },
              },
              if (arm == 'with')
                {
                  'type': 'tool_use',
                  'name': 'mcp__dartograph__dependency_query',
                  'input': {'symbol': 'windowWidth'},
                },
            ],
          },
        };
        final text = '${jsonEncode(event)}\n';
        file.writeAsStringSync(text);
        transcriptText[file.path] = text;
      }
      final script = p.join(
        Directory.current.path,
        'tool/agent_benchmark/recount_usage.dart',
      );
      final result = await Process.run(Platform.resolvedExecutable, [
        script,
        root.path,
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      final rows = const LineSplitter()
          .convert(result.stdout as String)
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(rows.map((r) => r['dartographCalls']), [0, 1]);
      expect(rows.map((r) => r['contaminated']), [false, false]);
      expect(rows.map((r) => r['usedDartograph']), [false, true]);
      expect(
        rows.every((r) => r['correct'] == true && r['costUsd'] == 0.25),
        isTrue,
      );
      expect(rows.map((r) => r['previousDartographCalls']), [1, 2]);
      expect(summary.readAsStringSync(), raw);
      for (final entry in transcriptText.entries) {
        expect(File(entry.key).readAsStringSync(), entry.value);
      }
      File(transcriptText.keys.last).deleteSync();
      final missing = await Process.run(Platform.resolvedExecutable, [
        script,
        root.path,
      ]);
      expect(missing.exitCode, 65);
      expect(missing.stdout, isEmpty);
      expect(summary.readAsStringSync(), raw);
    },
  );
}
