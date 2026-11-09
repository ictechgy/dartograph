import 'dart:io';

import 'package:dartograph/src/index/dart_sdk_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 인덱서가 analyzer에 넘길 SDK 디렉터리 탐색의 회귀 테스트다(#160).
///
/// 실제 파일 시스템에 SDK 표지 파일만 둔 가짜 레이아웃을 만들고 실행 파일 위치·
/// 환경변수를 주입한다. 기대 경로는 픽스처에서 손으로 정한 값이다. AOT 바이너리는
/// SDK 밖(`<tmp>/install/bin/dartograph`)에 둔다 — 그 두 단계 위는 SDK가 아니다.
void main() {
  late Directory workspace;

  setUp(() async {
    final created = await Directory.systemTemp.createTemp('dartograph-sdk.');
    workspace = Directory(created.resolveSymbolicLinksSync());
  });
  tearDown(() => workspace.delete(recursive: true));

  /// [relative] 경로에 빈 파일을 만들고 절대 경로를 돌려준다.
  String touch(String relative) {
    final file = File(p.join(workspace.path, relative))
      ..createSync(recursive: true);
    return file.path;
  }

  /// [relative] 디렉터리를 SDK 레이아웃(표지 파일 + `bin/dart`)으로 만든다.
  String sdkAt(String relative) {
    touch(
      p.join(
        relative,
        'lib',
        '_internal',
        'sdk_library_metadata',
        'lib',
        'libraries.dart',
      ),
    );
    touch(p.join(relative, 'bin', 'dart'));
    return p.join(workspace.path, relative);
  }

  /// SDK 밖에 둔 AOT 바이너리 경로다.
  String aotBinary() => touch(p.join('install', 'bin', 'dartograph'));

  /// [environment]만 보는 탐색이다(실제 호스트 환경을 섞지 않는다).
  String? locate(
    Map<String, String> environment, {
    String? executable,
    bool windows = false,
  }) => locateDartSdk(
    resolvedExecutable: executable ?? aotBinary(),
    environment: environment,
    windows: windows,
  );

  test('the running VM inside an SDK is used first', () {
    final sdk = sdkAt('vm-sdk');
    final other = sdkAt('other-sdk');

    expect(
      locate({'DART_SDK': other}, executable: p.join(sdk, 'bin', 'dart')),
      sdk,
    );
  });

  test('an AOT binary finds the SDK of a real dart on PATH', () {
    final sdk = sdkAt('dart-sdk');

    expect(locate({'PATH': p.join(sdk, 'bin')}), sdk);
  });

  test('a symlinked dart on PATH resolves to its SDK', () {
    final sdk = sdkAt('dart-sdk');
    final shims = p.join(workspace.path, 'shims');
    Directory(shims).createSync();
    Link(p.join(shims, 'dart')).createSync(p.join(sdk, 'bin', 'dart'));

    expect(locate({'PATH': shims}), sdk);
  });

  test('a Flutter bin/dart wrapper on PATH finds bin/cache/dart-sdk', () {
    // Flutter의 bin/dart는 셸 래퍼다. 두 단계 위(Flutter 루트)는 SDK가 아니다.
    touch(p.join('flutter', 'bin', 'dart'));
    final sdk = sdkAt(p.join('flutter', 'bin', 'cache', 'dart-sdk'));

    expect(locate({'PATH': p.join(workspace.path, 'flutter', 'bin')}), sdk);
  });

  test('a symlink to the Flutter wrapper also finds the Flutter SDK', () {
    touch(p.join('flutter', 'bin', 'dart'));
    final sdk = sdkAt(p.join('flutter', 'bin', 'cache', 'dart-sdk'));
    final shims = p.join(workspace.path, 'shims');
    Directory(shims).createSync();
    Link(
      p.join(shims, 'dart'),
    ).createSync(p.join(workspace.path, 'flutter', 'bin', 'dart'));

    expect(locate({'PATH': shims}), sdk);
  });

  test('Windows Flutter dart.bat on PATH finds the Flutter SDK', () {
    touch(p.join('flutter', 'bin', 'dart.bat'));
    final sdk = sdkAt(p.join('flutter', 'bin', 'cache', 'dart-sdk'));

    expect(
      locate({
        'PATH': 'C:/missing;${p.join(workspace.path, 'flutter', 'bin')}',
      }, windows: true),
      sdk,
    );
  });

  test('DART_SDK is used before PATH', () {
    final fromVariable = sdkAt('variable-sdk');
    final onPath = sdkAt('path-sdk');

    expect(
      locate({'DART_SDK': fromVariable, 'PATH': p.join(onPath, 'bin')}),
      fromVariable,
    );
  });

  test('FLUTTER_ROOT finds bin/cache/dart-sdk', () {
    final sdk = sdkAt(p.join('flutter', 'bin', 'cache', 'dart-sdk'));

    expect(locate({'FLUTTER_ROOT': p.join(workspace.path, 'flutter')}), sdk);
  });

  test('an invalid DART_SDK falls through to PATH', () {
    final onPath = sdkAt('path-sdk');

    expect(
      locate({
        'DART_SDK': p.join(workspace.path, 'not-an-sdk'),
        'PATH': p.join(onPath, 'bin'),
      }),
      onPath,
    );
  });

  test('PATH order decides between two SDKs', () {
    final first = sdkAt('first-sdk');
    final second = sdkAt('second-sdk');

    expect(
      locate({'PATH': '${p.join(first, 'bin')}:${p.join(second, 'bin')}'}),
      first,
    );
  });

  test('an SDK beside the executable is still found when nothing else is', () {
    // 0.17.0은 탐색 실패 뒤 analyzer 기본값이 이 배치를 찾았다. 회귀하지 않는다.
    final binary = aotBinary();
    final sdk = sdkAt(p.join('install', 'bin', 'dart-sdk'));

    expect(locate({'PATH': ''}, executable: binary), sdk);
  });

  test('PATH is used before an SDK beside the executable', () {
    final binary = aotBinary();
    sdkAt(p.join('install', 'bin', 'dart-sdk'));
    final onPath = sdkAt('path-sdk');

    expect(locate({'PATH': p.join(onPath, 'bin')}, executable: binary), onPath);
  });

  test(
    'a project directory cannot plant an SDK through cwd-relative paths',
    () {
      // analyzer 기본값은 작업 디렉터리의 third_party/dart_lang/v2/sdk도 봤다.
      sdkAt(p.join('third_party', 'dart_lang', 'v2', 'sdk'));
      final previous = Directory.current;
      Directory.current = workspace;
      addTearDown(() => Directory.current = previous);

      expect(locate({'PATH': ''}), isNull);
    },
  );

  test('no SDK anywhere is null rather than a guessed directory', () {
    touch(p.join('tools', 'dart'));

    expect(
      locate({
        'PATH': '${p.join(workspace.path, 'tools')}::',
        'DART_SDK': '',
        'FLUTTER_ROOT': '',
      }),
      isNull,
    );
  });
}
