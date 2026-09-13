import 'dart:io';

/// 리터럴 URL: 네트워크 접근 없이는 확인할 수 없어 미판정이다.
const String corpusEndpoint = 'https://example.com/api/v1';

/// 리터럴 URL을 파싱한다.
Uri corpusHealth() => Uri.parse('http://127.0.0.1:8080/health');

/// 대상이 런타임에 정해지는 HTTP 클라이언트.
HttpClient corpusClient() => HttpClient();
