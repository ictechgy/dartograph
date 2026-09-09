import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// dartograph#38 — 모노레포 조인용 bridges 공유 루트(--project + pub
/// workspace 자동 감지)의 CLI 계약이다.
void main() {
  late Directory mono;
  late String monoRoot;

  Future<void> writePackage(
    String relative, {
    required String pubspec,
    String channelSource = '''
import 'package:flutter/services.dart';

final channel = MethodChannel('dev.example/cam');

void shoot() => channel.invokeMethod('takePhoto');
''',
  }) async {
    final directory = Directory(p.join(mono.path, relative));
    await Directory(p.join(directory.path, 'lib')).create(recursive: true);
    await File(p.join(directory.path, 'pubspec.yaml')).writeAsString(pubspec);
    await File(
      p.join(directory.path, 'lib', 'channel.dart'),
    ).writeAsString(channelSource);
  }

  setUp(() async {
    mono = await Directory.systemTemp.createTemp('bridges-project.');
    monoRoot = await mono.resolveSymbolicLinks();
    await writePackage(
      'packages/interface_pkg',
      pubspec: '''
name: interface_pkg
resolution: workspace
environment:
  sdk: ^3.11.0
''',
    );
    await writePackage(
      'packages/plugin_pkg',
      pubspec: '''
name: plugin_pkg
environment:
  sdk: ^3.11.0
''',
    );
    await File(p.join(mono.path, 'pubspec.yaml')).writeAsString('''
name: mono
workspace:
  - packages/interface_pkg
  - packages/plugin_pkg
environment:
  sdk: ^3.11.0
''');
  });

  tearDown(() => mono.delete(recursive: true));

  Future<Map<String, Object?>> bridges(
    List<String> arguments, {
    StringBuffer? errors,
  }) async {
    final output = StringBuffer();
    final status = await runDartograph(
      ['bridges', '--format', 'json', ...arguments],
      output: output,
      error: errors ?? StringBuffer(),
    );
    expect(status, ExitStatus.success.code, reason: arguments.join(' '));
    return jsonDecode(output.toString()) as Map<String, Object?>;
  }

  test('pub workspace member auto-detects the shared project root', () async {
    final document = await bridges(['${mono.path}/packages/interface_pkg']);

    expect(document['project'], monoRoot);
    final fact =
        (document['facts']! as List)
                .where((item) => (item as Map)['kind'] == 'channel-create')
                .single
            as Map;
    expect(
      (fact['location']! as Map)['path'],
      'packages/interface_pkg/lib/channel.dart',
    );
    expect(document['limitations'], isEmpty);
  });

  test(
    'explicit --project rebases a non-workspace package identically',
    () async {
      final viaOption = await bridges([
        '--project',
        mono.path,
        '${mono.path}/packages/plugin_pkg',
      ]);
      final viaWorkspace = await bridges([
        '${mono.path}/packages/interface_pkg',
      ]);

      // #38의 핵심: 두 producer 문서의 project 문자열이 정확히 일치한다.
      expect(viaOption['project'], monoRoot);
      expect(viaOption['project'], viaWorkspace['project']);
      // location.path는 각자 패키지에서 공유 루트까지 재기준된다.
      expect(
        ((viaOption['facts']! as List)
                .where((item) => (item as Map)['kind'] == 'channel-create')
                .single
            as Map)['location'],
        containsPair('path', 'packages/plugin_pkg/lib/channel.dart'),
      );
      expect(
        ((viaWorkspace['facts']! as List)
                .where((item) => (item as Map)['kind'] == 'channel-create')
                .single
            as Map)['location'],
        containsPair('path', 'packages/interface_pkg/lib/channel.dart'),
      );
    },
  );

  test(
    'without workspace or --project the scan root stays the project',
    () async {
      final outside = await Directory.systemTemp.createTemp('bridges-plain.');
      addTearDown(() => outside.delete(recursive: true));
      await Directory(p.join(outside.path, 'lib')).create();
      await File(p.join(outside.path, 'pubspec.yaml')).writeAsString('''
name: plain_pkg
environment:
  sdk: ^3.11.0
''');
      await File(p.join(outside.path, 'lib', 'channel.dart')).writeAsString('''
import 'package:flutter/services.dart';

final channel = MethodChannel('dev.example/plain');
''');

      final document = await bridges([outside.path]);

      expect(document['project'], await outside.resolveSymbolicLinks());
      expect(((document['facts']! as List).single as Map)['location'], {
        'column': isA<int>(),
        'line': 3,
        'path': 'lib/channel.dart',
      });
    },
  );

  test(
    'workspace declaration without an ancestor root reports a limitation',
    () async {
      final orphan = await Directory.systemTemp.createTemp('bridges-orphan.');
      addTearDown(() => orphan.delete(recursive: true));
      await Directory(p.join(orphan.path, 'lib')).create();
      await File(p.join(orphan.path, 'pubspec.yaml')).writeAsString('''
name: orphan_pkg
resolution: workspace
environment:
  sdk: ^3.11.0
''');
      await File(p.join(orphan.path, 'lib', 'channel.dart')).writeAsString('''
import 'package:flutter/services.dart';

final channel = MethodChannel('dev.example/orphan');
''');

      final document = await bridges([orphan.path]);

      expect(document['project'], await orphan.resolveSymbolicLinks());
      expect(
        document['limitations'],
        contains(startsWith('pub-workspace-root-not-found:')),
      );
    },
  );

  test('an unparsable pubspec limits detection instead of failing', () async {
    final broken = await Directory.systemTemp.createTemp('bridges-broken.');
    addTearDown(() => broken.delete(recursive: true));
    await Directory(p.join(broken.path, 'lib')).create();
    await File(
      p.join(broken.path, 'pubspec.yaml'),
    ).writeAsString('name: broken\nresolution: [unclosed\n');
    await File(p.join(broken.path, 'lib', 'channel.dart')).writeAsString('''
import 'package:flutter/services.dart';

final channel = MethodChannel('dev.example/broken');
''');

    final document = await bridges([broken.path]);

    expect(document['project'], await broken.resolveSymbolicLinks());
    expect(
      document['limitations'],
      contains(startsWith('pub-workspace-pubspec-unparsed:')),
    );
  });

  test('--project misuse is a usage error', () async {
    final errors = StringBuffer();
    for (final invocation in [
      // 스캔 루트를 포함하지 않는 공유 루트.
      ['--project', '${mono.path}/packages/interface_pkg', mono.path],
      // 없는 디렉터리.
      ['--project', '${mono.path}/absent', mono.path],
      // 중복·값 빠짐·옵션 모양 값.
      ['--project', mono.path, '--project', mono.path, mono.path],
      ['--project'],
      ['--project', '--strict', mono.path],
    ]) {
      expect(
        await runDartograph(
          ['bridges', '--format', 'json', ...invocation],
          output: StringBuffer(),
          error: errors,
        ),
        ExitStatus.usage.code,
        reason: invocation.join(' '),
      );
    }
    expect(
      errors.toString(),
      contains(
        'Invalid --project: it must be an existing directory containing the '
        'package root.',
      ),
    );
    // 경로는 반향하지 않는다.
    expect(errors.toString(), isNot(contains(mono.path)));
  });
}
