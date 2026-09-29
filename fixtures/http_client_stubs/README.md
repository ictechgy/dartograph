# HTTP 클라이언트 스텁

`routes` 스캐너 테스트용 최소 API 스텁이다. 실제 패키지(http 1.6.0, dio 5.11.1,
retrofit 4.10.0, chopper 8.7.0)의 **라이브러리 URI와 선언 이름·계층**만 흉내 낸다 —
스캐너는 element의 `package:<이름>/` URI와 타입 계층으로 신원을 판정하므로 네트워크
없이(pub get 없이) 같은 판정을 검증할 수 있다. 동작(URL 결합)은 흉내 내지 않는다 —
그 의미는 실제 패키지로 실행한 오라클(`fixtures/http_routes/oracle/`)이 검증한다.
