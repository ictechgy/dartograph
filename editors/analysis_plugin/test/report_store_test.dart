import 'dart:convert';
import 'dart:io';

import 'package:dartograph_analysis_plugin/src/report_store.dart';
import 'package:test/test.dart';

void main() {
  group('stripScheme', () {
    test('project: 접두를 벗기고 다른 스킴은 null이다', () {
      expect(stripScheme('project:lib/a.dart'), 'lib/a.dart');
      expect(stripScheme('lib/a.dart'), 'lib/a.dart');
      expect(stripScheme('package:dep/x.dart'), isNull);
      expect(stripScheme(''), isNull);
      expect(stripScheme(null), isNull);
    });
  });

  group('safeRelative', () {
    test('루트 밖 경로를 배제한다', () {
      expect(safeRelative('lib/a.dart'), 'lib/a.dart');
      expect(safeRelative('../x.dart'), isNull);
      expect(safeRelative('a/../b.dart'), isNull);
      expect(safeRelative('/abs/x.dart'), isNull);
      expect(safeRelative('C:/x.dart'), isNull);
    });
  });

  group('parseDead', () {
    test('source·line·column을 발견 위치로 변환한다', () {
      final document =
          jsonDecode('''
        {"findings":[
          {"kind":"declaration","source":"project:lib/unused.dart",
           "line":4,"column":7,"reason":"unreachable from all retention roots"},
          {"kind":"file","source":"project:lib/orphan.dart",
           "reason":"no reachable declaration or reachable library import"},
          {"kind":"declaration","source":"package:dep/x.dart","reason":"skip"},
          {"kind":"file","source":"project:../outside.dart","reason":"skip"}
        ],"report":"dead"}
      ''')
              as Map<String, Object?>;
      final byFile = parseDead(document);
      expect(byFile.keys, containsAll(['lib/unused.dart', 'lib/orphan.dart']));
      expect(byFile['lib/unused.dart']!.single.line, 4);
      expect(byFile['lib/unused.dart']!.single.column, 7);
      expect(
        byFile['lib/unused.dart']!.single.message,
        contains('unreachable from all retention roots'),
      );
      // 파일 수준 발견은 행·열이 없으므로 1행 1열로 둔다.
      expect(byFile['lib/orphan.dart']!.single.line, 1);
    });

    test('모양이 어긋난 필드는 던지지 않고 건너뛴다', () {
      final byFile = parseDead({
        'findings': {'not': 'a list'},
      });
      expect(byFile, isEmpty);
      final malformed = parseDead({
        'findings': [
          {'kind': 'declaration', 'source': 42, 'line': 'x'},
          {'kind': 'declaration', 'source': 'project:lib/a.dart', 'line': 2.5},
        ],
      });
      expect(malformed['lib/a.dart']!.single.line, 1);
    });
  });

  group('parseDup', () {
    test('양 인스턴스를 발견으로 변환하고 상대 위치를 메시지에 넣는다', () {
      final document =
          jsonDecode('''
        {"findings":[{"tokenCount":80,"instances":[
          {"source":"project:lib/a.dart","startLine":3,"endLine":20},
          {"source":"project:lib/b.dart","startLine":8,"endLine":25}
        ]}],"report":"dup"}
      ''')
              as Map<String, Object?>;
      final byFile = parseDup(document);
      expect(byFile['lib/a.dart']!.single.endLine, 20);
      expect(byFile['lib/a.dart']!.single.message, contains('lib/b.dart:8'));
      expect(byFile['lib/b.dart']!.single.message, contains('lib/a.dart:3'));
      expect(byFile['lib/a.dart']!.single.message, contains('80 tokens'));
    });

    test('패키지 밖 인스턴스는 발견을 만들지 않지만 위치는 메시지에 남는다', () {
      final document =
          jsonDecode('''
        {"findings":[{"tokenCount":50,"instances":[
          {"source":"project:lib/a.dart","startLine":1,"endLine":5},
          {"source":"package:dep/x.dart","startLine":1,"endLine":5}
        ]}],"report":"dup"}
      ''')
              as Map<String, Object?>;
      final byFile = parseDup(document);
      expect(byFile.keys, ['lib/a.dart']);
      expect(byFile['lib/a.dart']!.single.message, contains('package:dep'));
    });

    test('1 미만 시작과 뒤집힌 범위를 정규화한다', () {
      final byFile = parseDup({
        'findings': [
          {
            'tokenCount': 40,
            'instances': [
              {'source': 'project:lib/a.dart', 'startLine': 0, 'endLine': 0},
            ],
          },
        ],
      });
      expect(byFile['lib/a.dart']!.single.line, 1);
      expect(byFile['lib/a.dart']!.single.endLine, 1);
      final reversed = parseDup({
        'findings': [
          {
            'tokenCount': 40,
            'instances': [
              {'source': 'project:lib/a.dart', 'startLine': 9, 'endLine': 3},
            ],
          },
        ],
      });
      expect(reversed['lib/a.dart']!.single.endLine, 9);
    });
  });

  group('ReportCache', () {
    test('CLI 실행은 증분 캐시를 패키지 밖 사용자 캐시에 둔다', () async {
      final dir = await Directory.systemTemp.createTemp('dgplug_args_');
      final record = File('${dir.path}/argv');
      // 받은 인자를 한 줄로 남기고 빈 보고서로 성공하는 가짜 CLI다.
      final script = File('${dir.path}/record.sh')
        ..writeAsStringSync(
          '#!/bin/sh\nprintf \'%s\\n\' "\$*" >> "${record.path}"\n'
          'printf \'{"findings":[],"report":"dead"}\'\n',
        );
      await Process.run('chmod', ['+x', script.path]);
      ReportCache.clear();
      ReportCache.debugExecutable = script.path;
      try {
        expect(ReportCache.reportFor(dir.path), isNotNull);
        // 패키지 안 `.dartograph/cache`를 넘기면 저장소가 심어 둔 캐시를 믿는다.
        expect(record.readAsLinesSync(), [
          'dead --format json --incremental-user-cache ${dir.path}',
          'dup --format json --incremental-user-cache ${dir.path}',
        ]);
      } finally {
        ReportCache.clear();
        await dir.delete(recursive: true);
      }
    });

    test('실행 실패를 캐시해 파일마다 재실행하지 않는다', () async {
      final dir = await Directory.systemTemp.createTemp('dgplug_cache_');
      final counter = File('${dir.path}/count');
      final script = File('${dir.path}/fail.sh')
        ..writeAsStringSync('#!/bin/sh\necho x >> "${counter.path}"\nexit 2\n');
      await Process.run('chmod', ['+x', script.path]);
      ReportCache.clear();
      ReportCache.debugExecutable = script.path;
      try {
        // dead·dup 각 1회씩 — 두 번째 조회는 TTL 안이라 재실행하지 않는다.
        expect(ReportCache.reportFor(dir.path), isNull);
        expect(ReportCache.reportFor(dir.path), isNull);
        expect(counter.readAsStringSync().trim().split('\n').length, 2);
      } finally {
        ReportCache.clear();
        await dir.delete(recursive: true);
      }
    });
  });

  group('ReportCache 갱신', () {
    late Directory base;
    late File log;

    setUp(() async {
      ReportCache.clear();
      base = await Directory.systemTemp.createTemp('dgplug_refresh_');
      log = File('${base.path}/log');
    });

    tearDown(() async {
      await ReportCache.debugWaitForRefreshes();
      ReportCache.clear();
      await base.delete(recursive: true);
    });

    test('간격이 지나도 디스크가 그대로면 CLI를 다시 실행하지 않는다', () async {
      final root = _createPackage(base, 'pkg');
      // 링크는 따라가지 않는다 — 순환은 경로를 끝없이 늘리고, 단계마다 다음 단계를
      // 두 번 가리키는 공유 링크 트리는 깊이 20에서 경로가 2^20개가 된다.
      Link('${root.path}/lib/loop').createSync(root.path);
      for (var depth = 0; depth < 20; depth++) {
        Directory('${root.path}/lib/d$depth').createSync();
        for (final name in ['a', 'b']) {
          Link('${root.path}/lib/d$depth/$name').createSync('../d${depth + 1}');
        }
      }
      Directory('${root.path}/lib/d20').createSync();
      ReportCache.debugExecutable = await _writeCommandLogger(base, log);
      var now = DateTime.utc(2026);
      ReportCache.debugNow = () => now;
      expect(ReportCache.reportFor(root.path), isNotNull);
      for (var check = 0; check < 3; check++) {
        now = now.add(const Duration(minutes: 5));
        expect(ReportCache.reportFor(root.path), isNotNull);
        await ReportCache.debugWaitForRefreshes();
      }
      // 첫 적재의 두 번뿐이다 — 수정 전에는 확인마다 dead·dup을 다시 실행했다.
      expect(_lines(log), ['dead', 'dup']);
    });

    test('Dart 소스와 설정 파일의 크기·수정 시각·목록이 바뀔 때만 다시 실행한다', () async {
      final root = _createPackage(base, 'pkg');
      ReportCache.debugExecutable = await _writeCommandLogger(base, log);
      var now = DateTime.utc(2026);
      ReportCache.debugNow = () => now;
      ReportCache.reportFor(root.path);
      // [change]를 적용하고 [elapsed] 뒤 갱신을 확인해 새로 실행한 CLI 수를 센다.
      Future<int> runsAfter(
        void Function() change, {
        Duration elapsed = const Duration(minutes: 5),
      }) async {
        final before = _lines(log).length;
        change();
        now = now.add(elapsed);
        ReportCache.reportFor(root.path);
        await ReportCache.debugWaitForRefreshes();
        return _lines(log).length - before;
      }

      final source = File('${root.path}/lib/a.dart');
      void write(String relative) => File('${root.path}/$relative')
        ..createSync(recursive: true)
        ..writeAsStringSync('// $relative\n');
      final stamp = DateTime.utc(2001);

      // 간격(최소 30초) 안에서는 바뀐 파일도 다시 실행하지 않는다.
      expect(
        await runsAfter(
          () => source.writeAsStringSync('void a() { }\n'),
          elapsed: const Duration(seconds: 29),
        ),
        0,
      );
      expect(await runsAfter(() {}, elapsed: const Duration(seconds: 2)), 2);
      // 분석 입력이 아닌 위치·이름의 변경은 신호가 아니다.
      expect(
        await runsAfter(() {
          write('.dart_tool/gen.dart');
          write('build/out.dart');
          write('.idea/x.dart');
          write('lib/notes.md');
        }),
        0,
      );
      // 변경 없음을 확인한 때부터 간격을 다시 센다. 크기는 같고 수정 시각만
      // 바뀐 변경을 그다음 확인이 잡는다.
      expect(
        await runsAfter(
          () => source.setLastModifiedSync(stamp),
          elapsed: const Duration(seconds: 29),
        ),
        0,
      );
      expect(await runsAfter(() {}, elapsed: const Duration(seconds: 2)), 2);
      // 수정 시각은 그대로 두고 크기만 바뀐다.
      expect(
        await runsAfter(() {
          source.writeAsStringSync('void a() {  }\n');
          source.setLastModifiedSync(stamp);
        }),
        2,
      );
      expect(await runsAfter(() => write('lib/b.dart')), 2);
      // 이름 바꾸기는 크기와 수정 시각을 그대로 둔다.
      expect(
        await runsAfter(
          () => File(
            '${root.path}/lib/b.dart',
          ).renameSync('${root.path}/lib/c.dart'),
        ),
        2,
      );
      expect(
        await runsAfter(() => File('${root.path}/lib/c.dart').deleteSync()),
        2,
      );
      // 링크는 따라가지 않지만 생기거나 사라지면 분석 대상이 바뀐다.
      expect(
        await runsAfter(
          () => Link('${root.path}/lib/shared').createSync(base.path),
        ),
        2,
      );
      for (final config in [
        'pubspec.yaml',
        'analysis_options.yaml',
        'dartograph.yaml',
        'build.yaml',
      ]) {
        expect(await runsAfter(() => write(config)), 2, reason: config);
      }
      // `pub get`이 쓰는 패키지 설정은 `.dart_tool` 안이지만 신호다. 루트에 없으면
      // 가장 가까운 조상의 설정을 본다(pub 워크스페이스 멤버).
      final ancestorConfig = File(
        '${base.path}/.dart_tool/package_config.json',
      );
      expect(
        await runsAfter(
          () => ancestorConfig
            ..createSync(recursive: true)
            ..writeAsStringSync('{}'),
        ),
        2,
      );
      expect(await runsAfter(() => write('.dart_tool/package_config.json')), 2);
      expect(await runsAfter(() => ancestorConfig.writeAsStringSync('{ }')), 0);
    });

    test('CLI가 도는 동안 저장한 변경은 다음 확인에서 다시 실행한다', () async {
      final root = _createPackage(base, 'pkg');
      final source = File('${root.path}/lib/a.dart');
      // 첫 적재와 첫 갱신의 dead 실행이 소스를 저장한다 — CLI가 읽는 도중의
      // 저장을 흉내 낸다. 신호는 CLI보다 먼저 재야 이 저장을 놓치지 않는다.
      ReportCache.debugExecutable = await _writeScript(base, '''
printf '%s\\n' "\$1" >> "${log.path}"
if [ "\$1" = dead ]; then
  runs=\$(grep -c dead "${log.path}")
  if [ "\$runs" -le 2 ]; then
    printf 'void a() { /* %s */ }\\n' "\$runs" > "${source.path}"
  fi
fi
printf '{"findings":[]}'
''');
      var now = DateTime.utc(2026);
      ReportCache.debugNow = () => now;
      ReportCache.reportFor(root.path);
      final counts = <int>[];
      for (var check = 0; check < 3; check++) {
        now = now.add(const Duration(seconds: 31));
        ReportCache.reportFor(root.path);
        await ReportCache.debugWaitForRefreshes();
        counts.add(_lines(log).length);
      }
      expect(counts, [4, 6, 6]);
    });

    test('갱신은 두 루트까지만 함께 돌고, 한 루트의 dead와 dup은 함께 실행한다', () async {
      final roots = [
        for (var index = 0; index < 5; index++)
          _createPackage(base, 'pkg$index'),
      ];
      final gate = File('${base.path}/gate');
      final release = File('${base.path}/release');
      // 실행의 시작과 끝을 남긴다. gate가 있으면 release가 생길 때까지 끝나지 않는다.
      ReportCache.debugExecutable = await _writeScript(base, '''
printf 'start %s %s\\n' "\$1" "\$5" >> "${log.path}"
if [ -e "${gate.path}" ]; then
  while [ ! -e "${release.path}" ]; do sleep 0.02; done
fi
printf 'end %s %s\\n' "\$1" "\$5" >> "${log.path}"
printf '{"findings":[]}'
''');
      var now = DateTime.utc(2026);
      ReportCache.debugNow = () => now;
      for (final root in roots) {
        ReportCache.reportFor(root.path);
      }
      gate.writeAsStringSync('');
      // 모든 루트를 바꿔 갱신을 넣고, 두 루트의 네 프로세스만 문 앞에서 기다리는지
      // 본 뒤 문을 연다. 두 번 돌려 첫 물결 뒤에도 자리 수가 맞는지 확인한다.
      for (var wave = 1; wave <= 2; wave++) {
        log.writeAsStringSync('');
        if (release.existsSync()) release.deleteSync();
        now = now.add(const Duration(minutes: 5));
        try {
          for (final root in roots) {
            File(
              '${root.path}/lib/a.dart',
            ).writeAsStringSync('void a() {} // wave $wave\n');
            ReportCache.reportFor(root.path);
          }
          await _waitUntil(() => _lines(log).length >= 4);
          // 늦게 시작하는 실행이 없는지 잠시 더 본다 — 자리는 앞의 두 갱신이 쥐고 있다.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final started = _lines(log);
          expect(started, hasLength(4), reason: 'wave $wave');
          final commandsByRoot = <String, List<String>>{};
          for (final line in started) {
            final [_, command, ...root] = line.split(' ');
            commandsByRoot.putIfAbsent(root.join(' '), () => []).add(command);
          }
          expect(commandsByRoot, hasLength(2), reason: 'wave $wave');
          for (final commands in commandsByRoot.values) {
            expect(commands, unorderedEquals(['dead', 'dup']));
          }
          // 대기 중이거나 실행 중인 루트는 다시 넣지 않는다.
          for (final root in roots) {
            ReportCache.reportFor(root.path);
          }
        } finally {
          release.writeAsStringSync('');
        }
        await ReportCache.debugWaitForRefreshes();
        final lines = _lines(log);
        expect(
          lines.where((line) => line.startsWith('start ')),
          hasLength(10),
          reason: 'wave $wave',
        );
        expect(_maxConcurrentRoots(lines), 2, reason: 'wave $wave');
      }
    });

    test('갱신 간격은 직전 실행 시간의 10배로 늘고 30분을 넘지 않는다', () async {
      final root = _createPackage(base, 'pkg');
      final clock = File('${base.path}/clock')..writeAsStringSync('0');
      final step = File('${base.path}/step')..writeAsStringSync('4');
      // 실행마다 가짜 시계를 step초 앞으로 돌린다 — 그만큼 걸린 실행처럼 보인다.
      ReportCache.debugExecutable = await _writeScript(base, '''
printf '%s\\n' "\$1" >> "${log.path}"
echo \$(( \$(cat "${clock.path}") + \$(cat "${step.path}") )) > "${clock.path}.\$\$"
mv "${clock.path}.\$\$" "${clock.path}"
printf '{"findings":[]}'
''');
      int seconds() => int.parse(clock.readAsStringSync().trim());
      ReportCache.debugNow = () =>
          DateTime.utc(2026).add(Duration(seconds: seconds()));
      // 시계를 [at]초로 옮겨 갱신을 확인하고 새로 실행한 CLI 수를 센다.
      Future<int> runsAt(int at) async {
        final before = _lines(log).length;
        clock.writeAsStringSync('$at');
        ReportCache.reportFor(root.path);
        await ReportCache.debugWaitForRefreshes();
        return _lines(log).length - before;
      }

      final source = File('${root.path}/lib/a.dart');
      // 첫 적재는 dead와 dup을 차례로 실행한다: 4초 + 4초 → 간격 80초.
      ReportCache.reportFor(root.path);
      final loaded = seconds();
      expect(loaded, 8);
      source.writeAsStringSync('void a() { }\n');
      expect(await runsAt(loaded + 79), 0);
      step.writeAsStringSync('3600');
      expect(await runsAt(loaded + 81), 2);
      // 이번 실행은 한 시간 넘게 걸렸지만 간격은 30분에서 멈춘다.
      final refreshed = seconds();
      source.writeAsStringSync('void a() {  }\n');
      expect(await runsAt(refreshed + 29 * 60), 0);
      expect(await runsAt(refreshed + 31 * 60), 2);
    });

    test('두 명령이 모두 실패하면 디스크가 그대로여도 간격 뒤 다시 실행한다', () async {
      final root = _createPackage(base, 'pkg');
      ReportCache.debugExecutable = await _writeScript(
        base,
        'printf \'%s\\n\' "\$1" >> "${log.path}"\nexit 2\n',
      );
      var now = DateTime.utc(2026);
      ReportCache.debugNow = () => now;
      expect(ReportCache.reportFor(root.path), isNull);
      now = now.add(const Duration(seconds: 31));
      expect(ReportCache.reportFor(root.path), isNull);
      await ReportCache.debugWaitForRefreshes();
      // 실패 원인(CLI 설치·버전 등)은 패키지 디스크 밖에 있을 수 있다.
      expect(_lines(log), hasLength(4));
    });

    test('한쪽 명령만 실패하면 성공한 쪽을 서빙하고 간격 뒤 다시 시도한다', () async {
      final root = _createPackage(base, 'pkg');
      // dup은 늘 실패하고, dead는 자기 실행 횟수를 발견의 행으로 낸다.
      ReportCache.debugExecutable = await _writeScript(base, '''
printf '%s\\n' "\$1" >> "${log.path}"
if [ "\$1" = dup ]; then exit 2; fi
line=\$(grep -c dead "${log.path}")
printf '{"findings":[{"kind":"declaration","source":"project:lib/a.dart","line":%s,"column":1,"reason":"r"}]}' "\$line"
''');
      var now = DateTime.utc(2026);
      ReportCache.debugNow = () => now;
      final first = ReportCache.reportFor(root.path)!;
      expect(first.dead['lib/a.dart']!.single.line, 1);
      expect(first.dup, isEmpty);
      now = now.add(const Duration(seconds: 31));
      ReportCache.reportFor(root.path);
      await ReportCache.debugWaitForRefreshes();
      final second = ReportCache.reportFor(root.path)!;
      expect(second.dead['lib/a.dart']!.single.line, 2);
      expect(second.dup, isEmpty);
    });
  });
}

/// [body]를 본문으로 하는 실행 가능한 sh 스크립트를 [directory]에 만든다.
Future<String> _writeScript(Directory directory, String body) async {
  final script = File('${directory.path}/cli.sh')
    ..writeAsStringSync('#!/bin/sh\n$body');
  final chmod = await Process.run('chmod', ['+x', script.path]);
  expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
  return script.path;
}

/// 받은 명령(dead·dup)을 [log]에 한 줄씩 남기고 빈 보고서로 성공하는 가짜 CLI다.
Future<String> _writeCommandLogger(Directory directory, File log) =>
    _writeScript(
      directory,
      'printf \'%s\\n\' "\$1" >> "${log.path}"\n'
      'printf \'{"findings":[]}\'\n',
    );

/// `pubspec.yaml`과 `lib/a.dart`가 있는 패키지 루트를 [parent] 아래에 만든다.
Directory _createPackage(Directory parent, String name) {
  final root = Directory('${parent.path}/$name')..createSync();
  File('${root.path}/pubspec.yaml').writeAsStringSync('name: $name\n');
  File('${root.path}/lib/a.dart')
    ..createSync(recursive: true)
    ..writeAsStringSync('void a() {}\n');
  return root;
}

/// 가짜 CLI가 [log]에 남긴 줄이다. 아직 실행하지 않았으면 비어 있다.
List<String> _lines(File log) =>
    log.existsSync() ? log.readAsLinesSync() : const [];

/// [condition]이 참이 될 때까지 기다린다. [timeout] 안에 참이 되지 않으면 실패한다.
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// `start <명령> <루트>`·`end <명령> <루트>` 기록에서 CLI가 동시에 돈 루트 수의
/// 최댓값을 센다.
int _maxConcurrentRoots(List<String> lines) {
  final running = <String, int>{};
  var maximum = 0;
  for (final line in lines) {
    final [event, _, ...rootParts] = line.split(' ');
    final root = rootParts.join(' ');
    running[root] = (running[root] ?? 0) + (event == 'start' ? 1 : -1);
    final active = running.values.where((count) => count > 0).length;
    if (active > maximum) maximum = active;
  }
  return maximum;
}
