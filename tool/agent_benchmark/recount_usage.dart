import 'dart:convert';
import 'dart:io';

import 'usage_detection.dart';

/// 원본 원장과 transcript를 보존하면서 사용량을 재집계한 JSONL을 출력한다.
void main(List<String> args) {
  if (args.length != 1 || args.single == '--help') {
    final output = args.length == 1 ? stdout : stderr;
    output.writeln(
      'Usage: dart run tool/agent_benchmark/recount_usage.dart <results-dir>',
    );
    exit(args.length == 1 ? 0 : 64);
  }
  try {
    final root = Directory(args.single);
    final records = File('${root.path}/summary.jsonl')
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
    final corrected = <Map<String, Object?>>[];
    for (final record in records) {
      final task = record['task'] as String;
      final arm = record['arm'] as String;
      final model = record['model'] as String;
      final run = record['run'] as int;
      if (task.contains(RegExp(r'[/\\]')) ||
          !const {'with', 'without'}.contains(arm) ||
          run < 0) {
        throw const FormatException('Invalid run identity');
      }
      final encodedModel = model.isEmpty ? 'model' : Uri.encodeComponent(model);
      final transcript = File(
        '${root.path}/transcripts/$task-$arm-$encodedModel-$run.jsonl',
      );
      var calls = 0;
      for (final line in transcript.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final event = jsonDecode(line);
        if (event is! Map || event['type'] != 'assistant') continue;
        final message = event['message'];
        if (message is! Map) continue;
        for (final content in message['content'] as List? ?? const []) {
          if (content is! Map || content['type'] != 'tool_use') continue;
          final name = content['name'] as String? ?? '';
          if (name.startsWith('mcp__dartograph')) {
            calls++;
          } else if (name == 'Bash') {
            final input = content['input'];
            final command = input is Map
                ? input['command'] as String? ?? ''
                : '';
            if (invokesDartograph(command)) calls++;
          }
        }
      }
      corrected.add({
        ...record,
        'usageDetection': usageDetectionVersion,
        'previousDartographCalls': record['dartographCalls'],
        'previousContaminated': record['contaminated'],
        'dartographCalls': calls,
        'usedDartograph': calls > 0,
        'contaminated': arm == 'without' && calls > 0,
      });
    }
    // 입력이 모두 유효할 때만 출력해 누락된 원문을 호출 0으로 바꾸지 않는다.
    for (final record in corrected) {
      stdout.writeln(jsonEncode(record));
    }
  } on Object {
    stderr.writeln(
      'Cannot recount usage: provide a valid summary and every model-named transcript. Original files were not changed.',
    );
    exit(65);
  }
}
