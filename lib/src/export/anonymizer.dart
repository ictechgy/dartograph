import '../core/graph_snapshot.dart';

/// 익명화가 그대로 두는 구조·공용 어휘다.
///
/// 스킴 접두와 관용 디렉터리·진입점 이름은 프로젝트를 식별하지 않는다.
/// 확장자는 세그먼트 규칙으로 보존된다.
const _whitelist = {
  'package',
  'project',
  'dart',
  'file',
  'lib',
  'src',
  'test',
  'bin',
  'example',
  'tool',
  'index',
  'main',
  '<no-library>',
};

/// 그래프 정체성을 결정적으로 익명화한다(dependency-cruiser `anon` 리포터 패리티).
///
/// 목적은 버그 리포트 공유다 — 구조(스킴·디렉터리 계층·`::`·멤버 점 구분·확장자)는
/// 보존하고 식별 문자열만 치환한다. 원본 단어 대신 무작위 단어 목록을 쓰는
/// dependency-cruiser와 달리, 정렬된 정점 순서대로 세는 결정적 토큰(`s0`, `s1`, …)을
/// 쓴다 — 같은 그래프는 항상 같은 출력이어야 이 형식의 회귀·비교가 가능하다.
/// 치환은 단사고 서로 다른 세그먼트는 결코 같은 토큰을 공유하지 않는다.
final class GraphAnonymizer {
  /// 그래프의 정점 ID·소스 URI에서 치환표를 미리 만든다.
  factory GraphAnonymizer.forGraph(GraphSnapshot graph) {
    final anonymizer = GraphAnonymizer._();
    for (final node in graph.nodes) {
      anonymizer.anonymizeId(node.id);
      final uri = node.sourceUri;
      if (uri != null) anonymizer.anonymizeUri(uri);
    }
    return anonymizer;
  }

  GraphAnonymizer._();

  final _segments = <String, String>{};
  final _paths = <String, String>{};

  /// 정점 ID(라이브러리 또는 `<라이브러리>::<선언>`)를 익명화한다.
  String anonymizeId(String id) {
    final separator = id.indexOf('::');
    if (separator < 0) return _library(id);
    final name = id.substring(separator + 2);
    return '${_library(id.substring(0, separator))}::${_declaration(name)}';
  }

  /// 소스 URI(라이브러리 경로)를 익명화한다.
  String anonymizeUri(String uri) => _library(uri);

  /// 자유 문구(예: limitation)에서 치환표에 등록된 경로 전체를 치환한다.
  ///
  /// 문구에 박힌 경로는 그래프에 실린 라이브러리 경로와 같은 문자열이다
  /// (예: `configured-entry-point-without-main: lib/a.dart`). 경로 전체만
  /// 바꾸고 세그먼트 단위 치환은 하지 않는다 — 짧은 파일명이 문구의 일반
  /// 단어와 겹쳐 과다치환하는 일을 막는다. 문구 치환 키는 슬래시를 가진
  /// 다중 세그먼트 경로만 등록한다(한 글자·단어 id가 문구의 일반 단어를
  /// 치환하는 사고 방지). 그래프에 없는 경로는 문구에 그대로 남는다
  /// (보장 범위는 USAGE에 문서화).
  String anonymizeText(String value) {
    var result = value;
    final keys = _paths.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final key in keys) {
      result = result.replaceAll(key, _paths[key]!);
    }
    return result;
  }

  String _library(String id) {
    final scheme = RegExp(r'^([a-z]+:)').firstMatch(id);
    final prefix = scheme?.group(1) ?? '';
    final rest = id.substring(prefix.length);
    if (rest.isEmpty) return id;
    final mapped = prefix + rest.split('/').map(_segment).join('/');
    if (mapped != id && rest.contains('/')) {
      // 경로 전체 키: 스킴 있는 그대로와 스킴 없는 상대 형태 둘 다 등록한다.
      // 다중 세그먼트 경로만 등록한다(anonymizeText 문서 참조).
      _paths.putIfAbsent(id, () => mapped);
      if (prefix.isNotEmpty) {
        _paths.putIfAbsent(rest, () => mapped.substring(prefix.length));
      }
    }
    return mapped;
  }

  String _declaration(String name) =>
      // 멤버의 점(`Foo.bar`)과 setter `=` 접미는 구조다 — 부분별로 치환한다.
      name.split('.').map(_segment).join('.');

  String _segment(String segment) => _segments.putIfAbsent(segment, () {
    if (_whitelist.contains(segment)) return segment;
    // 확장자는 보존한다: 첫 마침표 뒤는 그대로 둔다(`a.spec.dart` → `s3.spec.dart`).
    final dot = segment.indexOf('.');
    final suffix = dot < 0 ? '' : segment.substring(dot);
    return 's${_segments.length}$suffix';
  });
}
