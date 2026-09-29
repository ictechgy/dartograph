import 'package:dio/dio.dart';
import 'package:retrofit/retrofit.dart';

part 'retrofit_client.g.dart';

/// 어노테이션 인자로 쓰는 경로 상수.
abstract final class ApiPaths {
  /// 다른 선언의 상수 — analyzer 상수 평가로 읽는다.
  static const profile = '/me';
}

/// 절대 base: dio 연결로 base 경로가 앞에 붙는다(retrofit.dart 이중 규칙).
@RestApi(baseUrl: 'http://api.example.test/rv1')
abstract class AbsoluteBaseApi {
  /// 생성된 구현을 만든다.
  factory AbsoluteBaseApi(Dio dio) = _AbsoluteBaseApi;

  /// `/rv1/users/{}`.
  @GET('/users/{id}')
  Future<void> user(@Path('id') int id);

  /// 상수 경로 → `/rv1/me`.
  @GET(ApiPaths.profile)
  Future<void> me();

  /// 슬래시 없는 base 뒤 상대 경로는 그대로 붙는다(`/rv1items`).
  @POST('items')
  Future<void> create();
}

/// `/`로 시작하는 상대 base: dio base에 RFC 3986으로 해석된 뒤 경로가 붙는다.
@RestApi(baseUrl: '/rv2/')
abstract class RelativeBaseApi {
  /// 생성된 구현을 만든다.
  factory RelativeBaseApi(Dio dio) = _RelativeBaseApi;

  /// `/rv2/orders/{}`.
  @GET('/orders/{orderId}')
  Future<void> order(@Path() String orderId);

  /// `/rv2/carts/{}`.
  @DELETE('carts/{id}')
  Future<void> removeCart(@Path('id') int id);
}

/// base 없음: 주입된 dio의 base를 쓴다.
@RestApi()
abstract class NoBaseApi {
  /// 생성된 구현을 만든다.
  factory NoBaseApi(Dio dio) = _NoBaseApi;

  /// base 앵커 `/health`.
  @GET('/health')
  Future<void> health();

  /// 미상 base 뒤 상대 경로는 모호하다.
  @PUT('settings')
  Future<void> settings();
}
