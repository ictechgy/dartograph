# HTTP 경계 생산자 — `routes`와 `impact --format language-traversal`

_기록: 2026-09-29 · 상태: 0.16.0 발행 대상 · 계약 정본: isthmus
[GRAPH-EXCHANGE "HTTP 경계"](https://github.com/ictechgy/isthmus/blob/main/docs/GRAPH-EXCHANGE.md),
[HTTP-WRAPPERS](https://github.com/ictechgy/isthmus/blob/main/docs/HTTP-WRAPPERS.md),
[LANGUAGE-TRAVERSAL](https://github.com/ictechgy/isthmus/blob/main/docs/LANGUAGE-TRAVERSAL.md),
[TRACE](https://github.com/ictechgy/isthmus/blob/main/docs/TRACE.md)_

dartograph는 isthmus http 도메인의 **호출 측**(Flutter/Dart 클라이언트) 생산자다.
`routes --role client`가 `route-call` 사실을, `impact --format language-traversal`이
isthmus `trace`가 호출부에서 클라이언트 영향 심볼로 이어 가는 역방향 순회 문서를 낸다.
두 문서는 같은 id 공간(dartograph 그래프 선언 ID)을 쓴다.

## `routes --role client`

```sh
dartograph routes --role client [--format json] [--wrappers http-wrappers.json] \
  [--include-tests] [--service <name>] [--project <shared-root>] <package-root>
```

- 문서: bridge-facts v1, `platform: "dart"`, `target: "http"`, `roles: ["client"]`,
  `sourceSets.tests`(`excluded` 기본, `--include-tests`면 `included`), 선택 `service`.
  사실이 0건이어도 target은 `http`다(스캔했으나 호출 없음).
- 스캔: `impact`와 같은 analyzer 해석 유닛(`lib`·`bin`·`example`·`test`·
  `integration_test`)이다. 라이브러리 신원은 element의 라이브러리 URI(`package:dio/…`)와
  타입 계층으로만 판정한다 — 프로젝트의 같은 이름 함수는 호출로 보지 않는다.
- `symbol.usr`: 호출을 감싸는 그래프 선언의 dartograph ID(생성자·지역 함수 안이면 바깥
  클래스·메서드)로, `impact`의 관계 수집기가 간선 출발점으로 쓰는 소유자와 같은 규칙이다.
  **같은 `<package-root>`로 실행한 `impact`의 정점 ID와 같다**(`--project`는 위치 경로만
  바꾼다). 선언을 해석하지 못하면 usr를 생략하고 어휘적 `qualifiedName`만 싣고
  `missing-route-usrs:`로 센다 — 신원을 지어내지 않는다.
- `location`: 호출식이 시작하는 줄과 1-based UTF-8 byte 열. retrofit.dart·chopper는
  메서드 어노테이션(`@GET`) 위치다.
- dynamic 사실은 `channel: null`이다 — 원문 식은 URL 리터럴의 userinfo·query를 담을 수
  있어 싣지 않는다. 증명한 리터럴 접두사만 마스킹한 `channelPrefix`로 싣는다.
- `baseRef`: dio 수신 객체가 필드·최상위 변수면 그 선언 ID다(workspace 매니페스트의
  `match.baseRefs`에 쓸 수 있는 안정 id).

### 라이브러리 규칙과 확인한 소스

| 라이브러리(확인 버전) | 인식 | base 결합 | 근거 |
|---|---|---|---|
| package:http 1.6.0 | 최상위 `get`·`post`·`put`·`patch`·`delete`·`head`·`read`·`readBytes`, `Client`(구현 타입 포함) 같은 이름 메서드, `BaseRequest` 하위 타입 생성자(`Request('PATCH', uri)`) | base 없음. `Uri.parse` 문자열은 host 뒤 경로가 root, 앞 보간 뒤 `/`면 base. `Uri.https`·`Uri.http`의 경로 인자는 host가 동적이어도 root(authority에 `/`가 오면 `FormatException`) | `lib/http.dart`, Dart SDK `Uri` 동작(아래 표) |
| dio 5.11.1 | `Dio` 동사 메서드와 `*Uri` 변형, `request`/`requestUri`의 `Options(method:)`(dio가 대문자로 바꿈) | **단순 연결**: `path`가 `http:`·`https:`로 시작하지 않으면 `baseUrl + path`, `:/`가 정확히 하나면 그 뒤의 `//`를 `/`로 바꾼 다음 `Uri.parse(url).normalizePath()` | `lib/src/options.dart` `RequestOptions.uri`, `lib/src/dio_mixin.dart` `checkOptions`·`Options.compose` |
| retrofit 4.10.0 / retrofit_generator 10.2.11 | `@RestApi` 클래스의 `Method` 하위 어노테이션(`@GET`…`@OPTIONS`, `@Method`), `@Path` | **이중 규칙**: ① `_combineBaseUrls(dio.options.baseUrl, baseUrl)` — 어노테이션 base가 절대면 그대로, 상대면 dio base에 RFC 3986 `resolveUri`, 비면 dio base ② 경로는 `@Path` `replaceAll` 치환 후 **dio 단순 연결** | `lib/src/generator.dart` `_generateCombineBaseUrlsMethod`·`_generatePath`·`compose(...).copyWith(baseUrl:)` |
| chopper 8.7.0 / chopper_generator 8.7.0 | `@ChopperApi` 클래스의 `Method` 하위 어노테이션(`@GET`/`@Get`…), `@Path`(`replaceFirst`) | **이중 규칙**: ① 생성 시 `_generateUrl`이 base·경로 문자열을 합침(둘 다 `/` 없으면 `/` 삽입, 둘 다 있으면 하나 제거, 그 밖은 `//`→`/`) ② 실행 시 `Request.buildUri`가 절대 URL이 아니면 `ChopperClient.baseUrl`과 슬래시 결합(`rightStrip('/') + '/' + leftStrip('/')`) | chopper_generator `lib/src/generator.dart` `_generateUrl`, chopper `lib/src/request.dart` `buildUri`·`_mergeUri` |

isthmus 계약표는 retrofit.dart base를 "RFC 3986 방식"으로 적는다. 소스로 확인한 결과
RFC 3986은 **어노테이션 base를 dio base에 해석하는 첫 단계에만** 쓰이고, 메서드 경로는 dio
단순 연결로 붙는다. 그래서 `@RestApi(baseUrl: 'http://h/rv1')` + `@GET('/users/{id}')`는
`/users/{}`(RFC 3986)가 아니라 `/rv1/users/{}`이고, `@POST('items')`는 `/rv1items`다(오라클
기록). dartograph는 소스 동작을 따른다.

Dart SDK `Uri` 동작(3.13.3 실행 확인): `Uri.parse`는 점 세그먼트를 지우고 퍼센트 인코딩을
대문자 hex로 정규화하며 unreserved를 디코드한다. `Uri.https(host, path)`의 경로는 인코딩
전 값이라 `%`·`?`·`#`도 문자 그대로 인코딩하고(`%2f` → `%252f`), `/` 없는 경로에는 `/`를
붙인다.

### 해석과 증명

- 문자열: 리터럴·인접 문자열·보간·`+` 연결, analyzer 상수 평가(`const`, 파일 밖·패키지
  상수 포함), 초기식이 있는 final 최상위 변수·static·인스턴스 필드, 함수 안에서 다시
  대입되지 않는 지역 변수를 따라간다. 그 밖은 값 조각이다.
- 보간은 세그먼트 전체를 채울 때만 `{}`다. 세그먼트 일부·한 세그먼트에 둘 이상이면 dynamic과
  `channelPrefix`다. 끝에 붙은 지역 변수가 `?`로 시작하거나 빈 값뿐이면 query 꼬리로 뗀다
  (`queryTailStripped`).
- dio base: 수신 식이 `Dio(BaseOptions(baseUrl: 리터럴))`(인라인·변수 초기식·cascade
  `..options.baseUrl =`)일 때만 리터럴 base다. 프로젝트 어디서든 그 변수·`options`·
  `baseUrl`·`method`를 다시 쓰거나, 누구의 것인지 모르는 쓰기가 있으면 모든 리터럴 base를
  버린다(base 앵커). 미상 base 뒤 경로가 `/`로 시작하면 base, 상대면 dynamic과
  `ambiguous-base-join:`이다. 미상 base 뒤 `//`로 시작하는 경로는 base의 끝 `/`에 따라
  결과가 달라 모호하다. base URL에는 scheme 뒤 `:/`가 하나뿐이라고 가정한다.
- retrofit.dart: 어떤 생성자 호출이 `baseUrl`을 넘기면(`Api(dio, baseUrl: …)`) 어노테이션
  base를 믿지 않는다.
- `RequestOptions`의 `path`·`baseUrl`·`method`를 쓰거나 그 인자로 `copyWith`하는 코드가
  있으면(인터셉터 등, 생성 파일 제외) `url-rewrite-interceptors:`다. `baseUrl` 재작성은
  리터럴 base를, `path` 재작성은 템플릿을(dynamic), `method` 재작성은 동사를
  (`methodDynamic`) 버린다.
- 동사: package:http `Request`는 대문자 동사 리터럴만 동사다. dio는 대문자로 바꾼 값이
  동사면 동사다. 동사를 모르면 `methodDynamic: true`다.

### 래퍼 선언(`http-wrappers` v1)의 Dart 규칙

`"language": "dart"` 항목만 적용한다.

- `owner`: 생성자·메서드는 소유 타입의 dartograph 선언 ID
  (`package:app/api.dart::ApiClient`), 최상위 함수는 라이브러리 ID(`package:app/net.dart`,
  `lib/` 밖이면 `project:bin/tool.dart`). 모양이 맞지 않으면 선언 오류(64)다.
- `name`: 함수·메서드 이름, 생성자면 생성자 이름이고 이름 없는 생성자는 `new`다.
- 인자: `label`은 이름 붙은 인자, `index`는 작성 순서의 인자 위치(이름 붙은 인자 포함,
  그 자리가 이름 붙은 인자면 쓰지 않음)다. `methodEnum`은 enum 상수 이름과, 선언에 이름이
  있는 static 상수를 case로 본다. 그 밖의 상수 문자열은 값이다.
- 선언된 래퍼 본문의 dynamic 호출은 내지 않는다(래퍼 호출 사실이 대신한다). 선언되지 않은
  함수가 매개변수(또는 그 속성)를 URL 앞머리로 흘려보내면 `http-wrapper-undeclared:`로 센다.

### limitation

| 접두사 | 측 | 뜻 |
|---|---|---|
| `route-call-coverage:` | 호출 측 | 모델링하지 않은 API(dio `fetch`·`download`, dart:io `HttpClient`, chopper `ChopperClient` 직접 호출) 호출 수, 해석되지 않은 HTTP 클라이언트 패키지 import 수(pub get 필요) |
| `ambiguous-base-join:` | 호출 측 | 미상 dio base 뒤 상대 경로 수 |
| `url-rewrite-interceptors:` | 호출 측 | dio 요청을 다시 쓰는 위치 수 |
| `http-wrapper-unresolved:` | 호출 측 | 호출이 0건인 dart 래퍼 선언(`wrappers[n]`) |
| `http-wrapper-undeclared:` | 호출 측 | 선언되지 않은 래퍼 싱크 수 |
| `generated-client-unscanned:` | 호출 측 | 서비스 선언(retrofit.dart·chopper) 없이 HTTP 호출을 담은 생성 파일 수 |
| `missing-route-usrs:` | 체인 전용 | usr가 없는 사실 수 |

증명할 수 있는 요청 범위가 있는 호출 측 한계가 없어 `limitationScopes`는 내지 않는다
(스코프 없는 한계는 문서 전체 효과). 스코프 규칙 자체는 벡터로 검증한다.

## 공유 적합성 벡터

`fixtures/isthmus_conformance/`에 isthmus `76b6141`의 `http-template`·`url-compose`·
`http-limitation-scope`·`http-dispatch`를 벤더링하고 `conformance.lock`에 커밋과 sha256을 적었다.
`test/index/route_conformance_test.dart`가 lock을 대조하고 `producer`·
`producer:dartograph` 케이스를 모두 실행한다(모르는 규칙이면 실패): http-template 33,
url-compose 41(`wrapper.location`은 실제 스캐너로), http-limitation-scope 27 — **101/101
통과**. `producer:kartograph`(Spring)·`producer:openapi` 케이스는 서버 변환이라 적용하지
않는다. 벡터의 `dio-concat` 결합은 dio 규칙으로 실행한다. `http-dispatch`의 생산자
케이스(`dispatch.validate` 18)는 route-decl의 `order` 검증이라 route-decl을 내지 않는
dartograph에는 적용하지 않고, 테스트가 그 분류만 고정한다.

## 모의 서버 오라클

`fixtures/http_routes/`는 각 라이브러리·규칙을 부르는 합성 Flutter/Dart 클라이언트다.
`tool/run-http-route-oracle.sh`가 임시 복사본에 실제 패키지를 받고(pub.dev 네트워크)
`bin/oracle.dart`로 모든 요청을 127.0.0.1 임시 포트의 dart:io `HttpServer`에 모은다
(HttpOverrides 프록시 — 외부 요청 없음). 같은 복사본을 실제 패키지로 해석한 routes 사실을
`tool/route_oracle.dart`로 대조한다(root는 전체 경로, base는 세그먼트 경계 꼬리, `{}`는
비어 있지 않은 세그먼트, authority는 요청 host). 기본 CI는 네트워크를 쓰지 않는다 —
`test/index/route_oracle_test.dart`가 커밋된 기록(`oracle/recorded.json`)을 스텁
(`fixtures/http_client_stubs`, 라이브러리 URI·선언 계층만 흉내)으로 해석한 사실과 대조한다.

2026-09-29 기록(Dart 3.13.3, http 1.6.0, dio 5.11.1, retrofit 4.10.0 +
retrofit_generator 10.2.11, chopper 8.7.0 + chopper_generator 8.7.0): **35개 시나리오,
일치 32 · dynamic 3 · 불일치 0**.

| 규칙 | 시나리오 | 기록 요청 | route-call 사실 | 결과 |
|---|---|---|---|---|
| http 리터럴·query 꼬리 | `httpLiteral` | `GET /v1/items` | `GET /v1/items` root | 일치 |
| http 상수 보간 | `httpConstInterpolation` | `POST /v1/items/7` | `POST /v1/items/{}` root | 일치 |
| http 인접 문자열 | `httpAdjacent` | `PUT /v1/settings` | `PUT /v1/settings` root | 일치 |
| `Uri.http` 동적 host | `httpUriComponents` | `DELETE /v1/items/9` | `DELETE /v1/items/{}` root | 일치 |
| `Uri.http` 상대 경로 | `httpUriRelative` | `HEAD /v2/users` | `HEAD /v2/users` root | 일치 |
| `Client.get`·지역 변수 | `clientGet` | `GET /v1/profile` | `GET /v1/profile` root | 일치 |
| `Request` 동사 | `httpRequestSend` | `PATCH /v1/profile/name` | `PATCH /v1/profile/name` root | 일치 |
| 미상 base | `httpUnknownBase` | `GET /prefix/v1/status` | `GET /v1/status` base | 일치 |
| 부분 세그먼트 보간 | `httpPartialSegment` | `GET /files/report.json` | dynamic, prefix `/files/` | dynamic |
| query 꼬리 지역 변수 | `httpQueryTail` | `GET /v1/search` | `GET /v1/search` root | 일치 |
| 점 세그먼트 | `httpDotSegments` | `GET /v1/b` | `GET /v1/b` root | 일치 |
| **dio 단순 연결** | `dioLiteralBase` | `GET /v1/users/5` | `GET /v1/users/{}` root | 일치 |
| dio `//` 축약 | `dioTrailingSlash` | `POST /v2/orders` | `POST /v2/orders` root | 일치 |
| dio base `/` 뒤 상대 | `dioRelativeAfterSlash` | `PUT /v2/carts` | `PUT /v2/carts` root | 일치 |
| **dio 문자열 연결** | `dioConcatenation` | `GET /v4health` | `GET /v4health` root | 일치 |
| dio 경로 안 `//` | `dioDoubleSlash` | `DELETE /v1/a/b` | `DELETE /v1/a/b` root | 일치 |
| dio `Options.method` 대문자화 | `dioRequestMethod` | `PATCH /v1/profile` | `PATCH /v1/profile` root | 일치 |
| dio `getUri` | `dioGetUri` | `GET /v1/raw` | `GET /v1/raw` root | 일치 |
| dio 주입(미상 base) | `UsersRepository.load` | `GET /api/users/3` | `GET /users/{}` base | 일치 |
| dio 미상 base 상대 경로 | `UsersRepository.profile` | `GET /api/profile` | dynamic(`ambiguous-base-join:`) | dynamic |
| **retrofit 이중 규칙**(절대 base) | `AbsoluteBaseApi.user` | `GET /rv1/users/11` | `GET /rv1/users/{}` root | 일치 |
| retrofit 상수 경로 | `AbsoluteBaseApi.me` | `GET /rv1/me` | `GET /rv1/me` root | 일치 |
| **retrofit 이중 규칙**(연결) | `AbsoluteBaseApi.create` | `POST /rv1items` | `POST /rv1items` root | 일치 |
| retrofit 상대 base(`/rv2/`) | `RelativeBaseApi.order` | `GET /rv2/orders/o-1` | `GET /rv2/orders/{}` root | 일치 |
| retrofit 상대 base + 상대 경로 | `RelativeBaseApi.removeCart` | `DELETE /rv2/carts/4` | `DELETE /rv2/carts/{}` root | 일치 |
| retrofit base 없음 | `NoBaseApi.health` | `GET /nb/health` | `GET /health` base | 일치 |
| retrofit base 없음 + 상대 경로 | `NoBaseApi.settings` | `PUT /nb/settings` | dynamic(`ambiguous-base-join:`) | dynamic |
| chopper 빈 경로 | `TodoService.list` | `GET /api/todos` | `GET /todos` base | 일치 |
| chopper `@Path` | `TodoService.item` | `GET /api/todos/t1` | `GET /todos/{}` base | 일치 |
| chopper `/` 삽입 | `TodoService.done` | `POST /api/todos/done` | `POST /todos/done` base | 일치 |
| chopper 절대 base | `AbsoluteChopperService.ping` | `GET /ch/ping` | `GET /ch/ping` root | 일치 |
| chopper base 없음 | `BareChopperService.remove` | `DELETE /api/items/b2` | `DELETE /items/{}` base | 일치 |
| 함수 래퍼 기본 동사 | `wrapperGet` | `GET /wb/w/items` | `GET /w/items` base | 일치 |
| 함수 래퍼 enum 동사 | `wrapperPost` | `POST /wb/w/orders` | `POST /w/orders` base | 일치 |
| 생성자 래퍼 | `endpointDelete` | `DELETE /eb/e/items/6` | `DELETE /e/items/{}` base | 일치 |

## `impact --format language-traversal`

```sh
dartograph impact --format language-traversal [--direction dependents|dependencies] \
  [--roots-from <file|->] [--revision <rev>] [--generated-at <instant>] \
  [--project <shared-root>] [--incremental <dir>] [--workspace] <package-root> [<root-usr>...]
```

- 한 번의 순회로 모든 root(위치 인자와 `--roots-from`의 JSON 문자열 배열 또는
  bridge-facts 문서의 `symbol.usr`, 입력 순서·중복 제거)를 처리한다. `dependents`(기본)는
  호출자·참조자, `dependencies`는 root가 쓰는 쪽이다. 간선은 `impact`의 사용 간선이다.
- `reached[]`는 자기 자신이 아닌 root에서 닿은 모든 정점이다. `roots`는 닿는 모든 root
  인덱스(64개까지, 넘으면 `rootsTruncated`), `depth`·`via`는 가장 가까운 root 기준의
  최단 경로 목격이다(동률이면 id가 작은 선행 정점). 다른 root에서 닿은 root는 자기
  인덱스 없이 싣고, 그 depth는 두 번째로 가까운 root 기준이다(계약의 기준값·목격 규칙).
- 근거 등급: analyzer가 해석한 간선은 `direct`다. 재정의 멤버에서 기반 멤버로 가는 동적
  디스패치(역방향 — 기반 멤버를 부르는 호출이 이 구현으로 갈 수 있음, 정방향은 반대)는
  `candidate` 간선(`relationships`의 `dispatch`)이다. 값은 root마다 가장 강한 등급의
  최솟값이다. 주입된 구현의 전체 흐름을 증명하지 않으므로 `bound`는 내지 않는다.
- `unresolvedCalls`와 `dispatch`는 싣지 않는다 — 그래프가 동적 수신자·함수 값·콜백
  호출을 세지 않아 완전한 신고를 선언할 수 없다(isthmus는 "알 수 없음"으로 읽는다). 모든
  도달 정점에 `evidence`를 실어 근거 등급 분류는 선언한다.
- `symbol.location`은 문서 `project` 기준 경로와 줄이다. 그래프 정점의 열은 UTF-16
  단위라 싣지 않는다.
- `revision`: `--revision`, 없으면 `<package-root>`에 커밋되지 않은·추적되지 않은 변경이
  없을 때만 git HEAD, 그 밖은 생략. `graphRevision`: 정점(id·종류 표시)과 간선의
  `sha256:` 내용 해시(위치 제외)라 정·역방향 문서가 같은 값을 낸다.
- root가 그래프 ID와 정확히 같지 않으면 `symbol` 없이 싣고 `root-not-found:`,
  `truncationReasons: ["root-not-found"]`와 함께 문서를 출력한 뒤 64로 끝난다. 제어 문자
  (C0·DEL·C1·U+2028·U+2029)나 짝 없는 서러게이트가 든 root·`--revision`, root 없음, 이
  형식이 받지 않는 `impact` 옵션은 문서 없이 64다.
- 검증: `test/analysis/language_traversal_test.dart`가 무작위 그래프 60개에서 한 번
  순회를 root별 무차별 BFS(roots·depth·evidence·via 간선·정렬)와 대조하고, 계약의 두
  예시를 손으로 적은 기대값으로 확인한다.

## isthmus 왕복(e2e)

isthmus `78d3dee`를 임시 디렉터리에서 빌드해 확인했다(2026-09-29).

- `isthmus check dart.http.json server.http.json`: 합성 서버 route-decl 문서와 같은
  `project`로 입력 오류 없이 조인했다. `matchedRoutes` 4, 선언 없는 root 호출은
  `route-call-without-decl` error, base 호출은 suffix 후보·`-unverified`, 동사만 다른
  호출은 `route-method-mismatch`, dynamic 호출 4건은 `unjoined-dynamic-route-calls`였다.
- `isthmus trace`: platform `dart`, role `reverse`의 `language-traversal` 분석을 받아
  `GET /v1/users/{}`·`GET /rv1/users/{}` 호출부에서 클라이언트 영향 심볼(`direct`)로
  이었다. 분석 요약은 `evidenceReported: true`, `unresolvedCallsReported: false`,
  `rootProvenance: complete`였고 revision이 context와 같아 신선도 gap이 없었다.
- isthmus 쪽 변경은 필요하지 않았다.
