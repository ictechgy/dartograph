import 'dart:io';

import 'package:dartograph/src/analysis/baseline.dart';
import 'package:dartograph/src/analysis/reachability_analyzer.dart';
import 'package:test/test.dart';

void main() {
  final first = DeadFinding(
    id: 'package:app/a.dart::dead',
    kind: 'declaration',
    source: 'project:lib/a.dart',
    reason: 'unreachable from all retention roots',
    retentionRootsChecked: const ['package:app/main.dart::main'],
    limitations: const ['single configuration'],
  );
  final second = DeadFinding(
    id: 'package:app/b.dart',
    kind: 'file',
    source: 'project:lib/b.dart',
    reason: 'no reachable declaration or reachable library import',
    retentionRootsChecked: const ['package:app/main.dart::main'],
  );

  test(
    'baseline bytes are deterministic and suppress only exact findings',
    () async {
      final directory = await Directory.systemTemp.createTemp('baseline-test.');
      addTearDown(() => directory.delete(recursive: true));
      final one = File('${directory.path}/one.json');
      final two = File('${directory.path}/two.json');

      await BaselineStore.write(Baseline.capture([second, first, first]), one);
      await BaselineStore.write(Baseline.capture([first, second]), two);

      expect(await one.readAsBytes(), await two.readAsBytes());
      final loaded = await BaselineStore.read(one);
      expect(loaded.filter([first, second]).findings, isEmpty);
      expect(loaded.filter([first]).suppressedCount, 1);
      final moved = DeadFinding(
        id: first.id,
        kind: first.kind,
        source: first.source,
        line: 480,
        column: 9,
        reason: first.reason,
        retentionRootsChecked: first.retentionRootsChecked,
        limitations: const ['a newer analyzer limitation'],
      );
      expect(loaded.filter([moved]).findings, isEmpty);
      final novel = DeadFinding(
        id: 'package:app/new.dart::dead',
        kind: 'declaration',
        source: 'project:lib/new.dart',
        reason: first.reason,
        retentionRootsChecked: first.retentionRootsChecked,
      );
      expect(loaded.filter([novel]).findings, [novel]);
    },
  );

  test('baseline rejects malformed and unsupported documents', () async {
    final directory = await Directory.systemTemp.createTemp(
      'baseline-invalid.',
    );
    addTearDown(() => directory.delete(recursive: true));
    final malformed = File('${directory.path}/bad.json')
      ..writeAsStringSync('{');
    final future = File('${directory.path}/future.json')
      ..writeAsStringSync('{"formatVersion":2,"fingerprints":[]}');

    await expectLater(BaselineStore.read(malformed), throwsFormatException);
    await expectLater(BaselineStore.read(future), throwsFormatException);

    final foreign = File('${directory.path}/foreign.json')
      ..writeAsStringSync(
        '{"formatVersion":1,"fingerprints":[],"tool":"other"}',
      );
    await expectLater(BaselineStore.read(foreign), throwsFormatException);
  });
}
