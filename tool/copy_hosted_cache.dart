import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('Usage: copy-hosted-cache <package-config> <destination>');
    exitCode = 64;
    return;
  }
  try {
    final configuration = File(arguments[0]);
    final destination = Directory(arguments[1]);
    final document = jsonDecode(await configuration.readAsString());
    if (document is! Map<String, Object?> ||
        document['packages'] is! List<Object?>) {
      throw const FormatException('invalid package configuration');
    }

    var copied = 0;
    for (final value in document['packages']! as List<Object?>) {
      if (value is! Map<String, Object?> || value['rootUri'] is! String) {
        throw const FormatException('invalid package entry');
      }
      final uri = configuration.parent.uri
          .resolve(value['rootUri']! as String)
          .normalizePath();
      if (uri.scheme != 'file') continue;
      final sourcePath = _withoutTrailingSeparator(uri.toFilePath());
      final marker = '${Platform.pathSeparator}hosted${Platform.pathSeparator}';
      final markerIndex = sourcePath.indexOf(marker);
      if (markerIndex < 0) continue;
      final cacheRoot = sourcePath.substring(0, markerIndex);
      final relative = sourcePath.substring(cacheRoot.length + 1);
      final target = Directory(_join(destination.path, relative));
      await _copyDirectory(Directory(sourcePath), target);

      final metadata = Directory(
        _join(Directory(sourcePath).parent.path, '.cache'),
      );
      if (await metadata.exists()) {
        await _copyDirectory(
          metadata,
          Directory(_join(target.parent.path, '.cache')),
        );
      }
      copied++;
    }
    if (copied == 0) throw StateError('no hosted packages');
  } on Object {
    stderr.writeln('Could not prepare the isolated package cache.');
    exitCode = 2;
  }
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  if (await destination.exists()) return;
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final name = entity.path.substring(source.path.length + 1);
    final target = _join(destination.path, name);
    if (entity is File) {
      await entity.copy(target);
    } else if (entity is Directory) {
      await _copyDirectory(entity, Directory(target));
    } else if (entity is Link) {
      await Link(target).create(await entity.target());
    }
  }
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}${child.replaceAll('/', Platform.pathSeparator)}';

String _withoutTrailingSeparator(String path) {
  var result = path;
  while (result.length > 1 && result.endsWith(Platform.pathSeparator)) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}
