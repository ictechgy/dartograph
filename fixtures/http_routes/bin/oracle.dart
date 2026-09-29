// 모의 서버 오라클: 실제 http·dio·retrofit·chopper가 보낸 요청(method, path)을
// 127.0.0.1의 dart:io HttpServer에서 기록한다. 모든 클라이언트 요청은
// HttpOverrides 프록시 설정으로 이 서버에 도착하므로 외부 네트워크를 쓰지 않는다.
// 키는 routes 사실의 `symbol.usr`(그 요청을 만든 선언)다.
import 'dart:convert';
import 'dart:io';

import 'package:chopper/chopper.dart';
import 'package:dio/dio.dart';
import 'package:http_routes_fixture/api_wrapper.dart';
import 'package:http_routes_fixture/chopper_client.dart';
import 'package:http_routes_fixture/dio_client.dart';
import 'package:http_routes_fixture/http_client.dart';
import 'package:http_routes_fixture/retrofit_client.dart';

const _library = 'package:http_routes_fixture';

/// 시나리오 → 실행 함수다.
Map<String, Future<void> Function()> _scenarios() {
  Dio injected(String base) => Dio(BaseOptions(baseUrl: base));
  final chopper = ChopperClient(
    baseUrl: Uri.parse('http://api.example.test/api'),
  );
  return {
    '$_library/http_client.dart::httpLiteral': httpLiteral,
    '$_library/http_client.dart::httpConstInterpolation': () =>
        httpConstInterpolation(7),
    '$_library/http_client.dart::httpAdjacent': httpAdjacent,
    '$_library/http_client.dart::httpUriComponents': () =>
        httpUriComponents('api.example.test', 9),
    '$_library/http_client.dart::httpUriRelative': httpUriRelative,
    '$_library/http_client.dart::clientGet': clientGet,
    '$_library/http_client.dart::httpRequestSend': httpRequestSend,
    '$_library/http_client.dart::httpUnknownBase': () =>
        httpUnknownBase('http://api.example.test/prefix'),
    '$_library/http_client.dart::httpPartialSegment': () =>
        httpPartialSegment('report'),
    '$_library/http_client.dart::httpQueryTail': () => httpQueryTail('x'),
    '$_library/http_client.dart::httpDotSegments': httpDotSegments,
    '$_library/dio_client.dart::dioLiteralBase': () => dioLiteralBase(5),
    '$_library/dio_client.dart::dioTrailingSlash': dioTrailingSlash,
    '$_library/dio_client.dart::dioRelativeAfterSlash': dioRelativeAfterSlash,
    '$_library/dio_client.dart::dioConcatenation': dioConcatenation,
    '$_library/dio_client.dart::dioDoubleSlash': dioDoubleSlash,
    '$_library/dio_client.dart::dioRequestMethod': dioRequestMethod,
    '$_library/dio_client.dart::dioGetUri': dioGetUri,
    '$_library/dio_client.dart::UsersRepository.load': () =>
        UsersRepository(injected('http://api.example.test/api/')).load(3),
    '$_library/dio_client.dart::UsersRepository.profile': () =>
        UsersRepository(injected('http://api.example.test/api/')).profile(),
    '$_library/retrofit_client.dart::AbsoluteBaseApi.user': () =>
        AbsoluteBaseApi(Dio()).user(11),
    '$_library/retrofit_client.dart::AbsoluteBaseApi.me': () =>
        AbsoluteBaseApi(Dio()).me(),
    '$_library/retrofit_client.dart::AbsoluteBaseApi.create': () =>
        AbsoluteBaseApi(Dio()).create(),
    '$_library/retrofit_client.dart::RelativeBaseApi.order': () =>
        RelativeBaseApi(
          injected('http://api.example.test/ignored/'),
        ).order('o-1'),
    '$_library/retrofit_client.dart::RelativeBaseApi.removeCart': () =>
        RelativeBaseApi(
          injected('http://api.example.test/ignored/'),
        ).removeCart(4),
    '$_library/retrofit_client.dart::NoBaseApi.health': () =>
        NoBaseApi(injected('http://api.example.test/nb/')).health(),
    '$_library/retrofit_client.dart::NoBaseApi.settings': () =>
        NoBaseApi(injected('http://api.example.test/nb/')).settings(),
    '$_library/chopper_client.dart::TodoService.list': () =>
        TodoService.create(chopper).list(),
    '$_library/chopper_client.dart::TodoService.item': () =>
        TodoService.create(chopper).item('t1'),
    '$_library/chopper_client.dart::TodoService.done': () =>
        TodoService.create(chopper).done(),
    '$_library/chopper_client.dart::AbsoluteChopperService.ping': () =>
        AbsoluteChopperService.create(chopper).ping(),
    '$_library/chopper_client.dart::BareChopperService.remove': () =>
        BareChopperService.create(chopper).remove('b2'),
    '$_library/api_wrapper.dart::wrapperGet': () =>
        wrapperGet(ApiWrapper(injected('http://api.example.test/wb'))),
    '$_library/api_wrapper.dart::wrapperPost': () =>
        wrapperPost(ApiWrapper(injected('http://api.example.test/wb'))),
    '$_library/api_wrapper.dart::endpointDelete': () => endpointDelete(
      EndpointClient(injected('http://api.example.test/eb')),
      6,
    ),
  };
}

/// 모든 요청을 로컬 서버로 보내는 프록시 설정이다.
final class _LoopbackProxy extends HttpOverrides {
  _LoopbackProxy(this.port);

  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
}

Future<void> main(List<String> arguments) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final recorded = <Map<String, String>>[];
  server.listen((request) {
    recorded.add({
      'host': request.uri.host,
      'method': request.method,
      'path': request.uri.path,
    });
    request.response
      ..statusCode = 200
      ..write('ok');
    request.response.close();
  });
  final results = <String, Object>{};
  try {
    await HttpOverrides.runWithHttpOverrides(() async {
      for (final entry in _scenarios().entries) {
        recorded.clear();
        try {
          await entry.value();
          results[entry.key] = [...recorded];
        } on Object catch (error) {
          results[entry.key] = {'error': '$error'};
        }
      }
    }, _LoopbackProxy(server.port));
  } finally {
    await server.close(force: true);
  }
  final sorted = {
    for (final key in results.keys.toList()..sort()) key: results[key],
  };
  File(arguments.single).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(sorted)}\n',
  );
}
