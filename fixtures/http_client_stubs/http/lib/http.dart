// package:http 1.6.0의 API 모양만 흉내 낸 스텁이다.
class Response {}

class StreamedResponse {}

abstract class BaseRequest {
  BaseRequest(this.method, this.url);
  final String method;
  final Uri url;
}

class Request extends BaseRequest {
  Request(super.method, super.url);
}

class StreamedRequest extends BaseRequest {
  StreamedRequest(super.method, super.url);
}

class MultipartRequest extends BaseRequest {
  MultipartRequest(super.method, super.url);
}

abstract interface class Client {
  factory Client() => _IOClient();
  Future<Response> head(Uri url, {Map<String, String>? headers});
  Future<Response> get(Uri url, {Map<String, String>? headers});
  Future<Response> post(Uri url, {Map<String, String>? headers, Object? body});
  Future<Response> put(Uri url, {Map<String, String>? headers, Object? body});
  Future<Response> patch(Uri url, {Map<String, String>? headers, Object? body});
  Future<Response> delete(Uri url, {Map<String, String>? headers, Object? body});
  Future<String> read(Uri url, {Map<String, String>? headers});
  Future<StreamedResponse> send(BaseRequest request);
  void close();
}

abstract mixin class BaseClient implements Client {
  @override
  Future<Response> head(Uri url, {Map<String, String>? headers}) =>
      throw UnimplementedError();
  @override
  Future<Response> get(Uri url, {Map<String, String>? headers}) =>
      throw UnimplementedError();
  @override
  Future<Response> post(Uri url, {Map<String, String>? headers, Object? body}) =>
      throw UnimplementedError();
  @override
  Future<Response> put(Uri url, {Map<String, String>? headers, Object? body}) =>
      throw UnimplementedError();
  @override
  Future<Response> patch(Uri url, {Map<String, String>? headers, Object? body}) =>
      throw UnimplementedError();
  @override
  Future<Response> delete(Uri url, {Map<String, String>? headers, Object? body}) =>
      throw UnimplementedError();
  @override
  Future<String> read(Uri url, {Map<String, String>? headers}) =>
      throw UnimplementedError();
  @override
  void close() {}
}

class _IOClient extends BaseClient {
  @override
  Future<StreamedResponse> send(BaseRequest request) =>
      throw UnimplementedError();
}

Future<Response> head(Uri url, {Map<String, String>? headers}) =>
    throw UnimplementedError();
Future<Response> get(Uri url, {Map<String, String>? headers}) =>
    throw UnimplementedError();
Future<Response> post(Uri url, {Map<String, String>? headers, Object? body}) =>
    throw UnimplementedError();
Future<Response> put(Uri url, {Map<String, String>? headers, Object? body}) =>
    throw UnimplementedError();
Future<Response> patch(Uri url, {Map<String, String>? headers, Object? body}) =>
    throw UnimplementedError();
Future<Response> delete(Uri url, {Map<String, String>? headers, Object? body}) =>
    throw UnimplementedError();
Future<String> read(Uri url, {Map<String, String>? headers}) =>
    throw UnimplementedError();
