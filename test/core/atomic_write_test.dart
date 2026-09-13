import 'dart:io';

import 'package:dartograph/src/core/atomic_write.dart';
import 'package:test/test.dart';

void main() {
  group('AtomicWrite', () {
    late Directory temporary;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('dartograph-atomic-');
    });

    tearDown(() => temporary.delete(recursive: true));

    test('writes the target content via sync and async paths', () async {
      final syncTarget = File('${temporary.path}/sync.txt');
      AtomicWrite.stringSync(syncTarget, 'sync-payload');
      expect(syncTarget.readAsStringSync(), 'sync-payload');

      final asyncTarget = File('${temporary.path}/async.txt');
      await AtomicWrite.string(asyncTarget, 'async-payload');
      expect(await asyncTarget.readAsString(), 'async-payload');
    });

    test(
      'replaces a symlink at the target without touching its target file',
      () async {
        final outside = File('${temporary.path}/outside.txt');
        outside.writeAsStringSync('precious');
        final link = Link('${temporary.path}/link.txt')
          ..createSync(outside.path);

        AtomicWrite.stringSync(File(link.path), 'replacement');

        expect(outside.readAsStringSync(), 'precious');
        expect(File(link.path).readAsStringSync(), 'replacement');
        expect(FileSystemEntity.isLinkSync(link.path), isFalse);
      },
    );

    test('replaces a dangling symlink at the target without creating it', () {
      final target = Link('${temporary.path}/dangling.txt')
        ..createSync('${temporary.path}/never-created.txt');

      AtomicWrite.stringSync(File(target.path), 'replacement');

      expect(File('${temporary.path}/never-created.txt').existsSync(), isFalse);
      expect(File(target.path).readAsStringSync(), 'replacement');
      expect(FileSystemEntity.isLinkSync(target.path), isFalse);
    });

    test('fails closed on a pre-planted dangling symlink at the temp path', () {
      final target = File('${temporary.path}/guarded.txt');
      final tempPath = '${target.path}.tmp.$pid.fixed';
      final victim = '${temporary.path}/planted-victim.txt';
      Link(tempPath).createSync(victim);

      expect(
        () => AtomicWrite.stringSync(target, 'payload', tempSuffix: 'fixed'),
        throwsA(isA<FileSystemException>()),
      );

      // 심어둔 링크는 절단·관통되지 않고 그대로 남는다.
      expect(FileSystemEntity.isLinkSync(tempPath), isTrue);
      expect(File(victim).existsSync(), isFalse);
      expect(target.existsSync(), isFalse);
    });

    test('leaves no temporary file behind when the rename fails', () async {
      // 대상 자리가 디렉터리면 임시 생성·기록은 성공해도 교체가 실패한다.
      Directory('${temporary.path}/occupied').createSync();
      final target = File('${temporary.path}/occupied');

      expect(
        () => AtomicWrite.stringSync(target, 'orphan'),
        throwsA(isA<FileSystemException>()),
      );

      expect(temporary.listSync(), hasLength(1));
      expect(temporary.listSync().single.path, endsWith('/occupied'));
    });

    test('async path also cleans up when the rename fails', () async {
      Directory('${temporary.path}/occupied').createSync();
      final target = File('${temporary.path}/occupied');

      await expectLater(
        AtomicWrite.string(target, 'orphan'),
        throwsA(isA<FileSystemException>()),
      );

      expect(temporary.listSync(), hasLength(1));
      expect(temporary.listSync().single.path, endsWith('/occupied'));
    });
  });
}
