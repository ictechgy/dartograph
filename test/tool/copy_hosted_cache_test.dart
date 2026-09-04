import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('cache copy decodes file URIs with spaces and non-ASCII', () async {
    final directory = await Directory.systemTemp.createTemp(
      'copy-hosted-cache.',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = Directory(p.join(directory.path, 'cache with space', '한글'));
    final package = Directory(
      p.join(cache.path, 'hosted', 'pub.dev', 'sample-1.0.0'),
    )..createSync(recursive: true);
    File(
      p.join(package.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: sample');
    final metadata = Directory(
      p.join(cache.path, 'hosted', 'pub.dev', '.cache'),
    )..createSync();
    File(p.join(metadata.path, 'sample-versions.json')).writeAsStringSync('{}');
    final configuration = File(p.join(directory.path, 'package_config.json'))
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'sample',
              'rootUri': package.uri.toString(),
              'packageUri': 'lib/',
            },
          ],
        }),
      );
    final destination = Directory(p.join(directory.path, 'destination'));

    final result = await Process.run(Platform.resolvedExecutable, [
      'tool/copy_hosted_cache.dart',
      configuration.path,
      destination.path,
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(
      File(
        p.join(
          destination.path,
          'hosted',
          'pub.dev',
          'sample-1.0.0',
          'pubspec.yaml',
        ),
      ).readAsStringSync(),
      'name: sample',
    );
    expect(
      File(
        p.join(
          destination.path,
          'hosted',
          'pub.dev',
          '.cache',
          'sample-versions.json',
        ),
      ).existsSync(),
      isTrue,
    );
  });
}
