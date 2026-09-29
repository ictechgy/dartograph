import 'package:http/http.dart' as http;

const _host = 'http://api.example.test';
const _api = '$_host/v1';

/// 리터럴 전체 URL — query 꼬리를 뗀다.
Future<void> httpLiteral() async {
  await http.get(Uri.parse('http://api.example.test/v1/items?page=1'));
}

/// 상수 보간과 세그먼트 보간.
Future<void> httpConstInterpolation(int id) async {
  await http.post(Uri.parse('$_api/items/$id'));
}

/// 인접 문자열 리터럴.
Future<void> httpAdjacent() async {
  await http.put(
    Uri.parse(
      'http://api.example.test'
      '/v1/'
      'settings',
    ),
  );
}

/// `Uri.http`의 host가 동적이어도 경로는 root다.
Future<void> httpUriComponents(String host, int id) async {
  await http.delete(Uri.http(host, '/v1/items/$id'));
}

/// `Uri.http`의 상대 경로에는 `/`가 붙는다.
Future<void> httpUriRelative() async {
  await http.head(Uri.http('api.example.test', 'v2/users'));
}

/// `Client` 메서드와 지역 변수에 담은 `Uri`.
Future<void> clientGet() async {
  final client = http.Client();
  final uri = Uri.parse('http://api.example.test/v1/profile');
  await client.get(uri);
  client.close();
}

/// `Request` 생성과 `send`.
Future<void> httpRequestSend() async {
  final client = http.Client();
  final request = http.Request(
    'PATCH',
    Uri.parse('http://api.example.test/v1/profile/name'),
  );
  await client.send(request);
  client.close();
}

/// 미상 base 뒤 `/`로 시작하는 경로는 base 앵커다.
Future<void> httpUnknownBase(String baseUrl) async {
  await http.get(Uri.parse('$baseUrl/v1/status'));
}

/// 세그먼트 일부를 채우는 보간은 dynamic이다.
Future<void> httpPartialSegment(String name) async {
  await http.get(Uri.parse('http://api.example.test/files/$name.json'));
}

/// `?`로 시작하거나 빈 지역 변수는 query 꼬리다.
Future<void> httpQueryTail(String? query) async {
  final suffix = query == null ? '' : '?q=$query';
  await http.get(Uri.parse('http://api.example.test/v1/search$suffix'));
}

/// `Uri.parse`는 점 세그먼트를 지운다.
Future<void> httpDotSegments() async {
  await http.get(Uri.parse('http://api.example.test/v1/a/../b'));
}
