import 'dart:convert';

import '../core/graph_edge.dart';
import '../core/graph_node.dart';
import '../core/graph_snapshot.dart';
import 'anonymizer.dart';

/// 그래프 사실을 결정론적인 교환 형식으로 직렬화한다.
///
/// ## 출력 표면의 제어문자·escape 정책 (정본)
///
/// 동적 값(노드 ID·경로·limitation 문자열)은 신뢰하지 않는 입력이다. 각 표면은
/// 자기 문법의 구조(문장·행·태그·명령)를 깨지 못하도록 아래 표를 구현한다.
/// 정상 입력의 바이트는 바꾸지 않고 병적 입력에서만 발동한다.
///
/// | 표면 | 정책 |
/// |---|---|
/// | JSON 계열 전부(dead json·sarif 본문·query·compare·affected·cycles·rules·metrics·graph json/dot/mermaid/html의 limitations) | `jsonEncode` 네이티브 이스케이프 — 추가 처리 없음 |
/// | DOT | `\`·`"`·LF·CR → DOT 문자열 이스케이프(`\\`·`\"`·`\n`·`\r`) — 문장 구조 보존, 개행은 DOT의 렌더링 개행 이스케이프로 정규화 |
/// | Mermaid | `#`·`\`·`"`·CR·LF → 문서화 엔티티 코드(`#35;`·`#92;`·`#quot;`·`#13;`·`#10;`), `&`·`<`·`>` → HTML 엔티티 — 라벨은 항상 한 물리행. 나머지 C0(탭·ESC 등)은 행 구조를 깨지 않아 그대로 둔다 |
/// | HTML | 페이로드: `<` → `\u003c`(적법한 JSON 이스케이프, script-tag 토크나이저 보호) / 헤더 limitation: HTML 텍스트 엔티티(raw LF는 HTML이 공백으로 흡수) |
/// | text(dead_reporter) | 동적 값 전체(path·id·kind·reason·evidence·limitation)의 C0·DEL → 가시 이스케이프 — `path:line:col:` 행 프로토콜 위조 방지. 가시 이스케이프는 표시 전용이며 소비자가 역변환할 계약은 없다 |
/// | GitHub Actions(dead_reporter) | `%`·C0·DEL·C1·U+2028/2029·bidi(U+202A–202E·U+2066–2069) → 퍼센트 인코딩. 원문의 리터럴 `%XX`는 `%25` 선행 인코딩으로 단일 디코드 후 원문 그대로 표시된다 |
/// | SARIF uri(dead_reporter) | project 상대 경로는 구분자 분리 + 세그먼트별 `Uri` 인코딩(`\`·`%` 손실 없음), `file:`·`package:` 소스는 이미 절대 URI라 그대로 통과 |
///
/// escape를 설계상 거치지 않는 값은 신뢰 고정 어휘다: edge `kind.name`(enum),
/// `report.label`·`severity`·`rulePrefix`(enum), mermaid의 순번 노드 ID `n$i`,
/// `title=dartograph …` 상수, dead_reporter의 baseline 억제 notice
/// (`$n finding(s) suppressed by baseline` — n은 정수). 이 자리에 앞으로 사용자
/// 유래 문자열을 보간하지 않는다 — 보간이 필요해지는 순간 해당 표면의 escape를
/// 먼저 확장한다.
abstract final class GraphExporter {
  /// 정렬된 키와 배열을 쓰는 JSON 문서를 만든다.
  static String json(
    GraphSnapshot graph, {
    Iterable<String> limitations = const [],
  }) =>
      '${jsonEncode({
        'edges': [for (final edge in graph.edges) _edgeJson(edge, null)],
        'limitations': limitations.toList()..sort(),
        'nodes': [for (final node in graph.nodes) _nodeJson(node, null)],
      })}\n';

  /// 식별 문자열만 치환한 JSON 문서를 만든다(anon 형식).
  ///
  /// 필드 구성은 [json]과 같다 — 정점 ID·소스 URI·간선 양끝·limitation 문구의
  /// 경로만 [GraphAnonymizer]로 바꾼다(dependency-cruiser `anon` 리포터 패리티).
  /// 치환은 결정적이라 같은 그래프는 항상 같은 문서를 낸다.
  static String anon(
    GraphSnapshot graph, {
    Iterable<String> limitations = const [],
  }) {
    final anonymizer = GraphAnonymizer.forGraph(graph);
    return '${jsonEncode({
      'edges': [for (final edge in graph.edges) _edgeJson(edge, anonymizer)],
      'limitations': [for (final limitation in limitations) anonymizer.anonymizeText(limitation)]..sort(),
      'nodes': [for (final node in graph.nodes) _nodeJson(node, anonymizer)],
    })}\n';
  }

  static Map<String, Object> _edgeJson(GraphEdge edge, GraphAnonymizer? map) =>
      {
        'kind': edge.kind.name,
        'source': map == null ? edge.sourceId : map.anonymizeId(edge.sourceId),
        'target': map == null ? edge.targetId : map.anonymizeId(edge.targetId),
      };

  static Map<String, Object> _nodeJson(GraphNode node, GraphAnonymizer? map) =>
      {
        if (node.column != null) 'column': node.column!,
        'id': map == null ? node.id : map.anonymizeId(node.id),
        'isAbstract': node.isAbstract,
        // line·column과 같은 조건부 필드 규약: 참일 때만 실어 정상 그래프의
        // 바이트를 보존하고, json 소비자도 캐시 문서처럼 enum 상수 보존
        // 판정(isEnumConstant)을 재현할 수 있다.
        if (node.isEnumConstant) 'isEnumConstant': true,
        'isTypeDeclaration': node.isTypeDeclaration,
        if (node.line != null) 'line': node.line!,
        if (node.sourceUri != null)
          'sourceUri': map == null
              ? node.sourceUri!
              : map.anonymizeUri(node.sourceUri!),
        'synthesized': node.synthesized,
      };

  /// Graphviz가 읽는 DOT 문서를 만든다.
  ///
  /// [cycleNodeIds]에 있는 정점은 순환 참여로 색칠한다(madge 순환 노드 색칠
  /// 패리티 — 붉은 테두리·글자). 속성은 `style=dashed`(synthesized)가 먼저
  /// 오고 이어 `color=red fontcolor=red` 순으로 고정이며, 집합에 없는 id는
  /// 그냥 무시된다. 순환 판정은 분석 영역이므로 호출자가 `CycleDetector`로
  /// 계산해 전달하고, 비어 있으면 출력은 색칠 없이 기존 바이트와 동일하다.
  static String dot(
    GraphSnapshot graph, {
    Iterable<String> limitations = const [],
    Set<String> cycleNodeIds = const {},
  }) {
    final out = StringBuffer('digraph dartograph {\n');
    for (final limitation in limitations.toList()..sort()) {
      out.writeln('  // limitation: ${_escape(limitation)}');
    }
    for (final node in graph.nodes) {
      final attributes = [
        if (node.synthesized) 'style=dashed',
        if (cycleNodeIds.contains(node.id)) ...const [
          'color=red',
          'fontcolor=red',
        ],
      ].join(' ');
      out.writeln(
        '  "${_escape(node.id)}"${attributes.isEmpty ? '' : ' [$attributes]'};',
      );
    }
    for (final edge in graph.edges) {
      out.writeln(
        '  "${_escape(edge.sourceId)}" -> "${_escape(edge.targetId)}" [label="${edge.kind.name}"];',
      );
    }
    return '${out.toString()}}\n';
  }

  /// Mermaid flowchart 문서를 안정적인 순번 ID로 만든다.
  static String mermaid(
    GraphSnapshot graph, {
    Iterable<String> limitations = const [],
  }) {
    final out = StringBuffer('flowchart LR\n');
    for (final limitation in limitations.toList()..sort()) {
      out.writeln('  %% limitation: ${_escapeMermaid(limitation)}');
    }
    final ids = <String, String>{};
    for (var index = 0; index < graph.nodes.length; index++) {
      final node = graph.nodes[index];
      ids[node.id] = 'n$index';
      out.writeln('  n$index["${_escapeMermaid(node.id)}"]');
    }
    for (final edge in graph.edges) {
      out.writeln(
        '  ${ids[edge.sourceId]} -->|${edge.kind.name}| ${ids[edge.targetId]}',
      );
    }
    return out.toString();
  }

  /// HTML이 그릴 최대 정점 수.
  ///
  /// 힘 기반 배치는 매 프레임 정점 쌍을 모두 훑으므로 비용이 정점 수의 제곱에
  /// 비례한다. 심볼 수준 그래프를 그대로 넘기면 브라우저가 멈춘다. well-connected
  /// 정점부터 남기고 잘라 낸 사실을 페이지에 그대로 적는다(cartograph와 같은 정책).
  static const htmlNodeLimit = 400;

  /// 외부 의존이 없는 단일 HTML 문서를 만든다.
  ///
  /// CDN·외부 스크립트·외부 폰트를 전혀 쓰지 않는다. 네트워크가 막힌 사내망이나
  /// CI 아티팩트에서 열어야 하고, 그림 하나 보려고 외부 스크립트를 불러오는 것은
  /// 보안 검토를 통과하기 어렵다. 그래프 사실은 `<script type="application/json">`
  /// 페이로드로 실리고, 캔버스 힘 기반 배치·검색·팬·줌이 인라인 JS로 렌더링한다.
  /// [nodeLimit] 초과분은 연결이 많은 정점부터 남기고 `truncatedFrom`과 페이지
  /// 알림으로 사실대로 보고한다.
  static String html(
    GraphSnapshot graph, {
    Iterable<String> limitations = const [],
    int nodeLimit = htmlNodeLimit,
  }) {
    final sortedLimitations = limitations.toList()..sort();
    final degrees = <String, int>{for (final node in graph.nodes) node.id: 0};
    for (final edge in graph.edges) {
      degrees[edge.sourceId] = (degrees[edge.sourceId] ?? 0) + 1;
      degrees[edge.targetId] = (degrees[edge.targetId] ?? 0) + 1;
    }
    // 임의로 자르면 그림이 의미를 잃는다. 연결이 많은 정점이 구조를 가장 잘
    // 설명하므로 degree 내림차순, 동률은 id 오름차순으로 결정적으로 남긴다.
    final ranked = graph.nodes.toList()
      ..sort((a, b) {
        final order = degrees[b.id]!.compareTo(degrees[a.id]!);
        return order != 0 ? order : a.id.compareTo(b.id);
      });
    final truncatedFrom = graph.nodes.length > nodeLimit
        ? graph.nodes.length
        : null;
    final kept = <String>{for (final node in ranked.take(nodeLimit)) node.id};
    final payload = <String, Object>{
      'edges': [
        for (final edge in graph.edges)
          if (kept.contains(edge.sourceId) && kept.contains(edge.targetId))
            <String, Object>{
              'kind': edge.kind.name,
              'source': edge.sourceId,
              'target': edge.targetId,
            },
      ],
      'limitations': sortedLimitations,
      'nodes': [
        for (final node in graph.nodes)
          if (kept.contains(node.id))
            <String, Object>{
              'id': node.id,
              'kind': _htmlKind(node),
              'name': _htmlName(node),
              'synthesized': node.synthesized,
            },
      ],
      'truncatedFrom': ?truncatedFrom,
    };
    final data = _escapeForScriptTag(jsonEncode(payload));
    final truncationNotice = truncatedFrom == null
        ? ''
        : '<span class="stat">truncated from $truncatedFrom nodes, keeping '
              'the most connected — use --format dot for the full graph</span>';
    final limitationsBlock = sortedLimitations.isEmpty
        ? ''
        : '<details><summary class="stat">${sortedLimitations.length} '
              'limitation(s)</summary><ul class="limitations">'
              '${sortedLimitations.map((item) => '<li>${_escapeHtmlText(item)}</li>').join()}'
              '</ul></details>';
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>dartograph — dependency graph</title>
<style>
  :root { color-scheme: light dark; --bg: #fbfbfd; --fg: #1d1d1f; --line: #d2d2d7; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #16161a; --fg: #f2f2f7; --line: #3a3a3f; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--fg);
         font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  header { display: flex; gap: 16px; align-items: center; flex-wrap: wrap;
           padding: 12px 16px; border-bottom: 1px solid var(--line); }
  h1 { font-size: 14px; margin: 0; font-weight: 600; }
  .stat { color: #8a8a8e; }
  input { padding: 5px 9px; border: 1px solid var(--line); border-radius: 6px;
          background: transparent; color: inherit; min-width: 200px; }
  ul.limitations { margin: 8px 0; padding-left: 20px; max-width: 70ch;
                   font-family: ui-monospace, SFMono-Regular, monospace; }
  #canvas { display: block; width: 100vw; height: calc(100vh - 96px); cursor: grab; }
  #canvas:active { cursor: grabbing; }
  footer { position: fixed; bottom: 0; left: 0; right: 0; padding: 6px 16px;
           border-top: 1px solid var(--line); background: var(--bg); }
  #details { font-family: ui-monospace, SFMono-Regular, monospace; }
</style>
</head>
<body>
<header>
  <h1>dartograph</h1>
  <span class="stat" id="summary"></span>
  $truncationNotice$limitationsBlock
  <input id="search" type="search" placeholder="Filter nodes by name" autocomplete="off">
</header>
<canvas id="canvas"></canvas>
<footer><span id="details">Drag to pan, scroll to zoom, click a node for details.</span></footer>
<script id="graph-data" type="application/json">$data</script>
<script>
(function () {
  var graph = JSON.parse(document.getElementById('graph-data').textContent);
  var canvas = document.getElementById('canvas');
  var context = canvas.getContext('2d');
  var summary = document.getElementById('summary');
  var details = document.getElementById('details');
  var search = document.getElementById('search');

  summary.textContent = graph.nodes.length + ' nodes · ' + graph.edges.length + ' edges';

  var indexById = new Map();
  var nodes = graph.nodes.map(function (node, index) {
    indexById.set(node.id, index);
    var angle = (index / graph.nodes.length) * Math.PI * 2;
    var radius = 60 + Math.sqrt(graph.nodes.length) * 22;
    return {
      id: node.id, name: node.name, kind: node.kind, synthesized: node.synthesized,
      x: Math.cos(angle) * radius, y: Math.sin(angle) * radius, vx: 0, vy: 0, degree: 0
    };
  });
  var links = [];
  graph.edges.forEach(function (edge) {
    var source = indexById.get(edge.source);
    var target = indexById.get(edge.target);
    if (source === undefined || target === undefined) { return; }
    links.push({ source: source, target: target, kind: edge.kind });
    nodes[source].degree += 1;
    nodes[target].degree += 1;
  });

  // 단순 힘 기반 배치. 라이브러리를 쓰지 않는 대신 반복 횟수를 제한한다.
  var alpha = 1;
  function step() {
    var repulsion = 5200;
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        var dx = nodes[j].x - nodes[i].x;
        var dy = nodes[j].y - nodes[i].y;
        var distanceSquared = dx * dx + dy * dy || 0.01;
        var force = repulsion / distanceSquared;
        var distance = Math.sqrt(distanceSquared);
        var fx = (dx / distance) * force;
        var fy = (dy / distance) * force;
        nodes[i].vx -= fx; nodes[i].vy -= fy;
        nodes[j].vx += fx; nodes[j].vy += fy;
      }
    }
    links.forEach(function (link) {
      var a = nodes[link.source], b = nodes[link.target];
      var dx = b.x - a.x, dy = b.y - a.y;
      var distance = Math.sqrt(dx * dx + dy * dy) || 0.01;
      var force = (distance - 130) * 0.02;
      var fx = (dx / distance) * force, fy = (dy / distance) * force;
      a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
    });
    nodes.forEach(function (node) {
      node.vx -= node.x * 0.002; node.vy -= node.y * 0.002;
      node.x += node.vx * alpha; node.y += node.vy * alpha;
      node.vx *= 0.82; node.vy *= 0.82;
    });
    alpha *= 0.995;
  }

  var view = { x: 0, y: 0, scale: 1 };
  var highlight = '';

  function radiusOf(node) { return 4 + Math.min(10, Math.sqrt(node.degree) * 2.2); }

  function colorOf(node) {
    if (node.synthesized) { return '#e08600'; }
    if (node.kind === 'library') { return '#0b64d0'; }
    if (node.kind === 'type') { return '#8a5cf6'; }
    return '#3aa06a';
  }

  function draw() {
    var ratio = window.devicePixelRatio || 1;
    canvas.width = canvas.clientWidth * ratio;
    canvas.height = canvas.clientHeight * ratio;
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);
    context.save();
    context.translate(canvas.clientWidth / 2 + view.x, canvas.clientHeight / 2 + view.y);
    context.scale(view.scale, view.scale);

    context.lineWidth = 1 / view.scale;
    context.strokeStyle = 'rgba(128,128,140,0.35)';
    links.forEach(function (link) {
      var a = nodes[link.source], b = nodes[link.target];
      context.beginPath();
      context.moveTo(a.x, a.y);
      context.lineTo(b.x, b.y);
      context.stroke();
    });

    nodes.forEach(function (node) {
      var matched = highlight === '' ||
        node.name.toLowerCase().indexOf(highlight) !== -1;
      context.globalAlpha = matched ? 1 : 0.15;
      context.beginPath();
      context.arc(node.x, node.y, radiusOf(node), 0, Math.PI * 2);
      context.fillStyle = colorOf(node);
      context.fill();
      if (view.scale > 0.55 && matched) {
        context.fillStyle = getComputedStyle(document.body).color;
        context.font = (11 / view.scale) + 'px -apple-system, sans-serif';
        context.fillText(node.name, node.x + radiusOf(node) + 3, node.y + 3);
      }
    });
    context.globalAlpha = 1;
    context.restore();
  }

  function frame() {
    if (alpha > 0.02) { step(); }
    draw();
    requestAnimationFrame(frame);
  }

  var dragging = false, lastX = 0, lastY = 0;
  canvas.addEventListener('mousedown', function (event) {
    dragging = true; lastX = event.clientX; lastY = event.clientY;
  });
  window.addEventListener('mouseup', function () { dragging = false; });
  window.addEventListener('mousemove', function (event) {
    if (!dragging) { return; }
    view.x += event.clientX - lastX;
    view.y += event.clientY - lastY;
    lastX = event.clientX; lastY = event.clientY;
  });
  canvas.addEventListener('wheel', function (event) {
    event.preventDefault();
    view.scale = Math.max(0.15, Math.min(6, view.scale * (event.deltaY < 0 ? 1.1 : 0.9)));
  }, { passive: false });
  canvas.addEventListener('click', function (event) {
    var rect = canvas.getBoundingClientRect();
    var x = (event.clientX - rect.left - canvas.clientWidth / 2 - view.x) / view.scale;
    var y = (event.clientY - rect.top - canvas.clientHeight / 2 - view.y) / view.scale;
    var found = null;
    nodes.forEach(function (node) {
      var dx = node.x - x, dy = node.y - y;
      if (dx * dx + dy * dy < Math.pow(radiusOf(node) + 4, 2)) { found = node; }
    });
    details.textContent = found
      ? found.kind + ' ' + found.name + ' · ' + found.degree + ' connections · ' + found.id
      : 'Drag to pan, scroll to zoom, click a node for details.';
  });
  search.addEventListener('input', function () {
    highlight = search.value.trim().toLowerCase();
  });

  frame();
})();
</script>
</body>
</html>
''';
  }

  /// 정점의 표시 종류. 라이브러리/선언 구분은 GraphNode의 명시적 isLibrary로만
  /// 판정한다 — id 모양에서 유추하지 않는다(파일명에 `::`가 있어도(macOS 등에서
  /// 합법), 심지어 `.dart::`를 포함해도 종류가 흔들리지 않는다. 감사 "낮음":
  /// html `::` 파일명 오분류의 근본 해결 — 옛 `.dart::` 휴리스틱의 잔여 엣지였던
  /// `weird.dart::name.dart` 같은 파일명도 정확히 라이브러리로 분류한다).
  static String _htmlKind(GraphNode node) {
    if (node.isLibrary) return 'library';
    return node.isTypeDeclaration ? 'type' : 'member';
  }

  static String _htmlName(GraphNode node) {
    if (!node.isLibrary) {
      // 선언 이름은 마지막 `::` 뒤에 온다(파일명에 `::`가 있어도 구분자는 마지막 것).
      final separator = node.id.lastIndexOf('::');
      if (separator >= 0) return node.id.substring(separator + 2);
      // `<unnamed-extension@…>`처럼 `::` 없는 선언 ID는 경로 마지막 세그먼트로
      // 표시한다(옛 라이브러리 분기와 같은 규칙 — 출력 보존).
    }
    final slash = node.id.lastIndexOf('/');
    return slash >= 0 ? node.id.substring(slash + 1) : node.id;
  }

  /// JSON 페이로드의 여는 꺾쇠를 전부 JSON 이스케이프로 바꾼다.
  ///
  /// `</`만 막으면 부족하다: `<!--<script`가 들어오면 HTML 토크나이저가 script
  /// 이중 이스케이프 상태에서 문서의 실제 `</script>`를 삼켜 페이지 전체가
  /// 스크립트 안으로 빨려 들어간다. `\u003c`는 적법한 JSON 문자열 이스케이프라
  /// 파싱 결과는 그대로고 토크나이저가 볼 꺾쇠는 남지 않는다. `>`는 raw로 둬도
  /// script 데이터 상태의 토크나이저·`JSON.parse` 양쪽에 무해하다(`]]>`는 XML
  /// 도구 체인에서만 문제지만 이 출력의 계약은 브라우저 HTML이다). U+2028/2029도
  /// 페이로드가 JS 소스가 아니라 JSON.parse 입력이므로 재이스케이프하지 않는다.
  static String _escapeForScriptTag(String json) =>
      json.replaceAll('<', r'\u003c');

  static String _escapeHtmlText(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// DOT 인용 문자열 이스케이프. LF와 대칭으로 CR도 DOT 개행 이스케이프로
  /// 정규화한다(DOT에서 `\r`은 우측 정렬 개행 — raw CR이 행 구조를 흐트러뜨리지
  /// 않게 표시 수준으로 흡수).
  static String _escape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');

  /// Mermaid 라벨은 HTML 엔티티로 escape한다. DOT용 [_escape](백슬래시)는
  /// `<no-library>`·`<unnamed-extension@...>`처럼 dartograph가 스스로 만든 노드 ID를
  /// Mermaid가 HTML 태그로 오해하게 만든다. 따옴표는 인용 문자열을 중간에 끊고,
  /// `#`·역슬래시·개행은 Mermaid가 문서화한 엔티티 코드(`#35;`·`#92;`·`#quot;`·
  /// `#13;`·`#10;`)로 디코딩되므로, `#`을 먼저 바꿔야 이후에 도입하는 코드가 다시
  /// 깨지지 않는다. raw 개행은 라벨을 두 물리행으로 갈라 `b.dart"]` 같은 조각이
  /// 독립 문장이 되게 하므로(구문 절단·주입) 엔티티 코드로 한 행에 유지한다.
  static String _escapeMermaid(String value) => value
      .replaceAll('#', '#35;')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll(r'\', '#92;')
      .replaceAll('"', '#quot;')
      .replaceAll('\r', '#13;')
      .replaceAll('\n', '#10;');
}
