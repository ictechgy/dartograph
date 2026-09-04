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
      expect(output.toString(), 'dartograph $toolVersion\n');
      expect((bridge['tool'] as Map<String, Object?>)['version'], toolVersion);
    },
  );
}
