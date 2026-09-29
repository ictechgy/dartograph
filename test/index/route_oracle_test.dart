import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/index/analyzer_graph_index.dart';
import 'package:dartograph/src/index/http_wrappers.dart';
import 'package:dartograph/src/index/route_call_index.dart';
import 'package:test/test.dart';

import '../../tool/route_oracle.dart';
import '../support/route_fixture_support.dart';

/// 모의 서버 오라클의 커밋된 기록(`fixtures/http_routes/oracle/recorded.json`,
/// 실제 http 1.6.0·dio 5.11.1·retrofit 4.10.0·chopper 8.7.0이 127.0.0.1 서버에
/// 보낸 요청)을 스텁으로 해석한 routes 사실과 대조한다. 네트워크 없이 매 CI에서
/// 돈다 — 기록을 다시 만드는 것은 `tool/run-http-route-oracle.sh`다.
void main() {
  late Directory fixture;
  late RouteCallIndexResult result;

  setUpAll(() async {
    fixture = await copyRouteFixture();
    final wrappers = parseHttpWrappers(
      File('${fixture.path}/http-wrappers.json').readAsStringSync(),
    );
    result = await indexRouteCalls(fixture.path, wrappers: wrappers);
  });

  tearDownAll(() => fixture.delete(recursive: true));

  test('every recorded request agrees with its route-call fact', () {
    final recorded =
        jsonDecode(
              File(
                'fixtures/http_routes/oracle/recorded.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final rows = compareRouteOracle(result.facts, recorded);
    final disagreements = [
      for (final row in rows)
        if (row.outcome == 'disagree') row,
    ];
    expect(disagreements, isEmpty);
    expect(rows.where((row) => row.outcome == 'agree'), hasLength(32));
    // 증명할 수 없는 세 호출은 dynamic으로 남는다(부분 세그먼트 보간, 미상 base
    // 뒤 상대 경로 두 건).
    expect(
      {
        for (final row in rows)
          if (row.outcome == 'dynamic')
            row.scenario.substring(row.scenario.indexOf('::') + 2),
      },
      {'httpPartialSegment', 'UsersRepository.profile', 'NoBaseApi.settings'},
    );
  });

  test('dio simple join and retrofit.dart double rule keep base paths', () {
    Map<String, Object?> factFor(String name) => result.facts.singleWhere(
      (fact) => ((fact['symbol']! as Map)['usr']! as String).endsWith(name),
    );
    // RFC 3986이면 `/users/{}`·`/items`였을 호출이 base 경로를 앞에 둔다.
    expect(factFor('::dioLiteralBase')['channel'], '/v1/users/{}');
    expect(factFor('::dioConcatenation')['channel'], '/v4health');
    expect(factFor('::AbsoluteBaseApi.user')['channel'], '/rv1/users/{}');
    expect(factFor('::AbsoluteBaseApi.create')['channel'], '/rv1items');
    expect(factFor('::RelativeBaseApi.order')['pathAnchor'], 'root');
    expect(factFor('::NoBaseApi.health')['pathAnchor'], 'base');
  });

  test('limitations name the dynamic joins and the internal sink', () {
    expect(
      result.limitations,
      contains(startsWith('ambiguous-base-join: 2 call(s)')),
    );
    // EndpointClient.execute는 매개변수의 속성(endpoint.path)을 URL로 흘려보낸다.
    expect(
      result.limitations,
      contains(startsWith('http-wrapper-undeclared: 1 ')),
    );
    expect(
      result.limitations.where((l) => l.startsWith('missing-route-usrs')),
      isEmpty,
    );
  });

  test('every usr is a node id of the impact graph on the same root', () async {
    final fixture = await copyRouteFixture();
    addTearDown(() => fixture.delete(recursive: true));
    final wrappers = parseHttpWrappers(
      File('${fixture.path}/http-wrappers.json').readAsStringSync(),
    );
    final result = await indexRouteCalls(fixture.path, wrappers: wrappers);
    final graph = await AnalyzerGraphIndex().index(fixture.path);
    final ids = {for (final node in graph.graph.snapshot().nodes) node.id};
    final usrs = {
      for (final fact in result.facts)
        (fact['symbol']! as Map<String, Object?>)['usr']! as String,
    };
    expect(usrs, isNotEmpty);
    expect(usrs.difference(ids), isEmpty);
  });
}
