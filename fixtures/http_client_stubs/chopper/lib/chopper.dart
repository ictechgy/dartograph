// package:chopper 8.7.0의 어노테이션·클라이언트 모양만 흉내 낸 스텁이다.
class HttpMethod {
  static const String Get = 'GET';
  static const String Query = 'QUERY';
  static const String Post = 'POST';
  static const String Put = 'PUT';
  static const String Delete = 'DELETE';
  static const String Patch = 'PATCH';
  static const String Head = 'HEAD';
  static const String Options = 'OPTIONS';
}

final class ChopperApi {
  const ChopperApi({this.baseUrl = ''});
  final String baseUrl;
}

final class Path {
  const Path([this.name]);
  final String? name;
}

sealed class Method {
  const Method(this.method, {this.path = ''});
  final String method;
  final String path;
}

final class GET extends Method {
  const GET({String path = ''}) : super(HttpMethod.Get, path: path);
}

final class Get extends GET {
  const Get({super.path});
}

final class POST extends Method {
  const POST({String path = ''}) : super(HttpMethod.Post, path: path);
}

final class Post extends POST {
  const Post({super.path});
}

final class PUT extends Method {
  const PUT({String path = ''}) : super(HttpMethod.Put, path: path);
}

final class Put extends PUT {
  const Put({super.path});
}

final class DELETE extends Method {
  const DELETE({String path = ''}) : super(HttpMethod.Delete, path: path);
}

final class Delete extends DELETE {
  const Delete({super.path});
}

final class PATCH extends Method {
  const PATCH({String path = ''}) : super(HttpMethod.Patch, path: path);
}

final class Patch extends PATCH {
  const Patch({super.path});
}

class Response<T> {}

abstract class ChopperService {
  ChopperClient? client;
}

class ChopperClient {
  ChopperClient({Uri? baseUrl, Iterable<ChopperService>? services});
  Future<Response<T>> get<T>(Uri url) => throw UnimplementedError();
  Future<Response<T>> send<T>(Object request) => throw UnimplementedError();
}
