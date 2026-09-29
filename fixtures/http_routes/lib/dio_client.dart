import 'package:dio/dio.dart';

final _literal = Dio(BaseOptions(baseUrl: 'http://api.example.test/v1'));
final _trailing = Dio(BaseOptions(baseUrl: 'http://api.example.test/v2/'));
final _noSlash = Dio(BaseOptions(baseUrl: 'http://api.example.test/v4'));

/// dio 단순 연결: base 경로 뒤에 `/users/…`가 붙는다(RFC 3986이면 `/users/…`).
Future<void> dioLiteralBase(int id) async {
  await _literal.get('/users/$id');
}

/// base 끝 `/`와 경로 앞 `/`가 만나면 `//`를 `/`로 줄인다.
Future<void> dioTrailingSlash() async {
  await _trailing.post('/orders');
}

/// base 끝 `/` 뒤 상대 경로.
Future<void> dioRelativeAfterSlash() async {
  await _trailing.put('carts');
}

/// 슬래시 없는 base와 상대 경로는 문자열 그대로 붙는다(`/v4health`).
Future<void> dioConcatenation() async {
  await _noSlash.get('health');
}

/// 경로 안의 `//`도 줄인다.
Future<void> dioDoubleSlash() async {
  await _literal.delete('/a//b');
}

/// `request`의 `Options.method`는 대문자로 바뀐다.
Future<void> dioRequestMethod() async {
  await _literal.request('/profile', options: Options(method: 'patch'));
}

/// `getUri`는 `uri.toString()`을 base에 붙인다.
Future<void> dioGetUri() async {
  await _literal.getUri(Uri.parse('/raw'));
}

/// 주입된 dio의 base는 모른다.
class UsersRepository {
  /// 주입된 [_dio]로 만든다.
  UsersRepository(this._dio);

  final Dio _dio;

  /// `/`로 시작하는 경로는 base 앵커다.
  Future<void> load(int id) async {
    await _dio.get('/users/$id');
  }

  /// 미상 base 뒤 상대 경로는 모호하다.
  Future<void> profile() async {
    await _dio.get('profile');
  }
}
