import 'dart:convert';
import 'dart:io';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  test('source mutations preserve names and expose source-local gaps', () async {
    final root = await Directory.systemTemp.createTemp('evidence-mutations.');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await File(
      '${root.path}/pubspec.yaml',
    ).writeAsString('name: mutation_fixture\nenvironment:\n  sdk: ^3.11.0\n');
    final source = File('${root.path}/lib/main.dart');
    Future<Map> run(String body) async {
      await source.writeAsString(body);
      final output = StringBuffer();
      await runDartograph([
        'dead',
        '--format',
        'json',
        root.path,
      ], output: output);
      return jsonDecode(output.toString()) as Map;
    }

    final live = await run('void helper() {}\nvoid main() { helper(); }');
    expect(live['findings'], isEmpty);
    final renamed = await run('void renamed() {}\nvoid main() { renamed(); }');
    expect(renamed['findings'], isEmpty);
    final dead = await run('void helper() {}\nvoid main() {}');
    expect(
      (dead['findings'] as List).any((f) => f['id'].endsWith('::helper')),
      isTrue,
    );
    final gap = await run('void helper() {}\nvoid main() { missing(); }');
    final helper = (gap['findings'] as List).singleWhere(
      (f) => f['id'].endsWith('::helper'),
    );
    expect(
      helper['limitations'],
      contains('source-analysis-errors: project:lib/main.dart'),
    );
    await File(
      '${root.path}/lib/independent.dart',
    ).writeAsString('void isolated() {}');
    final scoped = await run('void helper() {}\nvoid main() { missing(); }');
    final isolated = (scoped['findings'] as List).singleWhere(
      (f) => f['id'].endsWith('::isolated'),
    );
    expect(
      isolated['limitations'],
      isNot(contains('source-analysis-errors: project:lib/main.dart')),
    );
    expect(
      isolated['limitations'],
      contains(
        'analysis gaps may affect reachability outside the source files where they were observed',
      ),
    );
    await File('${root.path}/lib/independent.dart').delete();
    final dynamicGap = await run(
      'void helper() {}\nvoid main() {}\nvoid dispatch(dynamic x) { x.helper(); }',
    );
    final finding = (dynamicGap['findings'] as List).first;
    expect(
      finding['limitations'],
      contains('source-unresolved-invocations: project:lib/main.dart'),
    );
    final healed = await run('void helper() {}\nvoid main() { helper(); }');
    expect(healed['findings'], isEmpty);
  });
}
