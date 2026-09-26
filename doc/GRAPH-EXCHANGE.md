# GRAPH-EXCHANGE — dartograph bridge-facts 생산자 스펙

`dartograph bridges`가 내보내는 `bridge-facts` JSON 문서의 공개 계약이다. 이 문서는
**생산자 측 계약**이다 — dartograph가 어떤 필드를 어떤 의미로 채우는지를 정의한다.
문서를 소비해 언어 간 채널을 조인하는 계약(여러 문서의 `project`·`channel`·`method`
정확 일치 규칙)의 정본은 isthmus의
[GRAPH-EXCHANGE](https://github.com/ictechgy/isthmus/blob/main/docs/GRAPH-EXCHANGE.md)다.

핵심 경계: bridge-facts는 **소스에서 관측된 사실**이지 실행 증명이 아니다.
`method-invoke`가 있다고 그 호출이 실행된다는 증명이 아니고, 채널 이름이 같다고 두
플랫폼이 실제로 통신한다는 인과 증명도 아니다. 조인은 관측된 문자열의 일치다.

## 문서 봉투

`bridges --format json`이 출력하는 최상위 객체다. JSON 키는 재귀적으로 코드포인트
사전순 정렬이고 들여쓰기 2칸, 마지막 줄개행으로 끝난다.

| 키 | 타입 | 의미 |
|---|---|---|
| `format` | string | 항상 `"bridge-facts"` |
| `version` | int | `1`(MethodChannel) 또는 `2`(--messages/--events) |
| `tool` | object | `{"name": "dartograph", "version": "<semver>"}` — 낸 도구와 버전 |
| `generatedAt` | string | UTC ISO-8601 밀리초 — 문서 추출 시각이라 출력 결정성 대상이 아니다 |
| `platform` | string | 항상 `"dart"` |
| `target` | string\|null | 사실이 하나라도 있으면 `"flutter"`, 없으면 `null` |
| `project` | string | 조인 키 — 같은 조인에 들어가는 모든 문서가 문자열 정확 일치해야 한다 |
| `transport` | string | version 2만: `"basic-message-channel"` 또는 `"event-channel"` |
| `facts` | array | 아래 fact 객체 목록 — 결정적 정렬 |
| `limitations` | array | 분석 한계 문자열 목록 |

`generatedAt`은 파일 수정 시각이나 compiler index 시각이 아니다. v1·v2 공유 계약의
선택적 `sourceModifiedAt`은 읽은 source의 최신 filesystem mtime을 관찰했을 때만 쓰며,
dartograph는 현재 이 값을 측정하지 않으므로 생략한다. 오래된 archive mtime을 추출 시각으로
바꾸거나, 추출 시각을 앱 빌드·실행·분석 완전성의 근거로 해석하지 않는다.
[kartograph 0.12.0 이하](https://github.com/ictechgy/kartograph/blob/v0.12.0/index/src/main/kotlin/dev/kartograph/index/BridgeFactScanner.kt)의
기본 `generatedAt`은 source mtime이므로 생산자 간 시각 차이를
곧바로 빌드 노후화로 해석하지 않는다. 소비자가 producer 버전으로 시각을 추측해 교체해서도 안 된다.

## Fact 객체

| 키 | 타입 | 의미 |
|---|---|---|
| `kind` | string | 아래 종류 표 |
| `channel` | string | 정적으로 해석된 채널 이름. 동적이면 원래 표현식 텍스트 |
| `method` | string? | 메서드 이름(v1 `method-invoke`만 해당). 없으면 키 자체가 없다 |
| `dynamic` | bool | 채널·메서드 이름을 정적으로 해석하지 못했으면 `true` |
| `channelPrefix` | string? | `dynamic` 채널에서 AST가 증명한 비어 있지 않은 선행 literal interpolation — 후보 근거일 뿐 완전한 런타임 주소가 아니다 |
| `symbol` | string? | 감싸는 선언의 어휘적 `Class.member` 이름 — 컴파일러 USR이 아니다. 귀속을 지원하지 않는 선언에서는 키가 없다 |
| `location` | object | `{"path": <프로젝트 상대 경로>, "line": <1-based>, "column": <1-based UTF-8 byte column>}` |

### 종류와 버전

| version | 명령 | `kind` | `transport` |
|---|---|---|---|
| 1 | `bridges` (기본) | `channel-create`, `method-invoke` | (키 없음) |
| 2 | `bridges --messages` | `message-send` | `basic-message-channel` |
| 2 | `bridges --events` | `stream-listen` | `event-channel` |

- `--messages`와 `--events`는 서로 다른 문서다 — 함께 쓰면 usage(64), 두 문서가
  필요하면 두 번 실행한다.
- `message-send`는 실제 `send` 호출만 센다 — 채널 생성·MethodChannel의 `method`
  필드를 만들지 않는다.
- `stream-listen`은 정적으로 식별된 `receiveBroadcastStream` 호출을 반환 스트림의
  소비 여부와 무관하게 기록한다 — 호출 실행·리스너 부착·활성 구독·이벤트 수신의
  증명이 아니다.

### 정렬

`facts`는 `location.path` → `kind` → `channel:method` 순으로 정렬된다. `generatedAt`
을 제외한 모든 필드는 같은 입력에 같은 바이트를 낸다.

## `project` 조인 키

조인은 `project` 문자열의 **정확 일치**(fail-closed)다 — 어긋나면 조인되지 않는다.
기준 결정 우선순위:

1. `--project <shared-root>` — 스캔 범위는 `<package-root>` 그대로지만 `project`와
   `location.path`가 `<shared-root>` 기준이 된다(포함 관계·realpath 검증, 아니면 64).
2. pubspec의 `resolution: workspace` — `workspace:` 키를 가진 가장 가까운 조상
   pubspec 디렉터리(pub workspace 루트)를 자동 사용한다.
3. 스캔 루트.

감지 실패는 폴백 + limitation(`pub-workspace-root-not-found`,
`pub-workspace-pubspec-unparsed`, `pub-workspace-member-not-listed`)으로 남긴다.
문서 생산 후 `project`를 손으로 고쳐 쓰는 것은 provenance를 깨므로 금지다.

## limitations

관측 한계는 문서 안에 남는다 — 소비자는 이 목록으로 출력의 공백을 판단한다.

| limitation | 의미 |
|---|---|
| `missing-caller-symbols` | 귀속을 지원하지 않는 선언에서 난 호출 — 위치는 있고 `symbol`은 없다 |
| `empty-bridge-names: N` | 빈 채널·메서드 이름 N건은 그 fact만 건너뛰었다 |
| `dynamic-channel-names: N` / `dynamic-method-names: N` / `dynamic-basic-message-channel-names: N` / `dynamic-event-channel-names: N` | 정적 해석 불가 이름 N건 |
| `invalid-method-invocations: N` | 미귀속·잘못된 형태의 invokeMethod 호출 N건 |
| `unresolved-stream-listens: N` | EventChannel로 입증되지 않은 수신 후보 N건 |
| `unscanned-ffi-interop: N` | dart:ffi·package:jni 계열 import를 가진 소스 N개 — 채널 조인 범위 밖 |
| `flutter-services-provenance-unverified:` | package_config가 `package:flutter/services.dart` 출처를 검증하지 못했다 |
| `flutter-services-reexports: N` | re-export로 들어온 services import N건 — 직접 import만 provenance로 쓴다 |
| `conditional-flutter-services-imports: N` | 조건부 지시문의 services import N건 |
| `pub-workspace-*` | workspace 감지 폴백 — `project` 기준이 스캔 루트로 내려갔다 |

## 예제

```json
{
  "facts": [
    {
      "channel": "com.example/camera",
      "dynamic": false,
      "kind": "channel-create",
      "location": {
        "column": 17,
        "line": 3,
        "path": "lib/camera_bridge.dart"
      },
      "symbol": "CameraBridge.channel"
    },
    {
      "channel": "com.example/camera",
      "dynamic": false,
      "kind": "method-invoke",
      "location": {
        "column": 12,
        "line": 7,
        "path": "lib/camera_bridge.dart"
      },
      "method": "takePhoto",
      "symbol": "CameraBridge.capture"
    },
    {
      "channel": "prefix + suffix",
      "channelPrefix": "com.example/",
      "dynamic": true,
      "kind": "method-invoke",
      "location": {
        "column": 5,
        "line": 15,
        "path": "lib/dynamic.dart"
      },
      "method": "ping"
    }
  ],
  "format": "bridge-facts",
  "generatedAt": "2026-09-18T09:30:00.000Z",
  "limitations": [
    "missing-caller-symbols: some invocations have source locations but no supported enclosing declaration name"
  ],
  "platform": "dart",
  "project": "camera-app",
  "target": "flutter",
  "tool": {
    "name": "dartograph",
    "version": "0.14.0"
  },
  "version": 1
}
```

대응하는 소스:

```dart
import 'package:flutter/services.dart';

class CameraBridge {
  static const channel = MethodChannel('com.example/camera');

  Future<void> capture() => channel.invokeMethod('takePhoto');
}
```

- 두 fact가 같은 `channel`을 공유한다 — isthmus는 이 문자열과 `project`로 네이티브
  측 문서와 조인한다.
- 세 번째 fact는 `dynamic: true`다 — `channel`은 원래 표현식 텍스트이고
  `channelPrefix`가 후보 근거다. 이 채널이 `com.example/...`로 조인된다는 보장은
  없다(런타임 주소가 아니다).
- `symbol`이 없는 fact는 `missing-caller-symbols`로 집계된다 — 사실을 버리지
  않는다.

## persistence 문서 (`schema`)

`dartograph schema --format json`은 같은 봉투의 버전 1 문서를 isthmus persistence
도메인(코드가 SQL 스키마 객체를 이름으로 참조하는 경계)용으로 낸다. 조인·진단 규칙의
정본은 isthmus GRAPH-EXCHANGE의 `target: "persistence"` 절이다.

- `platform`은 `"dart"`, 사실이 있으면 `target`은 `"persistence"`, 없으면 `null`이다.
  `transport`는 없다. 이 문서는 bridge 도메인의 호출 측 요건을 채우지 않는다.
- 모든 fact의 `kind`는 `relation-use`다. `channel`은 코드에 쓰인 관계 이름(한정·비한정
  그대로, 인용 부호 제거)이고, `method`가 있으면 그 관계의 컬럼 이름이다. 컬럼 사실은
  관계 사실을 함축하지 않으므로 관계 사실을 따로 낸다.
- 이름 escape: SQL 텍스트와 API 인자의 `.`는 한정자다. 인용 식별자 안의 `.`와 drift
  `tableName`·floor `tableName`처럼 한 식별자로 주어진 이름의 `.`는 `%2E`, `%`는
  `%25`로 escape한다.
- `dynamic: true`의 `channel`은 비리터럴 표현식이나 미해석 SQL의 원문 요약(공백 접음,
  최대 160자)이다. 보간 문자열의 선행 literal이 있으면 `channelPrefix`로 싣는다.
- `symbol.qualifiedName`은 bridges와 같은 어휘적 귀속이다. drift 테이블·컬럼과 floor
  엔티티·컬럼 선언 사실은 클래스(`Person`)·멤버(`Person.name`) 이름을 싣는다.
- `location`은 필수이며 bridges와 같은 1-based UTF-8 byte 열이다.

| limitation 접두사 | 뜻 |
|---|---|
| `dynamic-relation-names:` | 정적으로 읽지 못해 동적 사실로 낸 SQL 인자·관계 피연산자 수 |
| `skipped-sql-literals:` | SQL 동사가 있지만 대문자 형태가 아니라 읽지 않은 게이트 없는 리터럴 수 |
| `drift-name-derivation-unverified:` | 파생하지 않은 drift 테이블·컬럼 이름 수와 이유 |
| `non-relational-stores:` | 비SQL 저장소 패키지를 import한 파일 수와 패키지별 분포 |
| `unsupported-db-packages:` | 지원 표면 밖 SQL 패키지를 import한 파일 수와 분포 |
| `missing-relation-symbols:` | 감싸는 선언 이름이 없는 사실 수(`.drift` 파일 포함) |
| `invalid-relation-names:` | 제어 문자가 있어 버린 이름 수 |
| `unreadable-sources:`·`parse-errors:`·`symlink-escape:` | 파일 수준 관측 공백 |

## 소비자 지침

- `project`·`channel`·`method`는 문자열 정확 일치로만 비교한다 — 정규화·대소문자
  변환·`project` 재작성은 provenance를 깬다.
- `dynamic: true`인 fact는 조인에서 제외하거나 `channelPrefix`로 후보만 제시한다 —
  표현식 텍스트를 실제 채널명으로 착각하지 않는다.
- `limitations`가 비어 있지 않으면 관측 공백이 있을 수 있다 — `dynamic-*-names`와
  `unscanned-ffi-interop`은 조인이 못 보는 경계를 나타낸다.
- `version`·`transport`를 확인해 문서 종류를 구분한다 — v1과 v2는 같은 조인에서도
  다른 transport 계약이다.

## 자매 소비자 확장 (개발)

isthmus의 개발 계약에는 `transport: "react-native-event"`인 별도 v2 문서가 추가된다.
구독 측 `event-listen`은 isthmus JS 추출기, 네이티브 `event-emit`은 cartograph(Swift)/kartograph(Kotlin)가
생산한다. dartograph의 `--events`는 계속 Flutter EventChannel의 `stream-listen`만 내며,
RN 이벤트를 Dart 사실로 만들거나 두 transport를 섞지 않는다. Dart 생산 필드는 바뀌지 않는다.

`retentions --for kartograph`는 기존 Dart 호출 근거와 실제 JVM 식별자를 가진 Kotlin
수신 사실을 결합한다. ObjC 보존에는 실제 Clang USR과 이를 그래프에 포함하는 cartograph
개발 빌드가 필요하다. 이는 자매 도구의 개발 기능이며 dartograph의 새 발행이 필요하다는
뜻은 아니다. 정본과 배포 상태는 위 isthmus GRAPH-EXCHANGE 링크를 따른다.

v2 문서 종류는 `(version, transport)`로 구분한다. RN 문서는 `extract-js --events`와
`bridges --rn-events`로 명시적으로 선택하며, 지원하지 않는 transport는 소비자가 거부한다.
RN 경계는 native→JS 방향이고, 코어 전역 이벤트 이름을 같은 `(project, transport, channel)`
안에서 정확히 비교한다. Expo의 모듈별 이벤트는 이 키에 합치지 않는다. Dart/Flutter와
RN의 보존 근거도 transport별로 분리하며, 네이티브 식별자가 원본 호출 위치를 덮어쓰지 않는다.
매치된 Kotlin/ObjC 선언의 필요한 컴파일러 식별자가 누락되면 보존 문서 생성은 실패한다.
