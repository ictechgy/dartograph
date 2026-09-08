import 'dart:convert';

import '../core/graph_node.dart';
import '../core/graph_snapshot.dart';

/// 그래프 사실을 결정론적인 교환 형식으로 직렬화한다.
abstract final class GraphExporter {
  /// 정렬된 키와 배열을 쓰는 JSON 문서를 만든다.
  static String json(
    GraphSnapshot graph, {
    Iterable<String> limitations = const [],
  }) {
    final value = <String, Object>{
      'edges': [
        for (final edge in graph.edges)
          <String, Object>{
            'kind': edge.kind.name,
            'source': edge.sourceId,
            'target': edge.targetId,
          },
      ],
      'limitations': limitations.toList()..sort(),
      'nodes': [
        for (final node in graph.nodes)
          <String, Object>{
            if (node.column != null) 'column': node.column!,
            'id': node.id,
            'isAbstract': node.isAbstract,
            'isTypeDeclaration': node.isTypeDeclaration,
            if (node.line != null) 'line': node.line!,
            if (node.sourceUri != null) 'sourceUri': node.sourceUri!,
            'synthesized': node.synthesized,
          },
      ],
    };
    return '${jsonEncode(value)}\n';
  }

  /// Graphviz가 읽는 DOT 문서를 만든다.
  static String dot(
    GraphSnapshot graph, {
    Iterable<String> limitations = const [],
  }) {
    final out = StringBuffer('digraph dartograph {\n');
    for (final limitation in limitations.toList()..sort()) {
      out.writeln('  // limitation: ${_escape(limitation)}');
    }
    for (final node in graph.nodes) {
      out.writeln(
        '  "${_escape(node.id)}"${node.synthesized ? ' [style=dashed]' : ''};',
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
              'name': _htmlName(node.id),
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

  static String _htmlKind(GraphNode node) {
    if (!node.id.contains('::')) return 'library';
    return node.isTypeDeclaration ? 'type' : 'member';
  }

  static String _htmlName(String id) {
    final symbolSeparator = id.indexOf('::');
    if (symbolSeparator >= 0) return id.substring(symbolSeparator + 2);
    final slash = id.lastIndexOf('/');
    return slash >= 0 ? id.substring(slash + 1) : id;
  }

  /// JSON 페이로드의 여는 꺾쇠를 전부 JSON 이스케이프로 바꾼다.
  ///
  /// `</`만 막으면 부족하다: `<!--<script`가 들어오면 HTML 토크나이저가 script
  /// 이중 이스케이프 상태에서 문서의 실제 `</script>`를 삼켜 페이지 전체가
  /// 스크립트 안으로 빨려 들어간다. `\u003c`는 적법한 JSON 문자열 이스케이프라
  /// 파싱 결과는 그대로고 토크나이저가 볼 꺾쇠는 남지 않는다.
  static String _escapeForScriptTag(String json) =>
      json.replaceAll('<', r'\u003c');

  static String _escapeHtmlText(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _escape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');

  /// Mermaid 라벨은 HTML 엔티티로 escape한다. DOT용 [_escape](백슬래시)는
  /// `<no-library>`·`<unnamed-extension@...>`처럼 dartograph가 스스로 만든 노드 ID를
  /// Mermaid가 HTML 태그로 오해하게 만든다. 따옴표는 인용 문자열을 중간에 끊고,
  /// `#`·역슬래시는 Mermaid가 문서화한 엔티티 코드(`#35;`·`#92;`·`#quot;`)로
  /// 디코딩되므로, `#`을 먼저 바꿔야 이후에 도입하는 코드가 다시 깨지지 않는다.
  static String _escapeMermaid(String value) => value
      .replaceAll('#', '#35;')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll(r'\', '#92;')
      .replaceAll('"', '#quot;');
}
