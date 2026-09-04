import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:dartograph/src/core/tool_info.dart';
import 'package:dartograph/src/export/bridge_exporter.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test(
    'pubspec, CLI, and machine documents share the release version',
    () async {
      final pubspec =
          loadYaml(await File('pubspec.yaml').readAsString()) as YamlMap;
      final output = StringBuffer();

      expect(
        await runDartograph(const ['--version'], output: output),
        ExitStatus.success.code,
      );
      final bridge =
          jsonDecode(
                exportBridgeFacts(
                  project: '/project',
                  generatedAt: DateTime.utc(2026, 9, 4),
                  facts: const [],
                  limitations: const [],
                ),
              )
              as Map<String, Object?>;

      expect(pubspec['version'], toolVersion);
      final repository = Uri.parse(pubspec['repository']! as String);
      expect(repository.scheme, 'https');
      expect(repository.host, 'github.com');
      expect(repository.path, endsWith('/dartograph'));
      expect(pubspec['issue_tracker'], '${repository.toString()}/issues');
      expect(output.toString(), 'dartograph $toolVersion\n');
      expect((bridge['tool'] as Map<String, Object?>)['version'], toolVersion);
    },
  );

  test('bridge timestamps are normalized to exactly three UTC decimals', () {
    final bridge =
        jsonDecode(
              exportBridgeFacts(
                project: '/project',
                generatedAt: DateTime.utc(2026, 9, 4, 12, 30, 45, 123, 456),
                facts: const [],
                limitations: const [],
              ),
            )
            as Map<String, Object?>;

    expect(bridge['generatedAt'], '2026-09-04T12:30:45.123Z');

    final zeroMilliseconds =
        jsonDecode(
              exportBridgeFacts(
                project: '/project',
                generatedAt: DateTime.parse('2026-09-04T21:30:45+09:00'),
                facts: const [],
                limitations: const [],
              ),
            )
            as Map<String, Object?>;
    expect(zeroMilliseconds['generatedAt'], '2026-09-04T12:30:45.000Z');
  });
}
