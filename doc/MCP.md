# MCP 서버 (`dartograph mcp`)

dartograph는 [Model Context Protocol](https://modelcontextprotocol.io) 도구 세트를
stdio로 제공한다. AI 클라이언트가 셸 파싱 없이 영향·의존성·검증 질의를 도구 호출로
수행하게 하는 얇은 어댑터이며, 내부적으로는 CLI와 **완전히 같은** 실행 경로
(`runDartograph`)를 재사용한다. 그래서 도구 결과의 스키마·종료 코드가 `dartograph`
CLI와 항상 일치한다.

## 실행

```bash
dartograph mcp
```

- transport: stdio. stdin으로 개행 구분 JSON-RPC 2.0 메시지를 읽고, stdout으로
  응답만 쓴다. 사람용 로그는 stderr로 간다.
- protocolVersion: `2024-11-05`. `initialize`·`ping`·`tools/list`·`tools/call`·
  `resources/list`·`resources/read`·`prompts/list`·`prompts/get`과
  `notifications/*`를 처리한다.
- 알 수 없는 메서드는 `-32601`, 잘못된 JSON은 `-32700`, 잘못된 파라미터는 `-32602`,
  알 수 없는 리소스 URI는 `-32002`로 답하고 서버는 계속 동작한다.
- 도구는 **읽기 전용**이다. 저장소를 수정하지 않으며 `changed`·`batch` 배열은 OS 임시
  디렉터리에 잠깐 쓰고 호출이 끝나면 지운다.
- 세션 임시 캐시: `injected indexPackage`가 없으면 서버는 첫 색인 요청에서
  `dartograph-mcp-cache.*` OS 임시 디렉터리를 만들고, 그 안의 패키지별 하위
  디렉터리에 CLI의 파일 단위 증분 캐시(`IncrementalCache`)를 둔다. 반복 질의는
  변경된 파일과 그 역방향 import 폐쇄만 다시 해석한다. 서버 세션이 끝나면
  디렉터리를 지운다 — 임시 캐시는 서버가 소유하며 다른 세션이나 CLI와 공유하지
  않는다. 다른 packageRoot는 서로 다른 하위 디렉터리를 써서 키가 섞이지 않게
  분리된다. 캐시 생성·쓰기가 실패하면 그 세션은 전체 해석으로 폴백하고 결과는
  동등하다(실패 사실은 stderr 진단으로만 남고 경로는 출력하지 않는다).

## 클라이언트 설정 예시

```json
{
  "mcpServers": {
    "dartograph": {
      "command": "dartograph",
      "args": ["mcp"]
    }
  }
}
```

`dartograph`가 PATH에 없으면 `dart pub global activate dartograph` 후의 실행 파일
경로를 `command`에 넣거나, 저장소에서 `dart run bin/dartograph.dart mcp`를 쓴다.

`tools/list`가 광고하는 도구 목록을 `dartograph_explore` 하나로 줄이려면 서버
환경 변수를 설정한다(`"env": {"DARTOGRAPH_MCP_LEGACY_TOOLS": "0"}`를 서버
항목에 추가 — 지원하는 클라이언트 한정).

## 도구

모든 도구의 `packageRoot`는 **서버 작업 디렉터리 안의 실제 디렉터리**로 해석돼야
한다 — `.mcp.json` 등록으로 프로젝트 루트에서 띄운 서버라면 그 프로젝트 안의
패키지만 분석할 수 있다. 경계 밖이거나 존재하지 않는 경로는 인자 오류
(`isError: true`)로 거부된다.

stdio 프레이밍은 JSON-RPC 메시지 한 줄당 1MiB 상한이 있다. 상한을 넘는 메시지는
잘려서 `Invalid JSON`(-32700) 응답이 되고 연결은 유지된다.

`tools/list`는 다섯 도구를 광고한다. 서버 환경 변수
`DARTOGRAPH_MCP_LEGACY_TOOLS=0`(또는 `false`, 대소문자 무관)이면
`dartograph_explore`만 광고한다 — 나머지 도구는 목록에서 빠지지만
`tools/call`은 계속 받으므로 기존 클라이언트 설정과 프롬프트 안내가 깨지지
않는다. `0`·`false` 외의 값(미설정·`1` 등)은 전부 광고하며, 목록을
줄였을 때 `dartograph_explore` 응답의 `routed:` 표지는 목록에 없는 도구
이름을 가리킬 수 있다(라우팅된 경로의 이름이며 그 도구는 여전히 호출
가능하다).

### `dartograph_explore`

단일 진입점 — `packageRoot`에 **질문 형태 하나**를 붙여 호출하면 어떤 인자가
왔는지로 아래 경로 중 하나에 결정적으로 라우팅한다. 응답 텍스트 첫 줄의
`routed: <도구>`가 실제로 답한 경로를 밝히고, 이어서 해당 도구와 완전히 같은
출력(`exitCode` + 문서)이 온다. 좁은 도구 네 개를 나열하는 대신 하나로 안내해
호출자가 질문 형태만 고르면 되게 하는 것이 목적이다.

| 질문 형태 | 인자 | 라우팅 |
|---|---|---|
| 심볼 근거·소스 | `symbol` 또는 `batch` | `dependency_query` — `withSource`가 **기본 true**, `sourceContext` 기본 3. 명시하면 그 값이 우선 |
| 변경·선언 영향 | `impactSymbol` \| `since` \| `changed` 중 정확히 하나 | `impact_query` — `impactSymbol`은 `impact --symbol` seed로 재배치 |
| 검증 | `command`: `dead`·`deps`·`dup`·`cycles`·`rules`·`metrics` | `verify_run` — 명령별 수정자(`closedApp`·`kinds`·`minTokens`·`since`·`baseline`·`config`·`strict`·`format`)는 그대로 전달·검증된다 |
| 런타임 사실 | `command`: `runtime` | `runtime_query` — `limit`만 허용 |

경로에 의미 없는 인자는 조용히 무시하지 않고 인자 오류로 거부한다 — 예:
`command`와 `changed`·`symbol`의 조합, `impactSymbol`과 `symbol`의 조합.
`since`·`changed`·`impactSymbol`이 둘 이상이면 "exactly one of" 오류다.
`command`와 `since`의 조합은 영향 질의가 아니라 `dead --since`로 해석된다.
어떤 형태도 없으면 오류가 아니라 `routed: help`의 형태 안내를 돌려준다.

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call",
 "params":{"name":"dartograph_explore","arguments":{
   "packageRoot":"/path/to/package","symbol":"Foo"}}}
```

```text
routed: dependency_query
exitCode: 0
{"result":{"subject":{...,"source":[{"line":1,"text":"class Foo {"}, ...]}}}
```

### `impact_query`

수정 **전에** 영향 범위를 묻는다. `impact` 명령의 JSON 문서를 그대로 돌려준다.

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `packageRoot` | string | ✔ | 분석할 패키지 루트 |
| `since` | string | | Git 기준점(commit·branch·tag·`HEAD~1`) |
| `changed` | string[] | | 프로젝트 상대 변경 경로 1–1000개 |
| `symbol` | string | | 종속자를 볼 심볼 ID |
| `depth` | integer ≥1 | | 전이 한계(기본 무제한) |
| `limit` | integer ≥1 | | 보고 항목 수 제한 |

`since`·`changed`·`symbol` 중 **정확히 하나**를 준다.

호출 예(JSON-RPC):

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call",
 "params":{"name":"impact_query","arguments":{
   "packageRoot":"/path/to/package","since":"origin/main"}}}
```

응답 텍스트 첫 줄은 `exitCode: 0`이고, 그 다음 줄부터 영향 문서(JSON)가 온다.
문서에는 `changed`·`impacted`·`callSites`·`tests`·`risk`·`coverage`·`limitations`가
있고, `coverage.missedWithoutPrecheck`가 "변경 파일만 봤을 때 누락됐을" 심볼을 담는다.

실제 호출 성공 사례(이 저장소, `changed: ["lib/src/core/graph_edge.dart"]`):

```text
exitCode: 0
{"callSites":[...],"changed":{"libraries":["package:dartograph/src/core/graph_edge.dart"], ...},
 "coverage":{"directlyChangedSymbols":30,"relatedTests":29,"transitivelyImpacted":183, ...},
 "risk":{"level":"medium","score":66,"factors":[...]},"version":1}
```

### `dependency_query`

`query`/`query --batch`의 근거 문서를 돌려준다.

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `packageRoot` | string | ✔ | 분석할 패키지 루트 |
| `symbol` | string | | 단일 심볼 ID 또는 이름 |
| `batch` | string[] | | 심볼 1–1000개 |
| `depth` | integer ≥1 | | 사용 관계 추적 깊이(기본 1) |
| `limit` | integer ≥1 | | 방향별 이웃 수 제한 |
| `baseline` | string | | `baseline --write`로 만든 파일 |
| `withSource` | boolean | | 보고된 선언 위치의 소스 줄을 함께 돌려준다 |
| `sourceContext` | integer ≥0 | | `withSource`일 때 위치 앞뒤 줄 수(기본 0) |

`symbol`·`batch` 중 정확히 하나를 준다. `notFound`·`ambiguous`는 오류가 아니라 정상
결과로 돌아오며 부분 미발견이면 `exitCode: 64`다. `sourceContext`는 `withSource: true`
없이 주면 인자 오류다. 소스는 `project:` 파일만 읽고, 읽지 못한 위치는 생략된다.

### `runtime_query`

정적 런타임 의존성 사실 조회다. `runtime --no-verify --format json`과 완전히 같은
출력·종료 코드를 돌려준다 — 탐지만 수행하고 호스트 환경·파일 존재 판정은
하지 않는다. `--execute`, `--env`, `--dart-define`, `--fail-on`, `--record` 같은
실행·환경 주입 인자는 이 도구 표면에 없으며 주면 인자 오류(`isError: true`)로
거부된다. 이 도구는 어떤 경우에도 코드를 실행하지 않는다.

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `packageRoot` | string | ✔ | 분석할 패키지 루트 |
| `limit` | integer ≥1 | | 카테고리별 보고 항목 수 제한 |

응답 텍스트 첫 줄은 `exitCode: 0`이고 이어서 runtime-report version 1 JSON이
온다. `detected`·`limitations`는 채워지고 `verified`·`unverified`·`execution`은
비어 있다. 프로세스 환경은 판정에 쓰이지 않지만 탐지 결과에 환경 변수 **이름**은
실린다 — 값은 이 도구에서도 CLI와 같이 절대 출력하지 않는다.

### `verify_run`

검증을 실행하고 **종료 코드와 원시 출력**을 함께 돌려준다.

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `packageRoot` | string | ✔ | 분석할 패키지 루트 |
| `command` | enum | ✔ | `dead`·`deps`·`dup`·`cycles`·`rules`·`metrics` |
| `strict` | boolean | | `cycles`·`rules`·`metrics`에서 finding을 코드 1로 |
| `minTokens` | integer | | `dup` 전용: 중복 토큰 창 하한(≥ 2) |
| `kinds` | string[] | | `dead`·`deps`·`dup` 전용: 보고할 finding 종류만 남김 |
| `closedApp` | boolean | | `dead` 전용: `--closed-app`(공개 API 미보존, 독립 앱 전용) |
| `since` | string | | `dead --since` |
| `baseline` | string | | `dead --baseline` |
| `config` | string | | `rules --config`의 layers.yaml |
| `format` | enum | | `dead`·`deps`·`dup`: `text`·`json`·`markdown`·`github-actions`·`sarif`; `cycles`·`rules`·`metrics`: `text`·`json`·`sarif` |

`closedApp: true`를 `dead`가 아닌 명령에 주면 인자 오류로 거절한다 — 다른 명령에서는
의도 없이 무시되는 플래그를 받지 않는다. `minTokens`는 `dup` 전용, `kinds`는
`dead`·`deps`·`dup` 전용으로 같은 규칙이다. `cycles`·`rules`·`metrics`에
`markdown`·`github-actions`를 주면 인자 오류다(CLI가 지원하지 않는다).

응답 텍스트 첫 줄이 `exitCode: <0|1|2|64>`이고(`dead`·`deps` finding은 1), 이어서
CLI 출력이 온다. 분석 실패(2)·사용 오류(64)는 `isError: true`다.

## 리소스 (`resources/list`·`resources/read`)

프로젝트별 동적 상태가 아니라 **호출 사이에 바뀌지 않는 정적 문서**를 노출한다.
프로젝트의 그래프·발견은 도구 호출이 답한다.

| URI | mimeType | 내용 |
|---|---|---|
| `dartograph://usage` | `text/plain` | CLI 계약 전문 — `dartograph --help` 출력과 같은 문서 |
| `dartograph://skill` | `text/markdown` | 에이전트 스킬 문서 — `dartograph skill` 출력 |
| `dartograph://config` | `text/yaml` | 주석 달린 `dartograph.yaml` 템플릿 — `dartograph init` 출력 |

```json
{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{"uri":"dartograph://usage"}}
{"id":9,"jsonrpc":"2.0","result":{"contents":[{"uri":"dartograph://usage","mimeType":"text/plain","text":"dartograph — …"}]}}
```

모르는 URI는 `-32002`로 답한다. 응답의 `contents[].uri`는 요청 URI를 그대로 반향한다.

## 프롬프트 (`prompts/list`·`prompts/get`)

에이전트가 자주 쓰는 작업 흐름을 user 메시지 하나로 렌더링한다. 프롬프트 본문은
호출할 도구와 결과 해석 순서를 적은 안내문이다 — 서버가 도구를 대신 호출하지 않는다.

| 이름 | 인자 | 안내하는 흐름 |
|---|---|---|
| `impact-precheck` | `packageRoot`(필수), `since` | 수정 전 `impact_query` 호출 → impacted·callSites·risk 해석 |
| `dead-code-review` | `packageRoot`(필수), `closedApp` | `verify_run dead` → `dependency_query`로 근거 확인 → limitations 점검 |
| `dependency-audit` | `packageRoot`(필수) | `verify_run deps` → 네 종류 finding 해석 |
| `duplication-review` | `packageRoot`(필수), `minTokens` | `verify_run dup` → 인스턴스 확인 → 병합 후보 판단 |

```json
{"jsonrpc":"2.0","id":10,"method":"prompts/get","params":{"name":"impact-precheck","arguments":{"packageRoot":"/path/to/package","since":"origin/main"}}}
{"id":10,"jsonrpc":"2.0","result":{"description":"Pre-check what an edit affects …","messages":[{"role":"user","content":{"type":"text","text":"Pre-check the impact …"}}]}}
```

모르는 이름·필수 인자(`packageRoot`) 누락은 `-32602`다.

## 도구 스키마 (`tools/list`)

`tools/list`가 돌려주는 입력 스키마의 정본이다(설명 필드는 생략). 다섯 도구 모두
`additionalProperties: false`이고 `packageRoot`가 필수다.

```json
[
  {
    "name": "dartograph_explore",
    "inputSchema": {
      "type": "object",
      "properties": {
        "packageRoot": {"type": "string"},
        "symbol": {"type": "string"},
        "batch": {"type": "array", "items": {"type": "string"}},
        "impactSymbol": {"type": "string"},
        "since": {"type": "string"},
        "changed": {"type": "array", "items": {"type": "string"}},
        "command": {"type": "string", "enum": ["dead", "deps", "dup", "cycles", "rules", "metrics", "runtime"]},
        "strict": {"type": "boolean"},
        "closedApp": {"type": "boolean"},
        "minTokens": {"type": "integer"},
        "kinds": {"type": "array", "items": {"type": "string"}},
        "baseline": {"type": "string"},
        "config": {"type": "string"},
        "format": {"type": "string", "enum": ["text", "json", "markdown", "github-actions", "sarif"]},
        "depth": {"type": "integer", "minimum": 1},
        "limit": {"type": "integer", "minimum": 1},
        "withSource": {"type": "boolean"},
        "sourceContext": {"type": "integer", "minimum": 0}
      },
      "required": ["packageRoot"],
      "additionalProperties": false
    }
  },
  {
    "name": "impact_query",
    "inputSchema": {
      "type": "object",
      "properties": {
        "packageRoot": {"type": "string"},
        "since": {"type": "string"},
        "changed": {"type": "array", "items": {"type": "string"}},
        "symbol": {"type": "string"},
        "depth": {"type": "integer", "minimum": 1},
        "limit": {"type": "integer", "minimum": 1}
      },
      "required": ["packageRoot"],
      "additionalProperties": false
    }
  },
  {
    "name": "dependency_query",
    "inputSchema": {
      "type": "object",
      "properties": {
        "packageRoot": {"type": "string"},
        "symbol": {"type": "string"},
        "batch": {"type": "array", "items": {"type": "string"}},
        "depth": {"type": "integer", "minimum": 1},
        "limit": {"type": "integer", "minimum": 1},
        "baseline": {"type": "string"},
        "withSource": {"type": "boolean"},
        "sourceContext": {"type": "integer", "minimum": 0}
      },
      "required": ["packageRoot"],
      "additionalProperties": false
    }
  },
  {
    "name": "verify_run",
    "inputSchema": {
      "type": "object",
      "properties": {
        "packageRoot": {"type": "string"},
        "command": {"type": "string", "enum": ["dead", "deps", "cycles", "rules", "metrics"]},
        "strict": {"type": "boolean"},
        "closedApp": {"type": "boolean"},
        "since": {"type": "string"},
        "baseline": {"type": "string"},
        "config": {"type": "string"},
        "format": {"type": "string", "enum": ["text", "json", "markdown", "github-actions", "sarif"]}
      },
      "required": ["packageRoot", "command"],
      "additionalProperties": false
    }
  },
  {
    "name": "runtime_query",
    "inputSchema": {
      "type": "object",
      "properties": {
        "packageRoot": {"type": "string"},
        "limit": {"type": "integer", "minimum": 1}
      },
      "required": ["packageRoot"],
      "additionalProperties": false
    }
  }
]
```

## JSON-RPC 오류 코드

| 코드 | 상황 | 응답 `id` |
|---:|---|---|
| `-32700` | 줄이 유효한 JSON이 아님 | `null` |
| `-32600` | 메시지가 객체가 아님, 또는 `id`가 있는데 `method`가 없음 | 메시지의 `id`(없으면 `null`) |
| `-32601` | 알 수 없는 메서드 | 요청 `id` |
| `-32602` | `tools/call`·`resources/read`·`prompts/get`의 `params` 누락·비객체, 비문자열 `name`/`uri`, 알 수 없는 도구·프롬프트, 필수 인자 누락 | 요청 `id` |
| `-32002` | 알 수 없는 리소스 URI | 요청 `id` |
| `-32603` | 도구 실행 중 예상 못 한 예외(진단은 stderr) | 요청 `id` |

`id` 없는 메시지는 알림으로 보고 응답하지 않으며, `method`가 `notifications/`로
시작하면 항상 무응답이다. 어떤 오류에도 서버는 계속 동작한다.

## 재현 가능한 예시

한 줄이 메시지 하나다. `printf`로 파이프에 흘려 넣으면 그대로 재현된다.

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"ping"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' \
  | dartograph mcp
```

`initialize` 응답(`serverInfo.version`은 설치된 도구 버전):

```json
{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{},"resources":{},"prompts":{}},"protocolVersion":"2024-11-05","serverInfo":{"name":"dartograph","version":"0.10.0"}}}
```

성공 호출·인자 오류·도구 오류·메서드 오류·파싱 오류의 응답 형태:

```json
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"impact_query","arguments":{"packageRoot":"/path/to/package","since":"origin/main"}}}
{"id":4,"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"exitCode: 0\n{...}"}],"isError":false}}

{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"impact_query","arguments":{"packageRoot":"/path"}}}
{"id":5,"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"Invalid arguments: provide exactly one of since, changed, or symbol"}],"isError":true}}

{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope","arguments":{}}}
{"jsonrpc":"2.0","id":6,"error":{"code":-32602,"message":"Unknown tool: nope"}}

{"jsonrpc":"2.0","id":7,"method":"nope"}
{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"Unknown method: nope"}}

{"jsonrpc":"2.0","id":8,"method":
{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Invalid JSON"}}
```

`impact_query`·`dependency_query`의 성공 `text` 본문은 CLI의
`impact --format json`·`query` 문서와 완전히 같다(첫 줄만 `exitCode: <n>`). `verify_run`은
명령의 원시 출력을 그대로 내보낸다.

## 한계

- 서버 세션 임시 캐시가 있으면 그래프를 색인하는 도구(`impact_query`·
  `dependency_query`·`verify_run`)는 파일 단위 증분 재해석으로 반복 질의를
  빠르게 답한다. `runtime_query`는 이 캐시를 쓰지 않고 매 호출 정적 탐지를
  새로 한다. 캐시는 세션 소유이므로 세션마다 처음 한 번은 전체 색인 비용이
  들고, 서버를 자주 띄우는 호출 패턴에는 이득이 없다. 파일 변경은 다음 호출에서
  최신 사실로 반영된다 — 사실 캐시 키가 파일 내용 해시라 편집·삭제·신규 파일이 그
  호출의 재해석 대상이 되고, 응답은 호출 시점의 작업 트리를 반영한다(별도의
  staleness 배너가 필요 없다). 회귀는 `test/cli/mcp_server_test.dart`의
  “session cache reuses facts, refreshes edits and cleans up”가 고정한다. 캐시
  삭제 실패 시 OS 임시 저장소에 디렉터리가 남을 수 있다(stderr 진단으로 알린다).
  CLI의 파일별 증분 캐시(`--incremental <dir>`)는
  MCP 도구가 노출하지 않는다 — 세션 간에 사실을 재사용해야 하면 CLI를 직접
  쓴다([USAGE.md](USAGE.md)의 `--incremental`).
- `impact_query`·`dependency_query`의 관측은 의존 도달성이지 삭제 판정이 아니다.
  동적 디스패치·문자열 route·생성 코드는 근거를 제한할 수 있고, 그 사실은 각 문서의
  `limitations`에 실린다.
