import '../core/graph_snapshot.dart';

/// 익명화가 그대로 두는 구조·공용 어휘다.
///
/// 스킴 접두와 관용 디렉터리 이름은 프로젝트를 식별하지 않는다. 확장자는
/// 세그먼트 규칙으로 보존된다. 관용 어휘는 경로 세그먼트와 선언 이름 부분에
/// 같이 적용된다 — `main`·`test` 같은 이름은 어느 위치에 있든 관용어다.
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

/// dartograph 정점 ID가 실제로 쓰는 스킴 접두다. 이 외의 `x:` 모양 접두는
/// 스킴으로 통과시키지 않고 식별 문자열로 치환한다.
final _schemePattern = RegExp(r'^(package:|project:|dart:|file:)');

/// 세그먼트 끝에서 원문으로 남기는 확장자다(가장 긴 것이 이긴다).
///
/// `.dart`와 생성 파일 접미다. 생성 접미는 index의 `_generatedDartSuffixes`와 같은
/// 목록이다. 그 상수는 index 전용이고 export는 index에 의존하지 않으므로 여기에
/// 고정해 둔다. 목록 밖의 점 구분 부분(`a.spec.dart`의 `spec`, `com.acme.internal`,
/// `.yaml` 같은 다른 확장자)은 식별 문자열일 수 있어 부분마다 치환한다. 목록의
/// 조각(`g`·`pb` 등)은 토큰(`sN`)·관용 어휘와 겹치지 않아 치환이 단사로 남는다.
const _preservedExtensions = [
  '.dart',
  '.g.dart',
  '.freezed.dart',
  '.pb.dart',
  '.pbenum.dart',
  '.pbgrpc.dart',
  '.pbjson.dart',
  '.pbserver.dart',
];

/// 그래프 정체성을 결정적으로 익명화한다(dependency-cruiser `anon` 리포터 패리티).
///
/// 목적은 버그 리포트 공유다 — 구조(스킴·디렉터리 계층·`::`·멤버 점 구분·
/// `.dart`와 생성 파일 확장자)는 보존하고 식별 문자열만 치환한다. 원본 단어 대신
/// 무작위 단어 목록을 쓰는 dependency-cruiser와 달리, 정렬된 정점 순서대로 세는
/// 결정적 토큰(`s0`, `s1`, …)을 쓴다 — 같은 그래프는 항상 같은 출력이어야 이 형식의
/// 회귀·비교가 가능하다.
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
  final _ids = <String, String>{};
  RegExp? _textPattern;

  /// 정점 ID(라이브러리 또는 `<라이브러리>::<선언>`)를 익명화한다.
  ///
  /// 결과는 ID별로 메모한다. 간선 양끝처럼 같은 ID를 거듭 묻는 호출자가
  /// 정규식·split·join을 되풀이하지 않게 한다. 치환표가 결정적이라 메모해도
  /// 결과는 같다.
  String anonymizeId(String id) => _ids[id] ??= _anonymizeId(id);

  String _anonymizeId(String id) {
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
  /// 치환하는 사고 방지). 치환은 등록된 전체 키를 교대 패턴으로 묶어
  /// **한 번의 패스**로 수행한다(긴 키 먼저) — 연쇄 replaceAll이 치환
  /// 결과물을 다시 치환하는 이중 치환이 구조적으로 불가능하다. 그래프에
  /// 없는 경로는 문구에 그대로 남는다(보장 범위는 USAGE에 문서화).
  String anonymizeText(String value) {
    if (_paths.isEmpty) return value;
    // 같은 시작 위치에서는 긴 키가 먼저 매칭되도록 교대 순서를 길이 내림차로.
    _textPattern ??= RegExp(
      (_paths.keys.toList()..sort((a, b) => b.length.compareTo(a.length)))
          .map(RegExp.escape)
          .join('|'),
    );
    return value.replaceAllMapped(_textPattern!, (match) => _paths[match[0]]!);
  }

  String _library(String id) {
    final scheme = _schemePattern.firstMatch(id);
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
      // 멤버의 점(`Foo.bar`)은 구조다 — 부분별로 치환한다. setter 접미 `=`,
      // 확장자와 마찬가지로 식별자가 아닌 구조라 세그먼트 규칙과 대칭으로
      // 보존한다(`Foo.value=` → `s1.s2=`).
      name
          .split('.')
          .map((part) {
            final setter = part.endsWith('=') ? '=' : '';
            final stem = setter.isEmpty
                ? part
                : part.substring(0, part.length - 1);
            return '${_segment(stem)}$setter';
          })
          .join('.');

  /// 경로 세그먼트나 선언 이름 부분 하나를 치환한다(세그먼트별 메모).
  String _segment(String segment) =>
      _segments[segment] ??= _replaceSegment(segment);

  /// [_segment]의 본문이다. 토큰 번호는 처음 본 순서로 매기는 표의 크기다.
  ///
  /// 알려진 확장자만 원문으로 남긴다. 줄기(stem)에 점이 없으면 세그먼트 전체를
  /// 토큰 하나로 바꾼다(`repo.dart` → `s3.dart`, `cart.g.dart` → `s2.g.dart`).
  /// 줄기에 점이 남으면(`a.spec.dart`, `com.acme.internal`) 점으로 나눈 부분마다
  /// 같은 표로 치환한다. 첫 마침표 뒤를 원문으로 두면 `acme.billing_gateway.dart`
  /// 처럼 이름 대부분이 남기 때문이다. 빈 부분은 그대로 둬 점 구조를 지킨다.
  /// 부분과 토큰은 점을 담지 않으므로 서로 다른 세그먼트는 같은 결과가 되지 않는다.
  String _replaceSegment(String segment) {
    if (_whitelist.contains(segment)) return segment;
    final extension = _extensionOf(segment);
    final stem = segment.substring(0, segment.length - extension.length);
    if (!stem.contains('.')) return 's${_segments.length}$extension';
    final parts = [
      for (final part in stem.split('.')) part.isEmpty ? part : _segment(part),
    ];
    return '${parts.join('.')}$extension';
  }

  static String _extensionOf(String segment) {
    var extension = '';
    for (final candidate in _preservedExtensions) {
      if (candidate.length > extension.length && segment.endsWith(candidate)) {
        extension = candidate;
      }
    }
    return extension;
  }
}
