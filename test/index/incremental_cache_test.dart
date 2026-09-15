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

  test('stats default to a cold run', () {
    final cache = IncrementalCache('unused');

    expect(cache.stats.reusedFiles, 0);
    expect(cache.stats.resolvedFiles, 0);
    expect(cache.stats.cacheNotUpdated, isFalse);
    expect(cache.file.path, p.join('unused', 'facts.json'));
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
