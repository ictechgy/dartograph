import 'package:dio/dio.dart';

/// 래퍼의 동사 enum.
enum Verb {
  /// GET.
  get,

  /// POST.
  post,
}

/// 경로와 동사를 흘려보내는 앱 래퍼(http-wrappers 선언 대상).
class ApiWrapper {
  /// 주입된 [_dio]로 만든다.
  ApiWrapper(this._dio);

  final Dio _dio;

  /// [path]를 [method]로 보낸다.
  Future<void> send(String path, {Verb method = Verb.get}) async {
    await _dio.request(
      path,
      options: Options(method: method.name.toUpperCase()),
    );
  }
}

/// 엔드포인트 기술자(생성자 래퍼 선언 대상).
class Endpoint {
  /// [path]와 [method]로 만든다.
  const Endpoint(this.path, {this.method = 'GET'});

  /// 경로.
  final String path;

  /// 동사.
  final String method;
}

/// 기술자를 실행한다.
class EndpointClient {
  /// 주입된 [_dio]로 만든다.
  EndpointClient(this._dio);

  final Dio _dio;

  /// [endpoint]를 보낸다.
  Future<void> execute(Endpoint endpoint) async {
    await _dio.request(
      endpoint.path,
      options: Options(method: endpoint.method),
    );
  }
}

/// 선언된 함수 래퍼 호출.
Future<void> wrapperGet(ApiWrapper api) async {
  await api.send('/w/items');
}

/// 선언된 함수 래퍼의 enum 동사.
Future<void> wrapperPost(ApiWrapper api) async {
  await api.send('/w/orders', method: Verb.post);
}

/// 선언된 생성자 래퍼.
Future<void> endpointDelete(EndpointClient client, int id) async {
  await client.execute(Endpoint('/e/items/$id', method: 'DELETE'));
}
