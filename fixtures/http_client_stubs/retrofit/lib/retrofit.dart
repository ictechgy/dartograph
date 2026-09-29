// package:retrofit 4.10.0의 어노테이션 모양만 흉내 낸 스텁이다.
class HttpMethod {
  static const String GET = 'GET';
  static const String POST = 'POST';
  static const String PATCH = 'PATCH';
  static const String PUT = 'PUT';
  static const String DELETE = 'DELETE';
  static const String HEAD = 'HEAD';
  static const String OPTIONS = 'OPTIONS';
  static const String QUERY = 'QUERY';
}

class RestApi {
  const RestApi({this.baseUrl});
  final String? baseUrl;
}

class Method {
  const Method(this.method, this.path);
  final String method;
  final String path;
}

class GET extends Method {
  const GET(String path) : super(HttpMethod.GET, path);
}

class POST extends Method {
  const POST(String path) : super(HttpMethod.POST, path);
}

class PATCH extends Method {
  const PATCH(String path) : super(HttpMethod.PATCH, path);
}

class PUT extends Method {
  const PUT(String path) : super(HttpMethod.PUT, path);
}

class DELETE extends Method {
  const DELETE(String path) : super(HttpMethod.DELETE, path);
}

class HEAD extends Method {
  const HEAD(String path) : super(HttpMethod.HEAD, path);
}

class OPTIONS extends Method {
  const OPTIONS(String path) : super(HttpMethod.OPTIONS, path);
}

class QUERY extends Method {
  const QUERY(String path) : super(HttpMethod.QUERY, path);
}

class Path {
  const Path([this.value]);
  final String? value;
}

class Query {
  const Query(this.value);
  final String value;
}
