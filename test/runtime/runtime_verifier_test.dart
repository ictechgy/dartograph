import 'package:dartograph/src/runtime/runtime_facts.dart';
import 'package:dartograph/src/runtime/runtime_verifier.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 파일 시스템을 직접 관측하지 않도록 메모리 구현을 주입한다.
final class _MemoryFileSystem implements RuntimeFileSystem {
  _MemoryFileSystem({
    Map<String, RuntimePathState> states = const {},
    Set<String> executables = const {},
  }) : _states = {
         for (final entry in states.entries)
           p.normalize(entry.key): entry.value,
       },
       _executables = {for (final path in executables) p.normalize(path)};

  final Map<String, RuntimePathState> _states;
  final Set<String> _executables;

  @override
  RuntimePathState state(String path) =>
      _states[p.normalize(path)] ?? RuntimePathState.missing;

  @override
  bool executableAt(String path) => _executables.contains(p.normalize(path));
}

RuntimeFact _fact({
  RuntimeFactKind kind = RuntimeFactKind.env,
  RuntimeFactChannel channel = RuntimeFactChannel.processEnvironment,
  required String name,
  String? path,
  String? defaultValue,
  bool literal = true,
  String? unverifiableReason,
  int line = 1,
  int column = 3,
}) => RuntimeFact(
  kind: kind,
  channel: channel,
  name: name,
  source: 'project:lib/a.dart',
  line: line,
  column: column,
  detail: 'detail',
  path: path,
  defaultValue: defaultValue,
  literal: literal,
  unverifiableReason: unverifiableReason,
);

RuntimeReport _analyze(
  List<RuntimeFact> facts, {
  RuntimeInputs inputs = const RuntimeInputs(),
  RuntimeFileSystem? fileSystem,
  RuntimeExecution? execution,
  int? limit,
  bool verify = true,
  Set<RuntimeFactKind>? kinds,
  Set<String>? statuses,
}) => RuntimeVerifier.analyze(
  facts: facts,
  inputs: inputs,
  fileSystem: fileSystem ?? _MemoryFileSystem(),
  execution: execution,
  limit: limit,
  verify: verify,
  kinds: kinds,
  statuses: statuses,
);

List<RuntimeFactKind> _kinds(
  Map<RuntimeFactKind, List<RuntimeFact>> detected,
) => RuntimeFactKind.values.where((k) => detected[k]!.isNotEmpty).toList();

void main() {
  group('env 판정', () {
    test('dart-define은 제공 여부와 기본값으로 present·defaulted·missing을 가른다', () {
      final report = _analyze([
        _fact(name: 'DEFINE_SET', channel: RuntimeFactChannel.dartDefine),
        _fact(
          name: 'DEFINE_DEFAULTED',
          channel: RuntimeFactChannel.dartDefine,
          defaultValue: '8080',
        ),
        _fact(name: 'DEFINE_MISSING', channel: RuntimeFactChannel.dartDefine),
      ], inputs: const RuntimeInputs(dartDefines: {'DEFINE_SET': 'value'}));

      expect(report.present.single.fact.name, 'DEFINE_SET');
      expect(report.present.single.verdict, RuntimeVerdict.present);
      expect(report.present.single.evidence, '--dart-define DEFINE_SET');
      expect(report.defaulted.single.fact.name, 'DEFINE_DEFAULTED');
      expect(report.defaulted.single.evidence, 'default value "8080"');
      expect(report.missing.single.fact.name, 'DEFINE_MISSING');
      expect(
        report.missing.single.evidence,
        'not provided by --dart-define and no default',
      );
    });

    test('환경변수는 dart-define을 충족하지 않고 그 반대도 같다', () {
      final report = _analyze(
        [
          _fact(name: 'DEFINE', channel: RuntimeFactChannel.dartDefine),
          _fact(name: 'ENV'),
        ],
        inputs: const RuntimeInputs(
          environment: {'DEFINE': 'value'},
          dartDefines: {'ENV': 'value'},
          environmentFromProcess: false,
        ),
      );

      expect(report.present, isEmpty);
      expect(report.missing.map((item) => item.fact.name), ['DEFINE', 'ENV']);
    });

    test('환경 출처에 따라 근거 문구가 달라진다', () {
      final facts = [_fact(name: 'TOKEN'), _fact(name: 'ABSENT')];
      final process = _analyze(
        facts,
        inputs: const RuntimeInputs(environment: {'TOKEN': 'x'}),
      );
      expect(process.present.single.evidence, 'process environment');
      expect(
        process.missing.single.evidence,
        'not present in the process environment',
      );

      final hermetic = _analyze(
        facts,
        inputs: const RuntimeInputs(
          environment: {'TOKEN': 'x'},
          environmentFromProcess: false,
        ),
      );
      expect(hermetic.present.single.evidence, '--env TOKEN');
      expect(hermetic.missing.single.evidence, 'not provided by --env');
    });
  });

  group('경로 판정', () {
    test('파일·디렉터리·에셋을 존재 여부로 판정한다', () {
      final fileSystem = _MemoryFileSystem(
        states: {
          'config/app.yaml': RuntimePathState.file,
          'config/dir.yaml': RuntimePathState.directory,
          'logs/': RuntimePathState.directory,
          'assets/logo.json': RuntimePathState.file,
        },
      );
      final report = _analyze([
        _fact(
          kind: RuntimeFactKind.config,
          channel: RuntimeFactChannel.filePath,
          name: 'config/app.yaml',
          path: 'config/app.yaml',
        ),
        _fact(
          kind: RuntimeFactKind.config,
          channel: RuntimeFactChannel.filePath,
          name: 'config/dir.yaml',
          path: 'config/dir.yaml',
        ),
        _fact(
          kind: RuntimeFactKind.config,
          channel: RuntimeFactChannel.filePath,
          name: 'config/missing.yaml',
          path: 'config/missing.yaml',
        ),
        _fact(
          kind: RuntimeFactKind.config,
          channel: RuntimeFactChannel.directoryPath,
          name: 'logs/',
          path: 'logs/',
        ),
        _fact(
          kind: RuntimeFactKind.asset,
          channel: RuntimeFactChannel.assetBundle,
          name: 'assets/logo.json',
          path: 'assets/logo.json',
        ),
        _fact(
          kind: RuntimeFactKind.asset,
          channel: RuntimeFactChannel.assetBundle,
          name: 'assets/missing.json',
          path: 'assets/missing.json',
        ),
      ], fileSystem: fileSystem);

      expect(report.present.map((item) => item.fact.name), [
        'config/app.yaml',
        'logs/',
        'assets/logo.json',
      ]);
      expect(report.present.first.evidence, 'file exists: config/app.yaml');
      expect(report.present[1].evidence, 'directory exists: logs/');
      expect(report.present[2].evidence, 'asset file exists: assets/logo.json');
      // 종류가 어긋나면 존재해도 충족이 아니다.
      expect(report.missing.map((item) => item.fact.name), [
        'config/dir.yaml',
        'config/missing.yaml',
        'assets/missing.json',
      ]);
      expect(
        report.missing.first.evidence,
        'a directory exists at config/dir.yaml, not a file',
      );
      expect(
        report.missing.last.evidence,
        'asset not found: assets/missing.json',
      );
    });

    test('경로가 없는 사실은 존재 검사를 시도하지 않는다', () {
      final report = _analyze([
        _fact(
          kind: RuntimeFactKind.asset,
          channel: RuntimeFactChannel.assetBundle,
          name: 'assets/x.json',
        ),
      ]);

      expect(
        report.unverified.single.reason,
        'no-path: the fact carries no checkable path',
      );
    });
  });

  group('실행 파일 판정', () {
    test('PATH 조회와 경로 직접 지정을 구분한다', () {
      final fileSystem = _MemoryFileSystem(
        states: {
          '/opt/tool': RuntimePathState.file,
          '/opt/data': RuntimePathState.file,
        },
        executables: {'/usr/bin/git', '/opt/tool'},
      );
      final report = _analyze(
        [
          _fact(
            kind: RuntimeFactKind.dynamicLoad,
            channel: RuntimeFactChannel.executable,
            name: 'git',
            path: 'git',
          ),
          _fact(
            kind: RuntimeFactKind.dynamicLoad,
            channel: RuntimeFactChannel.executable,
            name: 'nope',
            path: 'nope',
          ),
          _fact(
            kind: RuntimeFactKind.dynamicLoad,
            channel: RuntimeFactChannel.executable,
            name: '/opt/tool',
            path: '/opt/tool',
          ),
          _fact(
            kind: RuntimeFactKind.dynamicLoad,
            channel: RuntimeFactChannel.executable,
            name: '/opt/data',
            path: '/opt/data',
          ),
        ],
        inputs: const RuntimeInputs(environment: {'PATH': '/usr/bin:/bin'}),
        fileSystem: fileSystem,
      );

      // 정렬은 이름이 아니라 위치 순이므로 이름→근거로 확인한다.
      expect(
        {for (final item in report.present) item.fact.name: item.evidence},
        {
          'git': 'executable found on PATH',
          '/opt/tool': 'executable file: /opt/tool',
        },
      );
      expect(
        {for (final item in report.missing) item.fact.name: item.evidence},
        {
          'nope': 'no executable named nope on PATH',
          '/opt/data': 'file exists but is not executable: /opt/data',
        },
      );
    });

    test('PATH가 없으면 맨 이름은 미판정으로 남긴다', () {
      final report = _analyze([
        _fact(
          kind: RuntimeFactKind.dynamicLoad,
          channel: RuntimeFactChannel.executable,
          name: 'git',
          path: 'git',
        ),
      ]);

      expect(report.unverified.single.reason, startsWith('path-not-provided'));
    });

    test('Windows에서는 세미콜론 구분자와 실행 확장자를 쓴다', () {
      final expected = p.join(r'D:\tools', 'tool.exe');
      final report = _analyze(
        [
          _fact(
            kind: RuntimeFactKind.dynamicLoad,
            channel: RuntimeFactChannel.executable,
            name: 'tool',
            path: 'tool',
          ),
        ],
        inputs: const RuntimeInputs(
          environment: {'PATH': r'C:\tools;D:\tools'},
          windows: true,
        ),
        fileSystem: _MemoryFileSystem(executables: {expected}),
      );

      expect(report.present.single.evidence, 'executable found on PATH');
    });
  });

  group('URI 판정', () {
    test('상대 경로·file 스킴은 검사하고 원격 스킴은 미판정으로 남긴다', () {
      final report = _analyze(
        [
          _fact(
            kind: RuntimeFactKind.dynamicLoad,
            channel: RuntimeFactChannel.uri,
            name: 'bin/worker.dart',
            path: 'bin/worker.dart',
          ),
          _fact(
            kind: RuntimeFactKind.dynamicLoad,
            channel: RuntimeFactChannel.uri,
            name: 'file:///tmp/worker.dart',
            path: 'file:///tmp/worker.dart',
          ),
          _fact(
            kind: RuntimeFactKind.dynamicLoad,
            channel: RuntimeFactChannel.uri,
            name: 'https://example.com/worker.dart',
            path: 'https://example.com/worker.dart',
          ),
          _fact(
            kind: RuntimeFactKind.dynamicLoad,
            channel: RuntimeFactChannel.uri,
            name: 'package:other/worker.dart',
            path: 'package:other/worker.dart',
          ),
        ],
        fileSystem: _MemoryFileSystem(
          states: {
            'bin/worker.dart': RuntimePathState.file,
            '/tmp/worker.dart': RuntimePathState.file,
          },
        ),
      );

      expect(report.present.map((item) => item.fact.name), [
        'bin/worker.dart',
        'file:///tmp/worker.dart',
      ]);
      expect(report.present.last.evidence, 'file exists: /tmp/worker.dart');
      expect(report.unverified.map((item) => item.fact.name), [
        'https://example.com/worker.dart',
        'package:other/worker.dart',
      ]);
      expect(report.unverified.first.reason, startsWith('remote-uri'));
      expect(report.unverified.last.reason, startsWith('uri-scheme'));
    });
  });

  group('미판정', () {
    test('탐지 단계 사유를 그대로 싣고 판정 규칙을 적용하지 않는다', () {
      final report = _analyze([
        _fact(
          name: 'API_TOKEN',
          path: 'ignored.txt',
          unverifiableReason: 'whole-environment-map: every key is read',
        ),
        _fact(name: runtimeComputedName, literal: false),
        _fact(
          kind: RuntimeFactKind.dynamicLoad,
          channel: RuntimeFactChannel.reflection,
          name: 'callee',
        ),
        _fact(
          kind: RuntimeFactKind.external,
          channel: RuntimeFactChannel.externalUrl,
          name: 'https://example.com',
        ),
        _fact(
          kind: RuntimeFactKind.dynamicLoad,
          channel: RuntimeFactChannel.nativeLibrary,
          name: 'libfoo.so',
        ),
      ]);

      expect(report.present, isEmpty);
      expect(report.missing, isEmpty);
      final reasons = {
        for (final item in report.unverified) item.fact.name: item.reason,
      };
      expect(reasons['API_TOKEN'], 'whole-environment-map: every key is read');
      expect(reasons[runtimeComputedName], startsWith('computed-target'));
      expect(reasons['callee'], startsWith('reflection-target'));
      expect(reasons['https://example.com'], startsWith('external-resource'));
      expect(reasons['libfoo.so'], startsWith('bare-library-name'));
      // 탐지 단계 사유가 있는 사실은 존재 검사 결과가 아니라 사유를 싣는다.
      expect(
        report.unverified
            .firstWhere((item) => item.fact.name == 'API_TOKEN')
            .fact
            .channel
            .key,
        'environment',
      );
      expect(
        report.unverified
            .firstWhere((item) => item.fact.name == 'libfoo.so')
            .toJson()['kind'],
        'dynamicLoad',
      );
    });
  });

  group('네이티브 라이브러리 판정', () {
    RuntimeFact library(String name, {String? path}) => _fact(
      kind: RuntimeFactKind.dynamicLoad,
      channel: RuntimeFactChannel.nativeLibrary,
      name: name,
      path: path,
    );

    test('경로로 지정한 라이브러리는 존재를 확인해 present·missing을 가른다', () {
      final report = _analyze(
        [
          library('assets/libcorpus.so', path: 'assets/libcorpus.so'),
          library('lib/absent.so', path: 'lib/absent.so'),
          library('/opt/lib/libz.so', path: '/opt/lib/libz.so'),
        ],
        fileSystem: _MemoryFileSystem(
          states: {
            'assets/libcorpus.so': RuntimePathState.file,
            '/opt/lib/libz.so': RuntimePathState.directory,
          },
        ),
      );

      expect(report.present.map((item) => item.fact.name), [
        'assets/libcorpus.so',
      ]);
      expect(
        report.present.single.evidence,
        'native library exists: assets/libcorpus.so',
      );
      final reasons = {
        for (final item in report.missing) item.fact.name: item.evidence,
      };
      expect(
        reasons['lib/absent.so'],
        'native library not found: lib/absent.so',
      );
      expect(
        reasons['/opt/lib/libz.so'],
        'a directory exists at /opt/lib/libz.so, not a native library',
      );
      // 경로가 있으면 판정할 수 있으므로 미판정으로 남기지 않는다.
      expect(report.unverified, isEmpty);
    });

    test('맨 이름은 경로가 없어 미판정으로 남긴다', () {
      final report = _analyze([library('libcorpus.so')]);

      expect(report.present, isEmpty);
      expect(report.missing, isEmpty);
      expect(report.unverified.single.fact.name, 'libcorpus.so');
      expect(report.unverified.single.reason, startsWith('bare-library-name'));
    });
  });

  group('위험도', () {
    List<RuntimeFact> missingFacts(int count) => [
      for (var index = 0; index < count; index++)
        _fact(name: 'MISSING_$index', line: index + 1),
    ];

    test('미충족·미판정·외부 자원을 각각 한 번만 센다', () {
      final report = _analyze([
        ...missingFacts(2),
        ...List.generate(
          3,
          (index) => _fact(name: runtimeComputedName, literal: false),
        ),
        ...List.generate(
          2,
          (index) => _fact(
            kind: RuntimeFactKind.external,
            channel: RuntimeFactChannel.externalUrl,
            name: 'https://example.com/$index',
          ),
        ),
      ]);

      expect(report.risk.factors.map((factor) => factor.name), [
        'missing-inputs',
        'unverified-facts',
        'external-resources',
      ]);
      expect(report.risk.factors.map((factor) => factor.weight), [24, 15, 8]);
      expect(report.risk.score, 47);
      expect(report.risk.level, 'medium');
    });

    test('요인별 상한과 총점 상한을 넘지 않는다', () {
      final report = _analyze([
        ...missingFacts(6),
        ...List.generate(
          10,
          (index) => _fact(name: runtimeComputedName, literal: false),
        ),
        ...List.generate(
          5,
          (index) => _fact(
            kind: RuntimeFactKind.external,
            channel: RuntimeFactChannel.externalUrl,
            name: 'https://example.com/$index',
          ),
        ),
      ]);

      expect(report.risk.factors.map((factor) => factor.weight), [72, 24, 16]);
      expect(report.risk.score, 100);
      expect(report.risk.level, 'high');
    });

    test('미충족 하나면 low, 실행 실패는 medium이다', () {
      final missing = _analyze(missingFacts(1));
      expect(missing.risk.score, 12);
      expect(missing.risk.level, 'low');

      final failed = _analyze(
        const [],
        execution: const RuntimeExecution(
          entrypoint: 'bin/probe.dart',
          exitCode: 3,
          timedOut: false,
          stderrSummary: 'boom',
        ),
      );
      expect(failed.risk.factors.single.name, 'execution-failed');
      expect(failed.risk.factors.single.weight, 30);
      expect(failed.risk.level, 'medium');
    });

    test('요인이 없으면 none이다', () {
      final report = _analyze([
        _fact(name: 'TOKEN'),
      ], inputs: const RuntimeInputs(environment: {'TOKEN': 'x'}));

      expect(report.risk.score, 0);
      expect(report.risk.level, 'none');
      expect(report.risk.factors, isEmpty);
    });
  });

  group('필터·미판정 집계', () {
    test('unverifiedReasonCounts는 사유 접두사를 사전순으로 센다', () {
      final report = _analyze([
        _fact(name: runtimeComputedName, literal: false),
        _fact(name: runtimeComputedName, literal: false, line: 2),
        _fact(
          name: 'API_TOKEN',
          line: 3,
          unverifiableReason: 'whole-environment-map: every key is read',
        ),
        _fact(
          kind: RuntimeFactKind.external,
          channel: RuntimeFactChannel.externalUrl,
          name: 'https://example.com',
          line: 4,
        ),
      ]);

      expect(report.unverifiedReasonCounts, {
        'computed-target': 2,
        'external-resource': 1,
        'whole-environment-map': 1,
      });
      expect(report.unverifiedReasonCounts.keys.toList(), [
        'computed-target',
        'external-resource',
        'whole-environment-map',
      ]);
    });

    test('집계는 필터·limit과 무관한 전체 미판정 집합 기준이다', () {
      final report = _analyze(
        [
          _fact(name: runtimeComputedName, literal: false),
          _fact(
            kind: RuntimeFactKind.external,
            channel: RuntimeFactChannel.externalUrl,
            name: 'https://example.com',
            line: 2,
          ),
        ],
        kinds: {RuntimeFactKind.env},
        statuses: {'missing'},
        limit: 1,
      );

      // 보고 목록은 비었지만 집계는 걸러지지 않은 미판정 둘을 센다.
      expect(report.unverified, isEmpty);
      expect(report.unverifiedReasonCounts, {
        'computed-target': 1,
        'external-resource': 1,
      });
    });

    test('검증을 끄면 미판정이 없어 집계는 비어 있다', () {
      final report = _analyze([_fact(name: 'TOKEN')], verify: false);

      expect(report.unverifiedReasonCounts, isEmpty);
    });

    test('접두사가 비는 사유는 unspecified로 묶이고 합계가 보존된다', () {
      final report = _analyze([
        _fact(name: 'A', unverifiableReason: ''),
        _fact(name: 'B', line: 2, unverifiableReason: ': orphan detail'),
        _fact(name: runtimeComputedName, literal: false, line: 3),
      ]);

      expect(report.unverifiedReasonCounts, {
        'computed-target': 1,
        'unspecified': 2,
      });
      expect(
        report.unverifiedReasonCounts.values.fold(0, (sum, n) => sum + n),
        report.unverified.length,
      );
    });

    test('필터 아래 limitations·위험도·집계는 전체 분석 기준으로 유지된다', () {
      final facts = [
        _fact(name: 'ENV_MISSING'),
        _fact(
          kind: RuntimeFactKind.config,
          channel: RuntimeFactChannel.filePath,
          name: 'config/x.yaml',
          path: 'config/x.yaml',
          line: 2,
        ),
        _fact(name: runtimeComputedName, literal: false, line: 3),
      ];
      final full = _analyze(facts);
      final filtered = _analyze(
        facts,
        kinds: {RuntimeFactKind.env},
        statuses: {'missing'},
        limit: 1,
      );

      expect(filtered.limitations, full.limitations);
      expect(filtered.risk.toJson(), full.risk.toJson());
      expect(filtered.unverifiedReasonCounts, full.unverifiedReasonCounts);
    });

    test('statuses 필터도 limit보다 먼저 적용된다', () {
      final report = _analyze(
        [
          _fact(name: 'A', line: 1),
          _fact(name: 'B', line: 2),
          _fact(name: runtimeComputedName, literal: false, line: 3),
        ],
        statuses: {'missing'},
        limit: 1,
      );

      expect(report.missing, hasLength(1));
      expect(report.unverified, isEmpty);
      expect(report.truncated.verified, 1);
      // 걸러진 미판정은 생략 수에도 들지 않는다.
      expect(report.truncated.unverified, 0);
    });

    test('kinds는 탐지 카테고리와 모든 판정 목록을 좁힌다', () {
      final report = _analyze(
        [
          _fact(name: 'ENV_MISSING'),
          _fact(
            kind: RuntimeFactKind.config,
            channel: RuntimeFactChannel.filePath,
            name: 'config/x.yaml',
            path: 'config/x.yaml',
            line: 2,
          ),
        ],
        kinds: {RuntimeFactKind.env},
      );

      expect(_kinds(report.detected), [RuntimeFactKind.env]);
      expect(report.detected.keys, RuntimeFactKind.values);
      expect(report.missing.map((item) => item.fact.name), ['ENV_MISSING']);
      // 필터는 보고 목록만 좁힌다 — 위험도는 걸러진 config 미충족까지 센다.
      expect(report.risk.score, 24);
      expect(report.risk.factors.single.name, 'missing-inputs');
    });

    test('statuses는 판정 절만 좁히고 탐지 목록은 유지한다', () {
      final report = _analyze(
        [
          _fact(name: 'ENV_SET'),
          _fact(name: 'ENV_MISSING', line: 2),
          _fact(name: runtimeComputedName, literal: false, line: 3),
        ],
        inputs: const RuntimeInputs(environment: {'ENV_SET': 'x'}),
        statuses: {'missing'},
      );

      expect(report.present, isEmpty);
      expect(report.defaulted, isEmpty);
      expect(report.missing.single.fact.name, 'ENV_MISSING');
      expect(report.unverified, isEmpty);
      expect(report.detected[RuntimeFactKind.env], hasLength(3));
      // 위험도·사유 집계는 필터 전 전체 집합 기준을 유지한다.
      expect(report.risk.factors.map((factor) => factor.name), [
        'missing-inputs',
        'unverified-facts',
      ]);
      expect(report.unverifiedReasonCounts, {'computed-target': 1});
    });

    test('필터는 limit보다 먼저 적용된다', () {
      final report = _analyze(
        [
          _fact(name: 'A', line: 1),
          _fact(name: 'B', line: 2),
          _fact(
            kind: RuntimeFactKind.config,
            channel: RuntimeFactChannel.filePath,
            name: 'config/x.yaml',
            path: 'config/x.yaml',
            line: 3,
          ),
        ],
        kinds: {RuntimeFactKind.env},
        limit: 1,
      );

      // 걸러진 config 사실은 생략 수에도 들지 않는다.
      expect(report.detected[RuntimeFactKind.config], isEmpty);
      expect(report.missing, hasLength(1));
      expect(report.truncated.detected, 1);
      expect(report.truncated.verified, 1);
      expect(report.truncated.unverified, 0);
    });
  });

  group('보고서 조립', () {
    test('detected는 다섯 카테고리 키를 항상 가진다', () {
      final report = _analyze([_fact(name: 'TOKEN')]);

      expect(_kinds(report.detected), [RuntimeFactKind.env]);
      expect(report.detected.keys, RuntimeFactKind.values);
    });

    test('--limit은 보고 항목만 줄이고 생략 수를 남긴다', () {
      final report = _analyze([
        _fact(name: 'A', line: 1),
        _fact(name: 'B', line: 2),
        _fact(name: runtimeComputedName, line: 3, literal: false),
        _fact(name: runtimeComputedName, line: 4, literal: false),
      ], limit: 1);

      expect(report.detected[RuntimeFactKind.env], hasLength(1));
      expect(report.missing, hasLength(1));
      expect(report.unverified, hasLength(1));
      expect(report.truncated.detected, 1 + 1 + 1);
      expect(report.truncated.verified, 1);
      expect(report.truncated.unverified, 1);
    });

    test('present·defaulted·missing은 위치 순으로 정렬한다', () {
      final report = _analyze([
        _fact(name: 'LATE', line: 9),
        _fact(name: 'EARLY', line: 2),
      ], inputs: const RuntimeInputs(environment: {'LATE': 'x', 'EARLY': 'y'}));

      expect(report.present.map((item) => item.fact.line), [2, 9]);
    });

    test('--no-verify는 판정 없이 탐지 사실만 남긴다', () {
      final report = _analyze([_fact(name: 'TOKEN')], verify: false);

      expect(report.verified, isFalse);
      expect(report.present, isEmpty);
      expect(report.defaulted, isEmpty);
      expect(report.missing, isEmpty);
      expect(report.unverified, isEmpty);
      expect(report.risk.score, 0);
      expect(report.detected[RuntimeFactKind.env], hasLength(1));
      expect(report.limitations, contains(startsWith('verification-disabled')));
    });

    test('한계에 입력 출처와 실행 위험을 밝힌다', () {
      final process = _analyze(const []);
      expect(
        process.limitations,
        contains(
          startsWith('environment-source: verification used the caller'),
        ),
      );

      final hermetic = _analyze(
        const [],
        inputs: const RuntimeInputs(environmentFromProcess: false),
      );
      expect(
        hermetic.limitations,
        contains(startsWith('environment-source: verification used only')),
      );

      final executed = _analyze(
        const [],
        execution: const RuntimeExecution(
          entrypoint: 'bin/probe.dart',
          exitCode: 0,
          timedOut: false,
          stderrSummary: '',
        ),
      );
      expect(executed.limitations, contains(startsWith('execute-runs-code')));
      // 한계 목록은 중복 없이 정렬한다(실행 시에도 결정적이다).
      expect(executed.limitations.toSet().length, executed.limitations.length);
      final sorted = [...executed.limitations]..sort();
      expect(executed.limitations, sorted);

      // 타임아웃으로 죽인 실행은 직계 PID만 대상이라 후손 생존 가능성을 남긴다.
      final timedOut = _analyze(
        const [],
        execution: const RuntimeExecution(
          entrypoint: 'bin/probe.dart',
          exitCode: -1,
          timedOut: true,
          stderrSummary: '',
        ),
      );
      expect(
        timedOut.limitations,
        contains(startsWith('execute-process-scope')),
      );
      expect(
        executed.limitations,
        isNot(contains(startsWith('execute-process-scope'))),
      );

      // 실행 파일을 못 찾아 아무것도 실행하지 않은 경우는 "실행 실패"가 아니다.
      final unresolved = _analyze(
        const [],
        execution: const RuntimeExecution.unresolved(
          entrypoint: 'bin/probe.dart',
          reason: 'dart-executable-not-found: no dart executable',
        ),
      );
      expect(
        unresolved.limitations,
        contains(startsWith('execute-unresolved')),
      );
      expect(
        unresolved.limitations,
        isNot(contains(startsWith('execute-runs-code'))),
      );
      expect(unresolved.risk.factors, isEmpty);
      expect(unresolved.execution!.unresolvedReason, isNotEmpty);
    });
  });
}
