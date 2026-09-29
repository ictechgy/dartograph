import 'package:chopper/chopper.dart';

part 'chopper_client.chopper.dart';

/// 상대 base: 생성기가 문자열로 합치고 실행 시 클라이언트 base와 슬래시 결합한다.
@ChopperApi(baseUrl: '/todos')
abstract class TodoService extends ChopperService {
  /// 생성된 구현을 만든다.
  static TodoService create([ChopperClient? client]) => _$TodoService(client);

  /// 빈 경로 → `/todos`.
  @Get()
  Future<Response<String>> list();

  /// `/todos/{}`.
  @GET(path: '/{id}')
  Future<Response<String>> item(@Path() String id);

  /// 둘 다 슬래시가 없으면 `/`를 넣는다 → `/todos/done`.
  @Post(path: 'done')
  Future<Response<String>> done();
}

/// 절대 base: 생성된 URL이 절대 URL이라 클라이언트 base를 무시한다.
@ChopperApi(baseUrl: 'http://api.example.test/ch/')
abstract class AbsoluteChopperService extends ChopperService {
  /// 생성된 구현을 만든다.
  static AbsoluteChopperService create([ChopperClient? client]) =>
      _$AbsoluteChopperService(client);

  /// 둘 다 슬래시면 하나를 뗀다 → `/ch/ping`.
  @Get(path: '/ping')
  Future<Response<String>> ping();
}

/// base 없음.
@ChopperApi()
abstract class BareChopperService extends ChopperService {
  /// 생성된 구현을 만든다.
  static BareChopperService create([ChopperClient? client]) =>
      _$BareChopperService(client);

  /// 상대 경로도 클라이언트 base와 슬래시 결합한다 → base 앵커 `/items/{}`.
  @Delete(path: 'items/{id}')
  Future<Response<String>> remove(@Path() String id);
}
