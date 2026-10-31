import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `--incremental <dir>`의 CLI 배선 계약이다.
///
/// 옵션을 떼어내는 규칙(위치·중복·값 누락)과, 실제 실행이 캐시를 만들고 두 번째
/// 실행에서 같은 산출물을 내는지 확인한다. 색인을 주입하지 않고 프로덕션 기본
/// 배선을 그대로 탄다 — 배선 자체가 검증 대상이다.
void main() {
  late Directory workspace;
  late Directory root;
  late String cacheDirectory;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'dartograph-incremental-cli.',
    );
    root = Directory(p.join(workspace.path, 'app'));
    cacheDirectory = p.join(workspace.path, 'facts');
    Future<void> write(String path, String contents) async {
      final file = File(p.join(root.path, path));
      await file.create(recursive: true);
      await file.writeAsString(contents);
    }

    await write('pubspec.yaml', 'name: app\nenvironment:\n  sdk: ^3.11.0\n');
    await write('lib/app.dart', "export 'service.dart';\n");
    await write('lib/service.dart', 'class Service {}\n');
    await write(
      'lib/main.dart',
      "import 'service.dart';\nvoid main() {\n  Service();\n}\n",
    );
  });

  tearDown(() => workspace.delete(recursive: true));

  test('incremental runs are byte-identical to the default path', () async {
    final plain = await _run(['graph', '--format', 'json', root.path]);
    final first = await _run([
      'graph',
      '--format',
      'json',
      '--incremental',
      cacheDirectory,
      root.path,
    ]);
    final second = await _run([
      'graph',
      '--format',
      'json',
      '--incremental',
      cacheDirectory,
      root.path,
    ]);

    expect(first.status, 0, reason: first.error);
    expect(second.status, 0, reason: second.error);
    expect(first.output, plain.output);
    expect(second.output, plain.output);
    expect(File(p.join(cacheDirectory, 'facts.json')).existsSync(), isTrue);

    // 옵션 위치는 고정이 아니다 — 명령 이름 바로 뒤에도 올 수 있다.
    final leading = await _run([
      'graph',
      '--incremental',
      cacheDirectory,
      '--format',
      'json',
      root.path,
    ]);
    expect(leading.status, 0, reason: leading.error);
    expect(leading.output, plain.output);

    // dead도 같은 색인 경로를 쓴다. package_config이 없어 lib/app.dart 배럴은
    // project: ID로 dead-file 발견이 된다 — findings는 종료 1이다.
    final dead = await _run([
      'dead',
      '--incremental',
      cacheDirectory,
      '--format',
      'json',
      root.path,
    ]);
    expect(dead.status, 1, reason: dead.error);
    expect(dead.output, contains('project:lib/app.dart'));
  });

  test(
    'a failed fact cache write keeps the deps --workspace audit unchanged',
    () async {
      // 멤버 pkg_b가 pkg_a를 선언하고 import한다 — 멤버별 감사에서는 발견이
      // 없다. 멤버 매니페스트를 잃은 결과는 루트 pubspec 하나로 감사하므로
      // pkg_a를 미선언 의존으로 오판해 종료 1이 된다.
      final workspaceRoot = p.join(workspace.path, 'ws');
      Future<void> write(String path, String contents) async {
        final file = File(p.join(workspaceRoot, path));
        await file.create(recursive: true);
        await file.writeAsString(contents);
      }

      await write(
        'pubspec.yaml',
        'name: ws_root\nenvironment:\n  sdk: ^3.8.0\n'
            'workspace:\n  - pkgs/pkg_a\n  - pkgs/pkg_b\n',
      );
      await write('lib/ws_root.dart', 'class RootPackage {}\n');
      await write(
        'pkgs/pkg_a/pubspec.yaml',
        'name: pkg_a\nenvironment:\n  sdk: ^3.8.0\nresolution: workspace\n',
      );
      await write('pkgs/pkg_a/lib/pkg_a.dart', 'class Foo {}\n');
      await write(
        'pkgs/pkg_b/pubspec.yaml',
        'name: pkg_b\nenvironment:\n  sdk: ^3.8.0\nresolution: workspace\n'
            'dependencies:\n  pkg_a:\n',
      );
      await write(
        'pkgs/pkg_b/lib/pkg_b.dart',
        "import 'package:pkg_a/pkg_a.dart';\n\nFoo makeFoo() => Foo();\n",
      );
      final pubGet = await Process.run(Platform.resolvedExecutable, const [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: workspaceRoot);
      expect(pubGet.exitCode, 0, reason: pubGet.stderr as String);
      // facts.json 자리에 디렉터리를 두어 원자적 교체(rename)가 실패하게 한다.
      final unwritable = p.join(workspace.path, 'unwritable-facts');
      await Directory(p.join(unwritable, 'facts.json')).create(recursive: true);

      final plain = await _run([
        'deps',
        '--format',
        'json',
        '--workspace',
        workspaceRoot,
      ]);
      final failedWrite = await _run([
        'deps',
        '--format',
        'json',
        '--workspace',
        '--incremental',
        unwritable,
        workspaceRoot,
      ]);

      expect(plain.status, 0, reason: '${plain.output}${plain.error}');
      expect(failedWrite.status, plain.status, reason: failedWrite.output);
      final expected = jsonDecode(plain.output) as Map<String, Object?>;
      final actual = jsonDecode(failedWrite.output) as Map<String, Object?>;
      expect(actual['findings'], expected['findings']);
      // 쓰기 실패 한계 하나만 더해지고 나머지 한계는 그대로다.
      const writeFailure =
          'incremental-cache-write-failed: analysis is complete but the fact '
          'cache was not updated';
      final limitations = (actual['limitations']! as List<Object?>)
          .cast<String>();
      expect(limitations.where((item) => item == writeFailure), hasLength(1));
      expect(
        limitations.where((item) => item != writeFailure).toList(),
        expected['limitations'],
      );
    },
  );

  test(
    'a planted facts.json link is not opened and the run completes',
    () async {
      // 훅·편집기의 옛 기본값처럼 분석 대상 안 `.dartograph/cache`를 쓴다.
      // 저장소는 이 자리에 링크를 커밋할 수 있다. 숨김 디렉터리라 분석 입력은
      // 아니므로, 결과는 캐시 없는 실행과 같고 버린 사실만 한계로 남아야 한다.
      final plain = await _run(['dead', '--format', 'json', root.path]);
      final plainDocument = jsonDecode(plain.output) as Map<String, Object?>;
      final genuine = p.join(workspace.path, 'genuine');
      final seeded = await _run([
        'dead',
        '--format',
        'json',
        '--incremental',
        genuine,
        root.path,
      ]);
      expect(seeded.status, plain.status, reason: seeded.error);
      final genuineFacts = File(p.join(genuine, 'facts.json'));
      final genuineContents = genuineFacts.readAsStringSync();
      final fifo = p.join(workspace.path, 'pipe');
      final mkfifo = await Process.run('mkfifo', [fifo]);
      expect(mkfifo.exitCode, 0, reason: mkfifo.stderr as String);
      const notRead =
          'incremental-cache-not-read: the fact cache file is a symbolic '
          'link, is not a regular file, or exceeds the 1024 MiB read limit; it '
          'was ignored and every file was resolved again';
      // dead finding은 전역 한계 목록을 함께 싣는다. 버린 캐시의 한계만 빼면
      // 문서 전체가 캐시 없는 실행과 같아야 한다.
      Object? withoutNotRead(Object? value) => switch (value) {
        Map() => {
          for (final entry in value.entries)
            entry.key: withoutNotRead(entry.value),
        },
        List() => [
          for (final item in value)
            if (item != notRead) withoutNotRead(item),
        ],
        _ => value,
      };

      // /dev/null은 수정 전 코드도 멈추지 않는 장치 대역이다(/dev/zero라면
      // 메모리를 채운다). 쓰는 쪽 없는 FIFO는 수정 전 코드가 열기에서 영구
      // 대기하던 입력이라 마지막에 둔다.
      for (final target in [genuineFacts.path, '/dev/null', fifo]) {
        final cache = Directory(p.join(root.path, '.dartograph', 'cache'));
        if (cache.existsSync()) cache.deleteSync(recursive: true);
        cache.createSync(recursive: true);
        final facts = p.join(cache.path, 'facts.json');
        Link(facts).createSync(target);

        final run = await _run([
          'dead',
          '--format',
          'json',
          '--incremental',
          cache.path,
          root.path,
        ]);

        expect(run.status, plain.status, reason: '$target: ${run.error}');
        final document = jsonDecode(run.output) as Map<String, Object?>;
        expect(
          (document['limitations']! as List<Object?>).where(
            (item) => item == notRead,
          ),
          hasLength(1),
          reason: target,
        );
        expect(withoutNotRead(document), plainDocument, reason: target);
        // 이번 쓰기가 링크 자리를 정규 파일로 바꾼다. 링크 대상은 그대로다.
        expect(
          FileSystemEntity.typeSync(facts, followLinks: false),
          FileSystemEntityType.file,
          reason: target,
        );
      }
      expect(genuineFacts.readAsStringSync(), genuineContents);
      expect(
        FileSystemEntity.typeSync(fifo, followLinks: false),
        FileSystemEntityType.pipe,
      );
    },
    skip: Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'stale or malformed package_config entries do not fail analysis',
    () async {
      final configuration = File(
        p.join(root.path, '.dart_tool', 'package_config.json'),
      );
      await configuration.parent.create(recursive: true);
      // 지운 path 의존·옮긴 pub cache처럼 루트가 사라진 항목과, 잘려서 깨진
      // 문서다. 캐시 키 열거만 이 입력에서 실패했다 — 전체 결과 캐시 경로는
      // 실패를 흡수했지만 증분·runtime 경로는 종료 2가 됐다.
      final gone = p.join(workspace.path, 'gone');
      final documents = {
        'stale': jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'app',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.11',
            },
            {
              'name': 'gone',
              'rootUri': '${p.toUri(gone)}/',
              'packageUri': 'lib/',
              'languageVersion': '3.11',
            },
          ],
        }),
        'malformed': '{"configVersion": 2, "packages": [',
      };
      // 선언 없는 배럴 lib/app.dart는 두 경우 모두 dead-file이다(종료 1).
      // 남은 app 항목은 계속 해석돼 package: ID가 되고, 깨진 문서는 package:
      // URI를 못 풀어 project: ID가 된다.
      const barrels = {
        'stale': 'package:app/app.dart',
        'malformed': 'project:lib/app.dart',
      };
      for (final MapEntry(key: name, value: document) in documents.entries) {
        await configuration.writeAsString(document);
        final plain = await _run(['dead', '--format', 'json', root.path]);
        final incremental = await _run([
          'dead',
          '--incremental',
          p.join(workspace.path, 'facts-$name'),
          '--format',
          'json',
          root.path,
        ]);
        final runtime = await _run([
          'runtime',
          '--no-verify',
          '--format',
          'json',
          root.path,
        ]);

        expect(plain.status, 1, reason: '$name: ${plain.error}');
        expect(plain.output, contains('"id":"${barrels[name]}"'));
        expect(incremental.status, plain.status, reason: incremental.error);
        expect(incremental.output, plain.output, reason: name);
        expect(runtime.status, 0, reason: '$name: ${runtime.error}');
      }
    },
  );

  group('--incremental-user-cache', () {
    late String userCacheBase;
    late Map<String, String> environment;

    setUp(() {
      // 실제 사용자 캐시를 건드리지 않게 세 플랫폼의 기준 변수를 모두 돌린다.
      userCacheBase = p.join(workspace.path, 'user-cache');
      environment = {
        'HOME': userCacheBase,
        'XDG_CACHE_HOME': userCacheBase,
        'LOCALAPPDATA': userCacheBase,
      };
    });

    /// [packageRoot]의 사실 파일 위치다. 제품 helper를 쓰지 않고 문서화된
    /// 규칙(`<OS 사용자 캐시>/dartograph/<canonical root sha256>/<mode>`)으로
    /// 계산한다.
    File factsFor(String packageRoot, {String mode = 'incremental'}) {
      final base = Platform.isMacOS
          ? p.join(userCacheBase, 'Library', 'Caches')
          : userCacheBase;
      final canonical = Directory(packageRoot).resolveSymbolicLinksSync();
      final key = sha256.convert(utf8.encode(canonical)).toString();
      return File(p.join(base, 'dartograph', key, mode, 'facts.json'));
    }

    Future<({int status, String output, String error})> run(
      List<String> arguments,
    ) => _run(arguments, userCacheEnvironment: environment);

    test('keeps facts outside the project and reuses them', () async {
      final plain = await run(['graph', '--format', 'json', root.path]);
      final first = await run([
        'graph',
        '--format',
        'json',
        '--incremental-user-cache',
        root.path,
      ]);

      expect(first.status, 0, reason: first.error);
      expect(first.output, plain.output);
      final facts = factsFor(root.path);
      expect(facts.existsSync(), isTrue);
      expect(p.isWithin(workspace.path, facts.path), isTrue);
      expect(p.isWithin(root.path, facts.path), isFalse);
      expect(Directory(p.join(root.path, '.dartograph')).existsSync(), isFalse);

      // 캐시가 현재 입력과 같으면 다시 쓰지 않는다. 시각이 그대로면 두 번째
      // 실행이 같은 위치의 사실을 읽어 재사용했다는 뜻이다.
      facts.setLastModifiedSync(DateTime(2001));
      final second = await run([
        'dead',
        '--format',
        'json',
        '--incremental-user-cache',
        root.path,
      ]);
      expect(second.status, 1, reason: second.error);
      expect(second.output, contains('project:lib/app.dart'));
      expect(facts.lastModifiedSync().isBefore(DateTime(2002)), isTrue);
    });

    test('compare keeps one fact cache per checkout', () async {
      final other = Directory(p.join(workspace.path, 'other'));
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File) continue;
        final copy = File(
          p.join(other.path, p.relative(entity.path, from: root.path)),
        );
        copy.parent.createSync(recursive: true);
        entity.copySync(copy.path);
      }
      // 체크아웃마다 사실이 달라야 한 디렉터리를 공유할 때 서로 덮어쓴다.
      File(
        p.join(other.path, 'lib', 'service.dart'),
      ).writeAsStringSync('class Service {}\nclass Extra {}\n');
      final arguments = ['compare', '--format', 'json', root.path, other.path];

      final plain = await run(arguments);
      final first = await run([
        arguments.first,
        '--incremental-user-cache',
        ...arguments.skip(1),
      ]);
      expect(first.status, plain.status, reason: first.error);
      expect(first.output, plain.output);
      final rootFacts = factsFor(root.path);
      final otherFacts = factsFor(other.path);
      expect(rootFacts.path, isNot(otherFacts.path));
      for (final facts in [rootFacts, otherFacts]) {
        expect(facts.existsSync(), isTrue, reason: facts.path);
        facts.setLastModifiedSync(DateTime(2001));
      }

      final second = await run([
        arguments.first,
        '--incremental-user-cache',
        ...arguments.skip(1),
      ]);
      expect(second.output, plain.output);
      for (final facts in [rootFacts, otherFacts]) {
        expect(
          facts.lastModifiedSync().isBefore(DateTime(2002)),
          isTrue,
          reason: '${facts.path} was rewritten',
        );
      }
    });

    test('workspace aggregation keeps its own fact cache', () async {
      // 저장소 fixture는 읽기만 한다 — 사실은 주입한 사용자 캐시 아래에 쓴다.
      final libraryUri = await Isolate.resolvePackageUri(
        Uri.parse('package:dartograph/dartograph.dart'),
      );
      expect(libraryUri, isNotNull);
      final fixture = p.join(
        File.fromUri(libraryUri!).parent.parent.path,
        'fixtures',
        'workspace_audit',
      );
      final arguments = ['deps', '--workspace', '--format', 'json', fixture];
      final plain = await run(arguments);
      final cached = await run([...arguments, '--incremental-user-cache']);

      expect(cached.status, plain.status, reason: cached.error);
      expect(cached.output, plain.output);
      expect(
        factsFor(fixture, mode: 'incremental-workspace').existsSync(),
        isTrue,
      );
      expect(factsFor(fixture).existsSync(), isFalse);
    });

    test('without a user cache location it analyzes and says so', () async {
      const unavailable =
          'incremental-cache-write-failed: no per-user cache directory is '
          'available (HOME, or XDG_CACHE_HOME on Linux and LOCALAPPDATA on '
          'Windows, is unset or not absolute); analysis is complete but the '
          'fact cache was not updated';
      Object? withoutUnavailable(Object? value) => switch (value) {
        Map() => {
          for (final entry in value.entries)
            entry.key: withoutUnavailable(entry.value),
        },
        List() => [
          for (final item in value)
            if (item != unavailable) withoutUnavailable(item),
        ],
        _ => value,
      };
      final plain = await _run([
        'dead',
        '--format',
        'json',
        root.path,
      ], userCacheEnvironment: const {});
      final run = await _run([
        'dead',
        '--format',
        'json',
        '--incremental-user-cache',
        root.path,
      ], userCacheEnvironment: const {});

      expect(run.status, plain.status, reason: run.error);
      final document = jsonDecode(run.output) as Map<String, Object?>;
      expect(
        (document['limitations']! as List<Object?>).where(
          (item) => item == unavailable,
        ),
        hasLength(1),
      );
      expect(withoutUnavailable(document), jsonDecode(plain.output));
      expect(Directory(p.join(root.path, '.dartograph')).existsSync(), isFalse);
    });

    test('conflicting or repeated switches are usage errors', () async {
      for (final invocation in [
        [
          'graph',
          '--format',
          'json',
          '--incremental-user-cache',
          '--incremental',
          cacheDirectory,
          root.path,
        ],
        [
          'dead',
          '--incremental',
          cacheDirectory,
          '--incremental-user-cache',
          root.path,
        ],
        [
          'graph',
          '--incremental-user-cache',
          '--format',
          'json',
          '--incremental-user-cache',
          root.path,
        ],
        ['graph', '--format', 'json', '--incremental-user-cache'],
        // 색인이 없는 명령은 이 스위치를 정의하지 않는다.
        ['runtime', '--incremental-user-cache', root.path],
        ['init', '--incremental-user-cache', root.path],
      ]) {
        final result = await run(invocation);
        expect(
          result.status,
          64,
          reason: 'usage error expected for $invocation (${result.error})',
        );
      }
      final conflict = await run([
        'graph',
        '--incremental-user-cache',
        '--incremental',
        cacheDirectory,
        root.path,
      ]);
      expect(conflict.error, contains('--incremental-user-cache'));
      expect(Directory(userCacheBase).existsSync(), isFalse);
      expect(Directory(cacheDirectory).existsSync(), isFalse);
    });
  });

  test('incremental option errors are usage errors', () async {
    for (final invocation in [
      ['graph', '--format', 'json', '--incremental', root.path],
      ['graph', '--format', 'json', '--incremental'],
      [
        'graph',
        '--format',
        'json',
        '--incremental',
        cacheDirectory,
        '--incremental',
        cacheDirectory,
        root.path,
      ],
      ['graph', '--format', 'json', '--incremental', '--level', root.path],
      ['dead', '--incremental', cacheDirectory, '--incremental', root.path],
      ['cycles', '--incremental', root.path],
    ]) {
      final result = await _run(invocation);
      expect(
        result.status,
        64,
        reason: 'usage error expected for $invocation (${result.error})',
      );
    }
  });

  test('commands without an index reject the option', () async {
    // runtime/skill/init은 이 옵션을 정의하지 않는다 — 조용히 무시하지 않는다.
    for (final invocation in [
      ['runtime', '--incremental', cacheDirectory, root.path],
      ['init', '--incremental', cacheDirectory, root.path],
    ]) {
      final result = await _run(invocation);
      expect(result.status, 64, reason: invocation.toString());
    }
  });
}

Future<({int status, String output, String error})> _run(
  List<String> arguments, {
  Map<String, String>? userCacheEnvironment,
}) async {
  final output = StringBuffer();
  final error = StringBuffer();
  final status = await runDartograph(
    arguments,
    output: output,
    error: error,
    userCacheEnvironment: userCacheEnvironment,
  );
  return (status: status, output: output.toString(), error: error.toString());
}
