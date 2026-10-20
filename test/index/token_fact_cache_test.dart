import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/core/fact_cache.dart';
import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/incremental_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dup` 전용 토큰 사실의 캐시 계약이다.
///
/// 토큰 사실은 증분 캐시의 `facts.json`과 전체 결과 캐시의 결과 항목에 들어가지
/// 않고 따로 저장된다. dup 경로(`includeTokenSegments: true`)만 그것을 읽고, 다른
/// 명령은 읽지도 결과에 싣지도 않는다. 토큰 캐시가 낡았거나 망가졌으면 그 파일만
/// 다시 해석한다. 기대값은 같은 입력을 캐시 없이 전체 해석한 결과다.
void main() {
  group('incremental cache', () {
    test(
      'non-dup runs keep token facts out of facts.json and results',
      () async {
        final fixture = await _fixture();
        addTearDown(fixture.dispose);
        final full = await _full(fixture.root, tokens: true);
        // 오라클 자체를 손으로 확인한 값에 묶는다. import는 선언이 아니라 빠지고
        // `class Service { Model? field; }`의 토큰 여덟 개가 행 2~4에 놓인다.
        expect(
          full.tokenSegments
              .where((segment) => segment.source == 'project:lib/service.dart')
              .single
              .lines,
          [2, 2, 2, 3, 3, 3, 3, 4],
        );
        final expected = _tokensOf(full);

        final dead = await _run(fixture);
        expect(dead.stats.resolvedFiles, 5);
        expect(dead.result.tokenSegments, isEmpty);
        final facts = _entriesOf(fixture.factsFile);
        final tokens = _entriesOf(fixture.tokenFile);
        expect(facts.keys.toList()..sort(), _sources);
        expect(tokens.keys.toList()..sort(), _sources);
        for (final source in _sources) {
          final entry = facts[source]! as Map;
          expect(
            (entry['facts']! as Map).containsKey('tokens'),
            isFalse,
            reason: source,
          );
          // 토큰 항목은 같은 파일 키로 검증된다.
          expect((tokens[source]! as Map)['key'], entry['key'], reason: source);
        }

        // 모든 파일을 해석한 non-dup 실행이 남긴 토큰을 dup이 그대로 재사용한다.
        final dup = await _run(fixture, tokens: true);
        expect(dup.stats.resolvedFiles, 0);
        expect(dup.stats.reusedFiles, 5);
        expect(_tokensOf(dup.result), expected);
      },
    );

    test('a non-dup run never opens the token file', () async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      final expected = _tokensOf(await _full(fixture.root, tokens: true));
      await _run(fixture, tokens: true);
      // 위조한 토큰 캐시를 가리키는 링크다. 따라가면 dup이 위조 토큰을 재사용한다.
      final forgedContents = fixture.tokenFile.readAsStringSync();
      final forged = File(p.join(fixture.workspace.path, 'forged.json'))
        ..writeAsStringSync(forgedContents);
      fixture.tokenFile.deleteSync();
      Link(fixture.tokenFile.path).createSync(forged.path);

      final dead = await _run(fixture);
      expect(dead.stats.resolvedFiles, 0);
      expect(dead.stats.tokenCacheNotRead, isFalse);
      expect(
        dead.result.limitationDetails,
        isNot(anyElement(startsWith('incremental-cache-not-read:'))),
      );
      expect(
        FileSystemEntity.typeSync(fixture.tokenFile.path, followLinks: false),
        FileSystemEntityType.link,
      );

      final dup = await _run(fixture, tokens: true);
      expect(dup.stats.tokenCacheNotRead, isTrue);
      expect(dup.stats.resolvedFiles, 5);
      expect(_tokensOf(dup.result), expected);
      expect(
        dup.result.limitationDetails
            .where((detail) => detail.startsWith('incremental-cache-not-read:'))
            .toList(),
        [
          'incremental-cache-not-read: the dup token cache file is a symbolic '
              'link, is not a regular file, or exceeds the 1024 MiB read limit; '
              'it was ignored and every file was resolved again',
        ],
      );
      // 그 실행의 쓰기가 링크 자리를 정규 파일로 바꾸고 링크 대상은 건드리지 않는다.
      expect(
        FileSystemEntity.typeSync(fixture.tokenFile.path, followLinks: false),
        FileSystemEntityType.file,
      );
      expect(forged.readAsStringSync(), forgedContents);
      final again = await _run(fixture, tokens: true);
      expect(again.stats.resolvedFiles, 0);
      expect(again.stats.tokenCacheNotRead, isFalse);
    }, skip: Platform.isWindows);

    test('stale token entries re-resolve only their own files', () async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      await _run(fixture, tokens: true);
      final tokensBefore = fixture.tokenFile.readAsStringSync();

      // model ← service ← main, 그리고 model을 export하는 app이 폐쇄에 든다.
      await File(
        p.join(fixture.root, 'lib', 'model.dart'),
      ).writeAsString('class Model {}\nclass ModelExtra {}\n');
      final dead = await _run(fixture);
      expect(dead.stats.resolvedFiles, 4);
      // 일부만 해석한 non-dup 실행은 토큰을 다 갖지 않아 토큰 파일을 건드리지 않는다.
      expect(fixture.tokenFile.readAsStringSync(), tokensBefore);

      // 사실은 이미 현재 입력과 맞다. 토큰 항목은 내용이 바뀐 model만 낡았다 —
      // 토큰은 그 파일 내용만의 함수라 폐쇄 전체를 다시 해석하지 않는다.
      final dup = await _run(fixture, tokens: true);
      expect(dup.stats.resolvedFiles, 1);
      expect(dup.stats.reusedFiles, 4);
      expect(
        _tokensOf(dup.result),
        _tokensOf(await _full(fixture.root, tokens: true)),
      );
      final again = await _run(fixture, tokens: true);
      expect(again.stats.resolvedFiles, 0);
      expect(_tokensOf(again.result), _tokensOf(dup.result));

      // 지운 파일의 토큰 항목은 dup 실행이 버린다(남기면 토큰 파일이 계속 자란다).
      await File(p.join(fixture.root, 'lib', 'other.dart')).delete();
      final deleted = await _run(fixture, tokens: true);
      expect(
        _tokensOf(deleted.result),
        _tokensOf(await _full(fixture.root, tokens: true)),
      );
      expect(
        _tokensOf(deleted.result),
        isNot(anyElement(startsWith('project:lib/other.dart|'))),
      );
      expect(_entriesOf(fixture.tokenFile).keys.toList()..sort(), [
        for (final source in _sources)
          if (source != 'lib/other.dart') source,
      ]);
    });

    test('missing or damaged token entries are re-resolved for dup', () async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      final expected = _tokensOf(await _full(fixture.root, tokens: true));
      await _run(fixture, tokens: true);

      // 줄 수가 토큰 수와 다른 항목은 형식 오류다. 그대로 쓰면 dup이 행을 찾다
      // 범위 밖 접근으로 실패한다.
      final decoded = jsonDecode(fixture.tokenFile.readAsStringSync()) as Map;
      final damaged = ((decoded['entries']! as Map)['lib/other.dart']! as Map)
          .cast<String, Object?>();
      damaged['facts'] = {
        'tokens': [
          {
            'c': [1, 2],
            'l': [1],
          },
        ],
      };
      fixture.tokenFile.writeAsStringSync(jsonEncode(decoded));
      final dead = await _run(fixture);
      expect(dead.stats.resolvedFiles, 0);
      final repaired = await _run(fixture, tokens: true);
      expect(repaired.stats.resolvedFiles, 1);
      expect(_tokensOf(repaired.result), expected);

      // 토큰 파일이 없으면 non-dup 실행은 그대로 재사용하고, dup이 전부 다시 해석한다.
      fixture.tokenFile.deleteSync();
      expect((await _run(fixture)).stats.resolvedFiles, 0);
      expect(fixture.tokenFile.existsSync(), isFalse);
      final rebuilt = await _run(fixture, tokens: true);
      expect(rebuilt.stats.resolvedFiles, 5);
      expect(rebuilt.stats.tokenCacheNotRead, isFalse);
      expect(_tokensOf(rebuilt.result), expected);
      expect((await _run(fixture, tokens: true)).stats.resolvedFiles, 0);
    });
  });

  group('full result cache', () {
    test(
      'the result entry carries no token facts; dup reads its own',
      () async {
        final fixture = await _fixture();
        addTearDown(fixture.dispose);
        final expected = _tokensOf(await _full(fixture.root, tokens: true));
        final cache = _MemoryFactCache();

        final dead = await AnalyzerGraphIndex(cache: cache).index(fixture.root);
        expect(dead.tokenSegments, isEmpty);
        // 분석 한 번이 결과 항목과 토큰 항목을 따로 쓴다.
        expect(cache.writeCount, 2);
        final payloads = [
          for (final payload in cache.values.values)
            (jsonDecode(payload) as Map).cast<String, Object?>(),
        ];
        final result = payloads.where((entry) => entry.containsKey('nodes'));
        final tokens = payloads.where(
          (entry) => entry.containsKey('tokenSegments'),
        );
        expect(result.single.containsKey('tokenSegments'), isFalse);
        expect(tokens.single.containsKey('nodes'), isFalse);

        // non-dup 재실행은 결과 항목 하나만 읽는다.
        final warmDead = await AnalyzerGraphIndex(
          cache: cache,
        ).index(fixture.root);
        expect(cache.readCount, 2);
        expect(cache.writeCount, 2);
        expect(warmDead.tokenSegments, isEmpty);

        // dup은 두 항목을 읽고 다시 분석하지 않는다.
        final warmDup = await AnalyzerGraphIndex(
          cache: cache,
          includeTokenSegments: true,
        ).index(fixture.root);
        expect(cache.readCount, 4);
        expect(cache.writeCount, 2);
        expect(_tokensOf(warmDup), expected);
      },
    );

    test('a missing or damaged token entry re-analyzes for dup only', () async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      final expected = _tokensOf(await _full(fixture.root, tokens: true));
      final cache = _MemoryFactCache();
      await AnalyzerGraphIndex(cache: cache).index(fixture.root);
      final tokenKey = cache.values.entries
          .singleWhere((entry) => entry.value.contains('"tokenSegments"'))
          .key;
      final saved = cache.values[tokenKey]!;

      cache.values.remove(tokenKey);
      await AnalyzerGraphIndex(cache: cache).index(fixture.root);
      expect(cache.writeCount, 2, reason: 'non-dup runs do not need tokens');
      final missing = await AnalyzerGraphIndex(
        cache: cache,
        includeTokenSegments: true,
      ).index(fixture.root);
      expect(cache.writeCount, 4);
      expect(_tokensOf(missing), expected);
      expect(cache.values[tokenKey], saved);

      // 첫 세그먼트의 행 하나를 지운다(토큰 수와 행 수가 어긋난다).
      final document = (jsonDecode(saved) as Map).cast<String, Object?>();
      final first = ((document['tokenSegments']! as List).first as Map)
          .cast<String, Object?>();
      first['l'] = (first['l']! as List).skip(1).toList();
      cache.values[tokenKey] = jsonEncode(document);
      await AnalyzerGraphIndex(cache: cache).index(fixture.root);
      expect(cache.writeCount, 4);
      final damaged = await AnalyzerGraphIndex(
        cache: cache,
        includeTokenSegments: true,
      ).index(fixture.root);
      expect(cache.writeCount, 6);
      expect(_tokensOf(damaged), expected);
    });
  });
}

/// 픽스처의 분석 단위다(정렬).
const _sources = [
  'lib/app.dart',
  'lib/main.dart',
  'lib/model.dart',
  'lib/other.dart',
  'lib/service.dart',
];

/// 토큰 세그먼트의 결정적 표현이다(출처·코드·행 모두 비교한다).
List<String> _tokensOf(AnalyzerGraphResult result) => [
  for (final segment in result.tokenSegments)
    '${segment.source}|${segment.codes.join(',')}|${segment.lines.join(',')}',
];

Map<Object?, Object?> _entriesOf(File file) =>
    (jsonDecode(file.readAsStringSync()) as Map)['entries']! as Map;

/// 증분 실행 한 번의 관측값이다.
final class _Run {
  const _Run(this.result, this.stats);

  final AnalyzerGraphResult result;
  final IncrementalStats stats;
}

/// 캐시 없이 전체 해석한 결과다(OS 사용자 캐시를 쓰지 않는다).
Future<AnalyzerGraphResult> _full(String root, {required bool tokens}) =>
    AnalyzerGraphIndex(
      cache: _ColdCache(),
      includeTokenSegments: tokens,
    ).index(root);

Future<_Run> _run(_Fixture fixture, {bool tokens = false}) async {
  final cache = IncrementalCache(fixture.cacheDirectory);
  final result = await AnalyzerGraphIndex(
    incremental: cache,
    includeTokenSegments: tokens,
  ).index(fixture.root);
  return _Run(result, cache.stats);
}

/// 분석 대상 루트와 캐시 디렉터리를 함께 가진 임시 픽스처다.
final class _Fixture {
  const _Fixture(this.workspace, this.root, this.cacheDirectory);

  final Directory workspace;
  final String root;
  final String cacheDirectory;

  File get factsFile => File(p.join(cacheDirectory, 'facts.json'));

  File get tokenFile => File(p.join(cacheDirectory, 'tokens.json'));

  Future<void> dispose() => workspace.delete(recursive: true);
}

Future<_Fixture> _fixture() async {
  final workspace = await Directory.systemTemp.createTemp(
    'dartograph-token-cache.',
  );
  final root = p.join(workspace.path, 'app');
  for (final entry in const {
    'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ^3.11.0\n',
    'lib/app.dart': "export 'model.dart';\n",
    'lib/model.dart': 'class Model {}\n',
    'lib/service.dart':
        "import 'model.dart';\nclass Service {\n  Model? field;\n}\n",
    'lib/main.dart': "import 'service.dart';\nvoid main() {\n  Service();\n}\n",
    'lib/other.dart': 'class Other {}\n',
  }.entries) {
    final file = File(p.join(root, entry.key));
    await file.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  return _Fixture(workspace, root, p.join(workspace.path, 'facts'));
}

/// 항상 miss인 캐시 — 전체 해석 경로를 그대로 쓴다.
final class _ColdCache implements FactCache {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String payload) async {}
}

final class _MemoryFactCache implements FactCache {
  final values = <String, String>{};
  var readCount = 0;
  var writeCount = 0;

  @override
  Future<String?> read(String key) async {
    readCount++;
    return values[key];
  }

  @override
  Future<void> write(String key, String payload) async {
    writeCount++;
    values[key] = payload;
  }
}
