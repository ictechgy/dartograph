// package:dio 5.11.1의 API 모양만 흉내 낸 스텁이다.
class Response<T> {}

class BaseOptions {
  BaseOptions({this.baseUrl = '', this.method = 'GET'});
  String baseUrl;
  String method;
}

class Options {
  Options({this.method});
  String? method;
}

class RequestOptions {
  RequestOptions({this.path = '', this.baseUrl = '', this.method = 'GET'});
  String path;
  String baseUrl;
  String method;
  RequestOptions copyWith({String? path, String? baseUrl, String? method}) =>
      this;
}

class RequestInterceptorHandler {
  void next(RequestOptions options) {}
}

class Interceptor {
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {}
}

class Interceptors {
  void add(Interceptor interceptor) {}
}

abstract class Dio {
  factory Dio([BaseOptions? options]) => DioForNative(options);
  late BaseOptions options;
  Interceptors get interceptors;
  Future<Response<T>> get<T>(String path, {Object? data, Options? options});
  Future<Response<T>> getUri<T>(Uri uri, {Object? data, Options? options});
  Future<Response<T>> post<T>(String path, {Object? data, Options? options});
  Future<Response<T>> put<T>(String path, {Object? data, Options? options});
  Future<Response<T>> patch<T>(String path, {Object? data, Options? options});
  Future<Response<T>> delete<T>(String path, {Object? data, Options? options});
  Future<Response<T>> head<T>(String path, {Object? data, Options? options});
  Future<Response<T>> request<T>(String path, {Object? data, Options? options});
  Future<Response<T>> fetch<T>(RequestOptions requestOptions);
}

abstract mixin class DioMixin implements Dio {}

class DioForNative with DioMixin implements Dio {
  DioForNative([BaseOptions? options]) : options = options ?? BaseOptions();
  @override
  BaseOptions options;
  @override
  Interceptors get interceptors => Interceptors();
  @override
  Future<Response<T>> get<T>(String path, {Object? data, Options? options}) =>
      throw UnimplementedError();
  @override
  Future<Response<T>> getUri<T>(Uri uri, {Object? data, Options? options}) =>
      throw UnimplementedError();
  @override
  Future<Response<T>> post<T>(String path, {Object? data, Options? options}) =>
      throw UnimplementedError();
  @override
  Future<Response<T>> put<T>(String path, {Object? data, Options? options}) =>
      throw UnimplementedError();
  @override
  Future<Response<T>> patch<T>(String path, {Object? data, Options? options}) =>
      throw UnimplementedError();
  @override
  Future<Response<T>> delete<T>(
    String path, {
    Object? data,
    Options? options,
  }) => throw UnimplementedError();
  @override
  Future<Response<T>> head<T>(String path, {Object? data, Options? options}) =>
      throw UnimplementedError();
  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Options? options,
  }) => throw UnimplementedError();
  @override
  Future<Response<T>> fetch<T>(RequestOptions requestOptions) =>
      throw UnimplementedError();
}
