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
- protocolVersion: `2024-11-05`. `initialize`·`ping`·`tools/list`·`tools/call`과
  `notifications/*`를 처리한다.
- 알 수 없는 메서드는 `-32601`, 잘못된 JSON은 `-32700`, 잘못된 파라미터는 `-32602`로
  답하고 서버는 계속 동작한다.
- 도구는 **읽기 전용**이다. 저장소를 수정하지 않으며 `changed`·`batch` 배열은 OS 임시
  디렉터리에 잠깐 쓰고 호출이 끝나면 지운다.

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

## 도구

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

`symbol`·`batch` 중 정확히 하나를 준다. `notFound`·`ambiguous`는 오류가 아니라 정상
결과로 돌아오며 부분 미발견이면 `exitCode: 64`다.

### `verify_run`

검증을 실행하고 **종료 코드와 원시 출력**을 함께 돌려준다.

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `packageRoot` | string | ✔ | 분석할 패키지 루트 |
| `command` | enum | ✔ | `dead`·`cycles`·`rules`·`metrics` |
| `strict` | boolean | | `cycles`·`rules`·`metrics`에서 finding을 코드 1로 |
| `since` | string | | `dead --since` |
| `baseline` | string | | `dead --baseline` |
| `config` | string | | `rules --config`의 layers.yaml |
| `format` | enum | | `dead` 전용: `text`·`json`·`markdown`·`github-actions`·`sarif` |

응답 텍스트 첫 줄이 `exitCode: <0|1|2|64>`이고(`dead` finding은 1), 이어서 CLI 출력이
온다. 분석 실패(2)·사용 오류(64)는 `isError: true`다.

## 오류 처리

| 상황 | 응답 |
|---|---|
| 알 수 없는 도구 | JSON-RPC `-32602` (`Unknown tool: <name>`) |
| 필수 인자 누락 | 도구 결과 `isError: true`, "Invalid arguments: ..." |
| 패키지 분석 실패 | 도구 결과 `isError: true`, `exitCode: 2` |
| 잘못된 JSON | JSON-RPC `-32700`, `id: null` |

## 한계

- 도구는 단일 호출마다 패키지를 다시 인덱싱한다(분석 캐시가 없으면 느리다). 반복
  질의가 많으면 `dependency_query`의 `batch`나 증분 캐시(`--cache-dir`)를 함께 쓴다.
- `impact_query`·`dependency_query`의 관측은 의존 도달성이지 삭제 판정이 아니다.
  동적 디스패치·문자열 route·생성 코드는 근거를 제한할 수 있고, 그 사실은 각 문서의
  `limitations`에 실린다.
