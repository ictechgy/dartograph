import 'dart:io';

import 'package:dartograph/src/index/incremental_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 사실 캐시 경계 자체의 계약이다 — 영속·폴백·원자적 교체.
///
/// 캐시는 최적화지 계약이 아니다: 읽을 수 없거나 형식이 어긋나면 빈 캐시로
/// 취급하고, 쓸 수 없으면 false만 돌려준다(분석은 호출자가 계속한다).
void main() {
  test('store and load round-trip entries', () async {
    final directory = await Directory.systemTemp.createTemp(
      'dartograph-incremental-cache.',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = IncrementalCache(directory.path);
    final key = IncrementalCache.keyFor(
      resolutionKey: 'resolution',
      contentHash: 'content',
    );

    expect(await cache.load(), isEmpty);
    expect(await cache.load(), isEmpty);
    expect(
      await cache.store({
        'lib/a.dart': CachedFacts(key: key, facts: {'nodes': 1}),
      }),
      isTrue,
    );
    final loaded = await cache.load();
    expect(loaded.keys, ['lib/a.dart']);
    expect(loaded['lib/a.dart']!.key, key);
    expect(loaded['lib/a.dart']!.facts, {'nodes': 1});
    // 교체는 임시 파일 + rename이다 — 임시 파일이 남지 않는다.
    expect(directory.listSync().map((entity) => p.basename(entity.path)), [
      'facts.json',
    ]);
  });

  test('token facts round-trip in their own file beside facts.json', () async {
    final directory = await Directory.systemTemp.createTemp(
      'dartograph-incremental-cache-tokens.',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = IncrementalCache(directory.path);

    expect(cache.tokenFile.path, p.join(directory.path, 'tokens.json'));
    expect(await cache.loadTokens(), isEmpty);
    expect(cache.stats.tokenCacheNotRead, isFalse);
    expect(
      await cache.storeTokens({
        'lib/a.dart': CachedFacts(key: 'k', facts: const {'tokens': []}),
      }),
      isTrue,
    );
    // 토큰 파일만 썼다 — 사실 파일은 아직 없고, 사실을 읽는 쪽은 토큰을 보지 않는다.
    expect(await cache.load(), isEmpty);
    expect(directory.listSync().map((entity) => p.basename(entity.path)), [
      'tokens.json',
    ]);
    expect(
      await cache.store({
        'lib/a.dart': CachedFacts(key: 'k', facts: const {'nodes': 1}),
      }),
      isTrue,
    );
    expect((await cache.load())['lib/a.dart']!.facts, {'nodes': 1});
    final tokens = await cache.loadTokens();
    expect(tokens.keys, ['lib/a.dart']);
    expect(tokens['lib/a.dart']!.facts, {'tokens': <Object?>[]});

    // 형식은 사실 파일과 같다 — 다른 스키마 버전은 전부 미스다.
    await cache.tokenFile.writeAsString(
      '{"entries":{"lib/a.dart":{"facts":{},"key":"k"}},'
      '"schemaVersion":${IncrementalCache.schemaVersion + 1}}',
    );
    expect(await cache.loadTokens(), isEmpty);
    expect(cache.stats.tokenCacheNotRead, isFalse);
  });

  test('load treats unreadable and mismatched caches as empty', () async {
    final directory = await Directory.systemTemp.createTemp(
      'dartograph-incremental-cache-invalid.',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = IncrementalCache(directory.path);
    final file = File(p.join(directory.path, 'facts.json'));

    await file.writeAsString('{');
    expect(await cache.load(), isEmpty);

    await file.writeAsString('[]');
    expect(await cache.load(), isEmpty);

    await file.writeAsString('{"entries":[],"schemaVersion":1}');
    expect(await cache.load(), isEmpty);

    await file.writeAsString(
      '{"entries":{},"schemaVersion":${IncrementalCache.schemaVersion + 1}}',
    );
    expect(await cache.load(), isEmpty);

    // 형식이 어긋난 항목은 미스지만 나머지 항목은 살아남는다.
    await file.writeAsString(
      '{"entries":{"lib/a.dart":7,"lib/b.dart":{"facts":"x"},'
      '"lib/c.dart":{"facts":{"nodes":[]},"key":"k"}},'
      '"schemaVersion":${IncrementalCache.schemaVersion}}',
    );
    final loaded = await cache.load();
    expect(loaded.keys, ['lib/c.dart']);
    expect(loaded['lib/c.dart']!.facts, {'nodes': <Object?>[]});

    // 캐시 경로 자리에 파일이 있으면 디렉터리를 만들 수 없어 쓰기가 실패한다.
    final blocked = IncrementalCache(
      p.join(directory.path, 'facts.json', 'nested'),
    );
    expect(await blocked.load(), isEmpty);
    expect(
      await blocked.store({
        'lib/a.dart': CachedFacts(key: 'k', facts: const {}),
      }),
      isFalse,
    );
  });

  test(
    'load never opens a linked, FIFO, or device cache file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'dartograph-incremental-cache-planted.',
      );
      addTearDown(() => directory.delete(recursive: true));
      // 정상 캐시를 다른 디렉터리에 만들어 둔다. 링크가 이 파일을 가리켜도
      // 열지 않아야 한다 — 저장소가 위조한 캐시를 가리키는 경우와 같다.
      final genuine = IncrementalCache(p.join(directory.path, 'genuine'));
      final key = IncrementalCache.keyFor(
        resolutionKey: 'resolution',
        contentHash: 'content',
      );
      expect(
        await genuine.store({
          'lib/a.dart': CachedFacts(key: key, facts: const {'nodes': 1}),
        }),
        isTrue,
      );
      final fifo = p.join(directory.path, 'pipe');
      final mkfifo = await Process.run('mkfifo', [fifo]);
      expect(mkfifo.exitCode, 0, reason: mkfifo.stderr as String);

      var cases = 0;
      Future<IncrementalCache> planted(
        void Function(String factsPath) plant,
      ) async {
        final cacheDirectory = Directory(
          p.join(directory.path, 'planted-${cases++}'),
        )..createSync();
        plant(p.join(cacheDirectory.path, 'facts.json'));
        return IncrementalCache(cacheDirectory.path);
      }

      // /dev/null은 길이 0·즉시 EOF라 수정 전 코드도 멈추지 않는 장치
      // 대역이다 — /dev/zero라면 같은 경로가 EOF 없이 메모리를 채운다.
      // FIFO는 쓰는 쪽이 없으면 열기에서 영구 대기하므로 마지막에 둔다.
      final rejected = <String, void Function(String)>{
        'link to a valid cache': (path) =>
            Link(path).createSync(genuine.file.path),
        'link to a device': (path) => Link(path).createSync('/dev/null'),
        'dangling link': (path) =>
            Link(path).createSync(p.join(directory.path, 'absent')),
        'link to a FIFO': (path) => Link(path).createSync(fifo),
        'FIFO': (path) {
          final made = Process.runSync('mkfifo', [path]);
          expect(made.exitCode, 0, reason: made.stderr as String);
        },
      };
      for (final MapEntry(key: name, value: plant) in rejected.entries) {
        final cache = await planted(plant);
        expect(await cache.load(), isEmpty, reason: name);
        expect(cache.stats.cacheNotRead, isTrue, reason: name);
      }
      // dup만 읽는 토큰 파일도 같은 경계를 지난다. 두 파일의 관측값은 따로다 —
      // 버린 파일이 어느 쪽인지 limitation이 구별한다.
      for (final MapEntry(key: name, value: plant) in rejected.entries) {
        final cacheDirectory = Directory(
          p.join(directory.path, 'planted-tokens-${cases++}'),
        )..createSync();
        final cache = IncrementalCache(cacheDirectory.path);
        plant(cache.tokenFile.path);
        expect(await cache.loadTokens(), isEmpty, reason: name);
        expect(cache.stats.tokenCacheNotRead, isTrue, reason: name);
        expect(cache.stats.cacheNotRead, isFalse, reason: name);
      }

      // 부재(첫 실행)와 디렉터리는 열어도 멈추지 않는다 — 조용한 미스이고,
      // 디렉터리는 다음 쓰기 실패가 limitation으로 드러난다.
      final absent = await planted((_) {});
      expect(await absent.load(), isEmpty);
      expect(absent.stats.cacheNotRead, isFalse);
      final folder = await planted((path) => Directory(path).createSync());
      expect(await folder.load(), isEmpty);
      expect(folder.stats.cacheNotRead, isFalse);
      expect(await genuine.load(), hasLength(1));
      expect(genuine.stats.cacheNotRead, isFalse);
    },
    skip: Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('load reads a regular cache file only up to the read limit', () async {
    final directory = await Directory.systemTemp.createTemp(
      'dartograph-incremental-cache-limit.',
    );
    addTearDown(() => directory.delete(recursive: true));
    final writer = IncrementalCache(directory.path);
    expect(
      await writer.store({
        'lib/a.dart': CachedFacts(key: 'k', facts: const {'nodes': 1}),
      }),
      isTrue,
    );
    final length = writer.file.lengthSync();

    final exact = IncrementalCache(directory.path, readLimit: length);
    expect((await exact.load()).keys, ['lib/a.dart']);
    expect(exact.stats.cacheNotRead, isFalse);

    final below = IncrementalCache(directory.path, readLimit: length - 1);
    expect(await below.load(), isEmpty);
    expect(below.stats.cacheNotRead, isTrue);
    // 같은 인스턴스의 다음 load는 관측값을 새로 정한다.
    await writer.file.writeAsString('{}');
    expect(await below.load(), isEmpty);
    expect(below.stats.cacheNotRead, isFalse);

    // 길이 0인 정규 파일은 상한까지 나눠 읽는 경로를 지난다 — 빈 내용은
    // 형식 오류(조용한 미스)다.
    await writer.file.writeAsString('');
    final empty = IncrementalCache(directory.path, readLimit: 8);
    expect(await empty.load(), isEmpty);
    expect(empty.stats.cacheNotRead, isFalse);
  });

  test(
    'store replaces a linked cache file instead of writing through it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'dartograph-incremental-cache-store-link.',
      );
      addTearDown(() => directory.delete(recursive: true));
      final outside = File(p.join(directory.path, 'outside.json'))
        ..writeAsStringSync('precious');
      final cacheDirectory = Directory(p.join(directory.path, 'cache'))
        ..createSync();
      final cache = IncrementalCache(cacheDirectory.path);
      Link(cache.file.path).createSync(outside.path);

      expect(
        await cache.store({
          'lib/a.dart': CachedFacts(key: 'k', facts: const {'nodes': 1}),
        }),
        isTrue,
      );

      expect(outside.readAsStringSync(), 'precious');
      expect(
        FileSystemEntity.typeSync(cache.file.path, followLinks: false),
        FileSystemEntityType.file,
      );
      expect((await cache.load()).keys, ['lib/a.dart']);
      expect(cache.stats.cacheNotRead, isFalse);
    },
    skip: Platform.isWindows,
  );

  test('stats default to a cold run', () {
    final cache = IncrementalCache('unused');

    expect(cache.stats.reusedFiles, 0);
    expect(cache.stats.resolvedFiles, 0);
    expect(cache.stats.cacheNotUpdated, isFalse);
    expect(cache.stats.cacheNotRead, isFalse);
    expect(cache.stats.tokenCacheNotRead, isFalse);
    expect(cache.file.path, p.join('unused', 'facts.json'));
    expect(cache.tokenFile.path, p.join('unused', 'tokens.json'));
    // 문서화된 기본 읽기 상한(1 GiB)이다.
    expect(cache.readLimit, 1024 * 1024 * 1024);
  });

  test('cached facts reject malformed JSON values', () {
    expect(CachedFacts.fromJson(null), isNull);
    expect(CachedFacts.fromJson('value'), isNull);
    expect(
      CachedFacts.fromJson({'key': 1, 'facts': <String, Object?>{}}),
      isNull,
    );
    expect(CachedFacts.fromJson({'key': 'k'}), isNull);
    expect(CachedFacts.fromJson({'facts': <String, Object?>{}}), isNull);
    final parsed = CachedFacts.fromJson({
      'facts': {'nodes': <Object?>[]},
      'key': 'k',
    });
    expect(parsed, isNotNull);
    expect(parsed!.key, 'k');
    expect(parsed.toJson(), {
      'facts': {'nodes': <Object?>[]},
      'key': 'k',
    });
  });
}
