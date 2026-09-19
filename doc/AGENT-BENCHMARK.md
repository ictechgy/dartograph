# 에이전트 with/without 대조 벤치마크

도구 속도(인덱싱·증분 배수)가 아니라 **에이전트가 dartograph를 쓸 때와
안 쓸 때**의 작업 비용·정답률 차이를 재는 하네스다.
`tool/agent_benchmark/agent_benchmark.dart`가 실행·채점하고, 이 문서가
방법론과 측정 조건의 정본이다. codegraph의 공개 벤치(arm당 다수 런·중앙값·
오염 차단 공개·불리한 지표 공개)를 기준 형식으로 따른다.

## 팔(arm) 정의

| | without | with |
|---|---|---|
| checkout | `<repos>/<name>` — 클론 그대로 | `<repos>/<name>-with` — 복사본 + 배선 |
| PATH | `.pub-cache` 항목 제거 — `dartograph` 호출 불가 | 그대로 |
| MCP | `--strict-mcp-config`로 서버 0개 강제 | `--mcp-config <root>/.mcp.json` — `dartograph setup --install` 산출물 |
| skill | 없음 | `.claude/skills/dartograph/SKILL.md` (`skill --install`) |
| 나머지 | 동일 — `--setting-sources project`, 동일 모델·턴 상한·도구 제한 | |

`--setting-sources project`는 사용자 수준 설정·메모리·MCP를 두 팔 모두에서
제외한다(측정: 사용자 CLAUDE.md가 memory_paths에 나타나지 않음,
mcp_servers `[]`). 레포 자체의 AGENTS.md·CLAUDE.md는 두 팔이 동일하게
받는다 — 클론 루트까지 베끼는 이유다.

## 오염·유효성 규칙

- without 런에서 `dartograph` Bash 호출이나 `mcp__dartograph*` 호출이
  하나라도 잡히면 **contaminated** — 집계에서 제외하고 수를 공개한다.
- with 런에서 dartograph 호출 0이면 **treatment-not-delivered** — 제외하지
  않고 `usedDartograph`로 기록한다. "도구가 있어도 안 쓴" 경우 자체가 결과다.
- 모든 런의 원시 트랜스크립트(`results/transcripts/*.jsonl`)를 보존한다.

## 지표

런당: `correct`(expected 근거 문자열 전부 포함), `numTurns`, `durationMs`,
`costUsd`, `fileReads`, `toolCalls` 종류별 수, `dartographCalls`.
task × arm 집계는 중앙값 — 첫 런의 콜드 인덱싱 편향을 줄인다.
절대 시간·비용은 SLA가 아니며 같은 조건의 상대 비교만 의미 있다.
**with arm이 더 느리거나 비싼 수치도 그대로 공개한다**(codegraph가
residual context +80%를 공개한 것과 같은 규칙).

## 과제(task)와 정답

`tool/agent_benchmark/tasks.json`에 프롬프트와 `expected` 근거 문자열을
둔다. 정답은 dartograph 출력을 기준 삼지 않고 **직접 grep·코드 읽기로
검증한** 파일·심볼 이름이다(도구가 채점자가 되면 편향된다). 과제는
grep이 어설프게 답하는 질의 유형을 고른다 — 도달성, 직접 영향,
호출자, 조건부 export, FFI/채널 경로.

레포는 doc/DECISION-analyzer.md의 도그푸딩 대상을 핀 리비전으로 쓴다:
`samples`(navigation_and_routing `463e365e`),
`packages`(path_provider_foundation `9af9c607`),
`invoiceninja`(`59fa2c8f`, 대형 — 별도 준비).

## 실행

```sh
# 레포 클론·pub get·with checkout 배선 (Flutter SDK 필요)
dart run tool/agent_benchmark/agent_benchmark.dart prepare \
  --repos <dir> --tasks tool/agent_benchmark/tasks.json --flutter-bin <flutter>

# task × arm × runs — 결과는 <out>/summary.jsonl + transcripts/
dart run tool/agent_benchmark/agent_benchmark.dart run \
  --repos <dir> --tasks tool/agent_benchmark/tasks.json --out <dir> \
  --runs 4 --model <model>

# task × arm 중앙값 표
dart run tool/agent_benchmark/agent_benchmark.dart score --out <dir>
```

런 인자는 고정이다: `--model`, `--max-turns 24`,
`--permission-mode bypassPermissions`, `--disallowedTools Edit Write
NotebookEdit`(읽기 전용 과제), `--no-session-persistence`.
모델은 런 기록에 남는다 — 팔끼리 다른 모델로 섞어 돌리면 비교가 무효다.

## 측정 기록

실행할 때마다 하단 표에 조건(모델·런 수·날짜·dartograph 버전)과 결과를
남긴다 — 불리한 수치를 지우지 않는다.

| 날짜 | 모델 | 런/arm | dartograph | 결과 |
|---|---|---|---|---|---|
| 2026-09-19 | claude haiku | 4 (nav-dead 5 — 파일럿 포함) | 0.14.0 (path activate, 4857136) | 오염 0/66. 정답률 차이는 nav-impact뿐(with 3/4, without 1/4). with arm의 dartograph 사용은 4/33 — 스킬·MCP가 있어도 에이전트가 안 부른 경우가 대부분 |

### 2026-09-19 첫 매트릭스 해석

- **도구 존재 ≠ 사용.** with arm 33런 중 dartograph 호출은 4런뿐이다
  (nav-dead 2/5, nav-impact 2/4). invoiceninja처럼 grep 비용이 큰
  대형 레포에서조차 haiku는 스킬을 로드하지 않고 grep·Read로 풀었다 —
  treatment-not-delivered가 이 측정의 주된 발견이다.
- **dartograph가 실제로 쓰인 곳에서만 차이가 났다.** nav-impact에서
  without arm은 `_BookstoreState.build` 대신 익명 GoRoute builder를
  답해 1/4만 정답이었고, with arm의 dartograph 사용 런은 선언을 정확히
  지목했다(3/4). 도달성·호출자·조건부 export 등 나머지 과제는 두 팔이
  사실상 동률이다 — grep으로 충분히 풀리는 질문에는 오버헤드만 남는다.
- inv-dead의 오답 2건은 양 팔 1건씩 max-turns(24) 초과다 — 대칭 실패.
- 이 측정은 **스킬 노출 방식의 개선 여지**(CLAUDE.md 안내·훅 제안 등)를
  시사하지, "dartograph가 에이전트를 빠르게 한다"는 근거로 쓸 수 없다.
  모델을 바꾸거나 과제를 더 어렵게 만들면 결과가 달라질 수 있다 — 같은
  조건의 재측정만 이 표에 추가한다.
