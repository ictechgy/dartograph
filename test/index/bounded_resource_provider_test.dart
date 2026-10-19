import 'dart:io' as io;

import 'package:analyzer/file_system/file_system.dart';
import 'package:dartograph/src/core/config_source.dart';
import 'package:dartograph/src/index/bounded_resource_provider.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/read_boundary_support.dart';

/// analyzer 읽기 경계가 내용 읽기만 막고 나머지 파일 시스템 동작은 실제
/// 구현과 같게 두는지 검증한다.
void main() {
  late io.Directory workspace;

  setUp(() async {
    workspace = await io.Directory.systemTemp.createTemp('bounded-provider.');
    workspace = io.Directory(workspace.resolveSymbolicLinksSync());
  });
  tearDown(() => workspace.delete(recursive: true));

  String write(String relative, String content) {
    final file = io.File(p.join(workspace.path, relative))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    return file.path;
  }

  test('정규 파일은 실제 구현과 같은 내용을 읽고 거부를 남기지 않는다', () {
    final provider = BoundedResourceProvider();
    final path = write('lib/a.dart', 'class A {}\n');
    final empty = write('lib/empty.dart', '');

    expect(provider.getFile(path).readAsStringSync(), 'class A {}\n');
    expect(provider.getFile(path).readAsBytesSync(), 'class A {}\n'.codeUnits);
    expect(provider.getFile(empty).readAsStringSync(), isEmpty);
    expect(provider.getFile(empty).readAsBytesSync(), isEmpty);
    provider.throwIfRejected();
  });

  test('부재·디렉터리·디코드 실패는 원래 실패이고 거부가 아니다', () {
    final provider = BoundedResourceProvider();
    final missing = p.join(workspace.path, 'missing.dart');
    final directory = p.join(workspace.path, 'lib');
    io.Directory(directory).createSync();
    final undecodable = p.join(workspace.path, 'bad.dart');
    io.File(undecodable).writeAsBytesSync(const [0xff, 0xfe, 0x00]);

    expect(
      () => provider.getFile(missing).readAsStringSync(),
      throwsA(isA<PathNotFoundException>()),
    );
    expect(
      () => provider.getFile(directory).readAsBytesSync(),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      () => provider.getFile(undecodable).readAsStringSync(),
      throwsA(isA<FileSystemException>()),
    );
    // 분석 입력 자체의 문제가 아니므로 analyzer의 기존 수습(없는 파일)에 맡긴다.
    provider.throwIfRejected();
  });

  test(
    '장치·FIFO는 열지 않고 analyzer 실패와 기록된 거부가 된다',
    () async {
      final provider = BoundedResourceProvider();
      final device = p.join(workspace.path, 'device.dart');
      await io.Link(device).create('/dev/null');
      final fifo = await fifoWithRepeatingWriter(
        p.join(workspace.path, 'pipe.dart'),
      );

      // /dev/null은 즉시 EOF라 열어도 멈추지 않는다. 열기 전에 거부해야만
      // 실패가 난다. FIFO는 쓰는 쪽이 붙어 있어, 열었다면 1초 뒤 빈 내용을
      // 읽고 실패 없이 끝났을 것이다.
      for (final path in [device, fifo]) {
        expect(
          () => provider.getFile(path).readAsBytesSync(),
          throwsA(isA<FileSystemException>()),
          reason: path,
        );
        expect(
          () => provider.getFile(path).readAsStringSync(),
          throwsA(isA<FileSystemException>()),
          reason: path,
        );
      }
      expect(
        provider.throwIfRejected,
        throwsA(
          isA<NonRegularFileException>().having(
            (rejection) => rejection.message,
            'message',
            isNot(contains(workspace.path)),
          ),
        ),
      );
    },
    skip: io.Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('상한을 넘는 정규 파일은 읽지 않고 상한 초과 거부가 된다', () {
    final provider = BoundedResourceProvider(readLimit: 4);
    final small = write('small.dart', 'abcd');
    final large = write('large.dart', 'abcde');

    expect(provider.getFile(small).readAsStringSync(), 'abcd');
    provider.throwIfRejected();
    expect(
      () => provider.getFile(large).readAsBytesSync(),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      provider.throwIfRejected,
      throwsA(
        isA<InputTooLargeException>().having(
          (rejection) => rejection.message,
          'message',
          'analysis input exceeds the 4-byte read limit',
        ),
      ),
    );
    expect(
      analysisInputTooLarge().message,
      'analysis input exceeds the 64 MiB read limit',
    );
  });

  test('나눠 읽기는 상한을 넘는 순간 멈추고 상한 초과 거부가 된다', () {
    // 길이를 0으로 보고하는 가상 파일 전용 경로지만, 판정은 실제로 읽은 양으로
    // 한다. 그래서 내용이 있는 정규 파일로도 같은 경계를 확인할 수 있다.
    final path = write('chunks.dart', 'abcdefgh');

    expect(readUnknownLengthSync(io.File(path), 8), 'abcdefgh'.codeUnits);
    expect(
      () => readUnknownLengthSync(io.File(path), 4),
      throwsA(
        isA<InputTooLargeException>().having(
          (rejection) => rejection.message,
          'message',
          'analysis input exceeds the 4-byte read limit',
        ),
      ),
    );
  });

  test('analyzer 밖의 직접 읽기도 같은 경계를 지나고 '
      '나머지 실패는 dart:io와 같다', () async {
    final source = write('lib/a.dart', 'class A {}\n');
    expect(readAnalysisInputSync(io.File(source)), 'class A {}\n');
    expect(
      readAnalysisInputBytesSync(io.File(source)),
      'class A {}\n'.codeUnits,
    );

    // 구문 스캐너는 dart:io 읽기 실패를 '읽을 수 없는 파일' 한계로 센다.
    // 부재와 UTF-8 디코드 실패가 그 모양(FileSystemException)을 지켜야
    // 스캐너의 기존 수습이 그대로 적용된다.
    final undecodable = p.join(workspace.path, 'bad.dart');
    io.File(undecodable).writeAsBytesSync(const [0xff, 0xfe, 0x00]);
    expect(
      () => readAnalysisInputSync(io.File(undecodable)),
      throwsA(isA<io.FileSystemException>()),
    );
    expect(
      () => readAnalysisInputSync(io.File(p.join(workspace.path, 'none'))),
      throwsA(isA<io.PathNotFoundException>()),
    );

    final device = p.join(workspace.path, 'device.dart');
    await io.Link(device).create('/dev/null');
    expect(
      () => readAnalysisInputBytesSync(io.File(device)),
      throwsA(isA<NonRegularFileException>()),
    );

    final large = p.join(workspace.path, 'large.dart');
    await writeOversizedSource(large, analysisReadLimit);
    expect(
      () => readAnalysisInputSync(io.File(large)),
      throwsA(isA<InputTooLargeException>()),
    );
  }, skip: io.Platform.isWindows);

  test('길이를 0으로 보고하는 가상 파일은 상한까지만 나눠 읽는다', () {
    // procfs 파일은 길이 0을 보고하지만 내용이 있다. dart:io 전체 읽기는
    // 이런 파일을 EOF까지 읽는다(`/proc/self/pagemap`은 끝없이 길다).
    const status = '/proc/self/status';
    final unbounded = BoundedResourceProvider().getFile(status);
    expect(io.File(status).lengthSync(), 0);
    expect(unbounded.readAsStringSync(), contains('Name:'));

    final bounded = BoundedResourceProvider(readLimit: 16);
    expect(
      () => bounded.getFile(status).readAsBytesSync(),
      throwsA(isA<FileSystemException>()),
    );
    expect(bounded.throwIfRejected, throwsA(isA<InputTooLargeException>()));
    expect(
      () => readUnknownLengthSync(io.File(status), 16),
      throwsA(isA<InputTooLargeException>()),
    );
  }, skip: !io.Platform.isLinux);

  test('탐색으로 얻은 자원도 같은 경계와 provider를 쓴다', () async {
    final provider = BoundedResourceProvider();
    final path = write('lib/a.dart', 'class A {}\n');
    await io.Link(p.join(workspace.path, 'lib', 'b.dart')).create('/dev/null');
    final root = provider.getFolder(workspace.path);
    final lib = root.getFolder('lib');

    final children = {for (final child in lib.getChildren()) child.shortName};
    expect(children, {'a.dart', 'b.dart'});
    for (final resource in [
      ...lib.getChildren(),
      root.getChild('lib'),
      lib.getChild('a.dart'),
      provider.getResource(path),
      provider.getResource(lib.path),
      lib.getFile('a.dart').parent,
      lib.parent,
      lib.getFile('a.dart').resolveSymbolicLinksSync(),
      lib.resolveSymbolicLinksSync(),
    ]) {
      expect(resource.provider, same(provider), reason: resource.path);
    }
    expect(provider.getResource(path), isA<File>());
    expect(provider.getResource(lib.path), isA<Folder>());
    expect(lib.getFile('a.dart'), provider.getFile(path));
    expect(lib.getFile('a.dart').hashCode, provider.getFile(path).hashCode);
    expect(lib, provider.getFolder(lib.path));
    expect(lib.getFile('a.dart'), isNot(provider.getFolder(path)));

    // 목록에서 얻은 링크 자식을 읽어도 경계를 지난다.
    final linked = lib.getChildren().whereType<File>().singleWhere(
      (file) => file.shortName == 'b.dart',
    );
    expect(linked.readAsBytesSync, throwsA(isA<FileSystemException>()));
    expect(provider.throwIfRejected, throwsA(isA<NonRegularFileException>()));
  }, skip: io.Platform.isWindows);

  test('쓰기·복사·이름 바꾸기·삭제는 실제 파일 시스템에 그대로 반영된다', () {
    final provider = BoundedResourceProvider();
    final source = provider.getFolder(p.join(workspace.path, 'src'))..create();
    expect(source.exists, isTrue);
    expect(source.isRoot, isFalse);
    expect(provider.getFolder('/').isRoot, isTrue);
    expect(provider.pathContext.separator, p.separator);

    final file = source.getFile('a.dart')..writeAsStringSync('class A {}\n');
    expect(file.exists, isTrue);
    expect(file.lengthSync, 11);
    expect(file.modificationStamp, greaterThan(0));
    expect(file.toUri(), Uri.file(file.path));
    expect(file.toString(), file.path);
    expect(file.isOrContains(file.path), isTrue);
    source.getFile('b.dart').writeAsBytesSync('class B {}\n'.codeUnits);

    expect(source.contains(file.path), isTrue);
    expect(source.isOrContains(source.path), isTrue);
    expect(source.canonicalizePath('x/../a.dart'), file.path);
    expect(source.toUri(), Uri.directory(source.path));
    expect(source.toString(), source.path);

    final copied = source.copyTo(
      provider.getFolder(workspace.path).getFolder('copy'),
    );
    expect(copied.provider, same(provider));
    expect(
      io.File(
        p.join(workspace.path, 'copy', 'src', 'b.dart'),
      ).readAsStringSync(),
      'class B {}\n',
    );

    final renamed = file.renameSync(p.join(source.path, 'c.dart'));
    expect(renamed.provider, same(provider));
    expect(renamed.readAsStringSync(), 'class A {}\n');
    expect(file.exists, isFalse);

    renamed.delete();
    expect(renamed.exists, isFalse);
    source.delete();
    expect(source.exists, isFalse);
    expect(provider.getLink(p.join(workspace.path, 'none')).exists, isFalse);
    provider.throwIfRejected();
  });
}
