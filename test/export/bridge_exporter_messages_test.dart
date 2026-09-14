import 'dart:convert';

import 'package:dartograph/src/export/bridge_exporter.dart';
import 'package:test/test.dart';

void main() {
  final timestamp = DateTime.utc(2026, 9, 14);

  test('keeps version 1 and version 2 transport pairs valid', () {
    final method =
        jsonDecode(
              exportBridgeFacts(
                project: '/project',
                generatedAt: timestamp,
                facts: const [],
                limitations: const [],
              ),
            )
            as Map<String, Object?>;
    expect(method['version'], 1);
    expect(method.containsKey('transport'), isFalse);

    final messages =
        jsonDecode(
              exportBridgeFacts(
                project: '/project',
                generatedAt: timestamp,
                facts: const [],
                limitations: const [],
                version: 2,
                transport: 'basic-message-channel',
              ),
            )
            as Map<String, Object?>;
    expect(messages['version'], 2);
    expect(messages['transport'], 'basic-message-channel');
  });

  test('rejects an inconsistent version and transport pair', () {
    expect(
      () => exportBridgeFacts(
        project: '/project',
        generatedAt: timestamp,
        facts: const [],
        limitations: const [],
        version: 2,
      ),
      throwsArgumentError,
    );
    expect(
      () => exportBridgeFacts(
        project: '/project',
        generatedAt: timestamp,
        facts: const [],
        limitations: const [],
        transport: 'basic-message-channel',
      ),
      throwsArgumentError,
    );
  });
}
