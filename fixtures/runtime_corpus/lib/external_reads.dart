import 'dart:io';

/// 리터럴 URL 상수: 목적지를 받는 자리에 넘기지 않으므로 외부 자원이 아니다
/// (단순 선언·비교를 오탐하지 않는다는 규칙의 반례다).
const String corpusEndpoint = 'https://example.com/api/v1';

/// 리터럴 URL을 파싱한다: 목적지 자리이므로 프로브할 수 없어 미판정이다.
Uri corpusHealth() => Uri.parse('http://127.0.0.1:8080/health');

/// 대상이 런타임에 정해지는 HTTP 클라이언트: 목적지를 이름하지 못해 미판정이다.
HttpClient corpusClient() => HttpClient();
