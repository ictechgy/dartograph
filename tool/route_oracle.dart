// 모의 서버 오라클 대조: routes 사실의 (method, 템플릿, 앵커)를 실제 클라이언트가
// 로컬 서버에 보낸 요청(method, path)과 비교해 일치 표를 낸다.
//
// 사용: dart run tool/route_oracle.dart <routes-facts.json> <recorded.json>
// 불일치가 있으면 종료 코드 1이다. 대조 규칙은 test/index/route_oracle_test.dart가
// 같은 함수로 커밋된 기록과 다시 확인한다.
import 'dart:convert';
import 'dart:io';

/// 시나리오 하나의 대조 결과다.
typedef OracleRow = ({
  String scenario,
  String outcome,
  String recorded,
  String fact,
});

/// 사실과 기록을 `symbol.usr`로 묶어 대조한다.
///
/// - `agree`: 동사가 같고, root 앵커면 템플릿이 경로 전체와, base 앵커면 경로의
///   세그먼트 경계 꼬리와 맞는다(`{}`는 비어 있지 않은 세그먼트 하나). authority가
///   있으면 요청 host와 같다.
/// - `dynamic`: 사실이 dynamic이다. channelPrefix가 있으면 그 접두사(root)나
///   꼬리(base)가 기록과 모순되지 않아야 한다.
/// - `disagree`: 그 밖의 모든 경우다.
List<OracleRow> compareRouteOracle(
  List<Map<String, Object?>> facts,
  Map<String, Object?> recorded,
) {
  final byUsr = <String, List<Map<String, Object?>>>{};
  for (final fact in facts) {
    final symbol = fact['symbol'] as Map<String, Object?>?;
    final usr = symbol?['usr'] as String?;
    if (usr != null) (byUsr[usr] ??= []).add(fact);
  }
  return [
    for (final entry in recorded.entries)
      _compare(entry.key, byUsr[entry.key] ?? const [], entry.value),
  ];
}

OracleRow _compare(
  String scenario,
  List<Map<String, Object?>> facts,
  Object? value,
) {
  final requests = value is List ? value.cast<Map<String, Object?>>() : null;
  if (requests == null || requests.length != 1 || facts.length != 1) {
    return (
      scenario: scenario,
      outcome: 'disagree',
      recorded: '$value',
      fact: '${facts.length} fact(s)',
    );
  }
  final request = requests.single;
  final fact = facts.single;
  final path = request['path']! as String;
  final recordedText = '${request['method']} $path';
  final factText = _describe(fact);
  final methodOk =
      fact['methodDynamic'] == true || fact['method'] == request['method'];
  final authority = fact['authority'];
  final hostOk = authority == null || authority == request['host'];
  final String outcome;
  if (fact['dynamic'] == true) {
    final prefix = fact['channelPrefix'] as String?;
    final prefixOk =
        prefix == null || _prefixConsistent(prefix, path, fact['pathAnchor']);
    outcome = methodOk && hostOk && prefixOk ? 'dynamic' : 'disagree';
  } else {
    final templateOk = _matches(
      fact['channel']! as String,
      path,
      fact['pathAnchor'],
    );
    outcome = methodOk && hostOk && templateOk && fact['methodDynamic'] != true
        ? 'agree'
        : 'disagree';
  }
  return (
    scenario: scenario,
    outcome: outcome,
    recorded: recordedText,
    fact: factText,
  );
}

String _describe(Map<String, Object?> fact) {
  final method = fact['method'] ?? '(methodDynamic)';
  if (fact['dynamic'] == true) {
    return '$method dynamic prefix=${fact['channelPrefix'] ?? '-'} ${fact['pathAnchor']}';
  }
  return '$method ${fact['channel']} ${fact['pathAnchor']}';
}

List<String> _segments(String path) => path.substring(1).split('/');

bool _segmentMatches(String template, String actual) =>
    template == '{}' ? actual.isNotEmpty : template == actual;

/// root는 전체, base는 세그먼트 경계 꼬리가 맞아야 한다.
bool _matches(String template, String path, Object? anchor) {
  final expected = _segments(template);
  final actual = _segments(path);
  if (anchor == 'root' && expected.length != actual.length) return false;
  if (expected.length > actual.length) return false;
  final offset = actual.length - expected.length;
  for (var index = 0; index < expected.length; index++) {
    if (!_segmentMatches(expected[index], actual[offset + index])) return false;
  }
  return true;
}

/// channelPrefix는 dynamic 호출의 증명된 앞부분이다. root면 기록 경로가 그
/// 접두사(마지막 조각은 문자열 접두사)로 시작해야 하고, base면 어딘가에서
/// 시작해야 한다.
bool _prefixConsistent(String prefix, String path, Object? anchor) {
  if (anchor == 'root') return path.startsWith(prefix.replaceAll('{}', ''));
  return path.contains(prefix.replaceAll('{}', ''));
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('Usage: route_oracle <routes-facts.json> <recorded.json>');
    exitCode = 64;
    return;
  }
  final document =
      jsonDecode(await File(arguments[0]).readAsString())
          as Map<String, Object?>;
  final recorded =
      jsonDecode(await File(arguments[1]).readAsString())
          as Map<String, Object?>;
  final facts = (document['facts']! as List).cast<Map<String, Object?>>();
  final rows = compareRouteOracle(facts, recorded);
  stdout.writeln('| scenario | recorded request | route-call fact | outcome |');
  stdout.writeln('|---|---|---|---|');
  for (final row in rows) {
    final name = row.scenario.substring(row.scenario.indexOf('::') + 2);
    stdout.writeln(
      '| `$name` | `${row.recorded}` | `${row.fact}` | ${row.outcome} |',
    );
  }
  final counts = <String, int>{};
  for (final row in rows) {
    counts.update(row.outcome, (n) => n + 1, ifAbsent: () => 1);
  }
  stdout.writeln('\n${rows.length} scenario(s): $counts');
  if (counts.containsKey('disagree')) exitCode = 1;
}
