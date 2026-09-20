import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'fake claude receives budget, preserves model transcripts, and resumes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'agent-benchmark.',
      );
      addTearDown(() => directory.delete(recursive: true));

      Directory(
        p.join(directory.path, 'repos', 'fixture'),
      ).createSync(recursive: true);
      final output = Directory(p.join(directory.path, 'results'));
      final tasks = File(p.join(directory.path, 'tasks.json'))
        ..writeAsStringSync(
          jsonEncode({
            'repos': [
              {
                'name': 'fixture',
                'url': 'unused',
                'revision': 'unused',
                'packageRoot': '.',
              },
            ],
            'tasks': [
              {
                'id': 'fixture-task',
                'repo': 'fixture',
                'prompt': 'Find the fixture evidence.',
                'expected': ['fixture evidence'],
              },
            ],
          }),
        );
      final argsFile = File(p.join(directory.path, 'claude-args.txt'));
      final fakeClaude = File(p.join(directory.path, 'fake-claude'))
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'printf \'%s\\n\' "\$@" > "\$BENCHMARK_ARGS_FILE"\n'
          'printf \'%s\\n\' \'{"type":"system","model":"claude-haiku"}\'\n'
          'printf \'%s\\n\' \'{"type":"result","result":"fixture evidence",'
          '"is_error":false,"num_turns":1,"duration_ms":2,'
          '"total_cost_usd":0.10,"usage":{"input_tokens":1,"output_tokens":1}}\'\n'
          'exit "\${FAKE_CLAUDE_EXIT:-0}"\n',
        );
      final chmod = await Process.run('chmod', ['+x', fakeClaude.path]);
      expect(chmod.exitCode, 0);

      final tool = p.join(
        Directory.current.path,
        'tool/agent_benchmark/agent_benchmark.dart',
      );
      final environment = Map<String, String>.from(Platform.environment)
        ..['BENCHMARK_ARGS_FILE'] = argsFile.path
        ..['FAKE_CLAUDE_EXIT'] = '0';
      Future<ProcessResult> runBenchmark({
        required String model,
        required Directory resultOutput,
        Map<String, String>? runEnvironment,
        String? maxBudgetUsd,
      }) {
        final args = [
          tool,
          'run',
          '--repos',
          p.join(directory.path, 'repos'),
          '--tasks',
          tasks.path,
          '--out',
          resultOutput.path,
          '--arm',
          'without',
          '--only',
          'fixture-task',
          '--runs',
          '1',
          '--model',
          model,
          if (maxBudgetUsd != null) ...['--max-budget-usd', maxBudgetUsd],
          '--claude-bin',
          fakeClaude.path,
        ];
        return Process.run(
          Platform.resolvedExecutable,
          args,
          environment: runEnvironment ?? environment,
        );
      }

      final first = await runBenchmark(
        model: 'model/v1',
        resultOutput: output,
        maxBudgetUsd: '0.25',
      );
      expect(first.exitCode, 0, reason: first.stderr);
      expect(argsFile.readAsStringSync(), contains('--max-budget-usd\n0.25'));

      final summary = File(p.join(output.path, 'summary.jsonl'));
      final firstRecord = jsonDecode(summary.readAsLinesSync().single);
      expect(firstRecord['correct'], isTrue);
      expect(firstRecord['resolvedModel'], 'claude-haiku');
      expect(firstRecord['maxBudgetUsd'], 0.25);
      expect(firstRecord['budgetExceeded'], isFalse);
      expect(
        File(
          p.join(
            output.path,
            'transcripts',
            'fixture-task-without-model%2Fv1-0.jsonl',
          ),
        ).existsSync(),
        isTrue,
      );

      final resumedEnvironment = Map<String, String>.from(environment)
        ..['FAKE_CLAUDE_EXIT'] = '7';
      final resumed = await runBenchmark(
        model: 'model/v1',
        resultOutput: output,
        runEnvironment: resumedEnvironment,
      );
      expect(resumed.exitCode, 0, reason: resumed.stderr);
      expect(summary.readAsLinesSync(), hasLength(1));

      final slashModel = await runBenchmark(model: 'a/b', resultOutput: output);
      final underscoreModel = await runBenchmark(
        model: 'a_b',
        resultOutput: output,
      );
      expect(slashModel.exitCode, 0, reason: slashModel.stderr);
      expect(underscoreModel.exitCode, 0, reason: underscoreModel.stderr);
      expect(
        File(
          p.join(
            output.path,
            'transcripts',
            'fixture-task-without-a%2Fb-0.jsonl',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(
            output.path,
            'transcripts',
            'fixture-task-without-a_b-0.jsonl',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(summary.readAsLinesSync(), hasLength(3));

      final orphanTranscript = File(
        p.join(
          output.path,
          'transcripts',
          'fixture-task-without-orphan-0.jsonl',
        ),
      )..writeAsStringSync('sentinel\n');
      final orphan = await runBenchmark(model: 'orphan', resultOutput: output);
      expect(orphan.exitCode, 64);
      expect(orphan.stderr, contains('already exists'));
      expect(orphanTranscript.readAsStringSync(), 'sentinel\n');
      expect(summary.readAsLinesSync(), hasLength(3));

      for (final invalidBudget in ['NaN', '-1']) {
        argsFile.writeAsStringSync('');
        final invalidOutput = Directory(
          p.join(directory.path, 'invalid-$invalidBudget'),
        );
        final invalid = await runBenchmark(
          model: 'invalid-$invalidBudget',
          resultOutput: invalidOutput,
          maxBudgetUsd: invalidBudget,
        );
        expect(invalid.exitCode, 64);
        expect(invalid.stderr, contains('--max-budget-usd'));
        expect(argsFile.readAsStringSync(), isEmpty);
        expect(
          File(p.join(invalidOutput.path, 'summary.jsonl')).existsSync(),
          isFalse,
        );
      }

      final failedOutput = Directory(p.join(directory.path, 'failed-results'));
      final failed = await runBenchmark(
        model: 'failed',
        resultOutput: failedOutput,
        runEnvironment: resumedEnvironment,
      );
      expect(failed.exitCode, 0, reason: failed.stderr);
      final failedRecord = jsonDecode(
        File(
          p.join(failedOutput.path, 'summary.jsonl'),
        ).readAsLinesSync().single,
      );
      expect(failedRecord['correct'], isFalse);
      expect(failedRecord['exitCode'], 7);
    },
  );
}
