/// 실제 패키지 소유 경로를 먼저 떼어내 workspace와 단일 패키지의 범위를 맞춘다.
/// 일반 lib/test/ 같은 경로 조각은 테스트 디렉터리로 추측하지 않는다.
bool isTestSourceUri(
  String? source, {
  Iterable<String> packageRoots = const [],
}) {
  if (source == null || !source.startsWith('project:')) return false;
  var relative = source.substring('project:'.length);
  var owner = '';
  for (final root in packageRoots) {
    if (root.length > owner.length && relative.startsWith('$root/')) {
      owner = root;
    }
  }
  if (owner.isNotEmpty) relative = relative.substring(owner.length + 1);
  return const [
    'test/',
    'integration_test/',
    'example/test/',
    'example/integration_test/',
  ].any(relative.startsWith);
}
