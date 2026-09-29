# http_routes — `routes` 오라클 fixture

합성 Flutter/Dart HTTP 클라이언트다. package:http·dio·retrofit.dart·chopper와 선언된
래퍼(`http-wrappers.json`)의 각 base 결합 규칙을 시나리오 함수 하나씩으로 부른다.

- `lib/*.g.dart`·`lib/*.chopper.dart`는 pubspec에 고정한 retrofit_generator·
  chopper_generator로 만든 생성물이다. 규칙을 바꾸면 실제 패키지 복사본에서
  `dart run build_runner build`로 다시 만든다.
- `bin/oracle.dart`는 실제 패키지로 모든 요청을 127.0.0.1 임시 포트 서버에 모아
  `oracle/recorded.json`(키는 사실의 `symbol.usr`)을 쓴다. 실행은
  `tool/run-http-route-oracle.sh`(pub.dev 네트워크 필요)다.
- 기본 테스트는 네트워크 없이 `fixtures/http_client_stubs`로 해석해 커밋된 기록과
  대조한다(`test/index/route_oracle_test.dart`). 저장소 루트 `dart analyze`는 실제
  패키지를 해석하지 못하므로 `analysis_options.yaml`이 이 디렉터리를 뺀다.

결과와 규칙 근거는 [doc/HTTP-ROUTES.md](../../doc/HTTP-ROUTES.md)에 있다.
