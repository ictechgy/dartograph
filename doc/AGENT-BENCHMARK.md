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
| PATH | `.pub-cache` 항목 제거 — 예방 수단, 검출이 불변식 | 그대로 |
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
- PATH 필터는 best-effort 예방이다(`dart pub global run` 등 우회가 남는다).
  실제 불변식은 **검출**이다 — 위의 contaminated 규칙이 without arm의
  dartograph 사용을 잡아내 제외한다.
- with 런에서 dartograph 호출 0이면 **treatment-not-delivered** — 제외하지
  않고 `usedDartograph`로 기록한다. "도구가 있어도 안 쓴" 경우 자체가 결과다.
- 모든 런의 원시 트랜스크립트(`results/transcripts/*.jsonl`)를 보존한다.
- `--setting-sources project`는 사용자 설정·메모리를 제외하지만 checkout의
  **부모 디렉터리**에서 발견되는 CLAUDE.md 계열은 막지 않는다 — reposDir 위의
  조상 경로에 지시 파일이 없는지 실행 전 확인한다(현재 측정 경로는 없음).

## 지표

런당: `correct`(expected 근거 문자열 전부 포함 **및** `isError == false`),
`numTurns`, `durationMs`, `costUsd`, `fileReads`, `bashCalls`, `toolCalls`
종류별 수, `dartographCalls`, `inputTokens`/`outputTokens`, `exitCode`,
`isError`, `runError`, `run` 인덱스.
task × arm × model 집계는 중앙값 — 첫 런의 콜드 인덱싱 편향을 줄인다.
절대 시간·비용은 SLA가 아니며 같은 조건의 상대 비교만 의미 있다.
**with arm이 더 느리거나 비싼 수치도 그대로 공개한다**(codegraph가
residual context +80%를 공개한 것과 같은 규칙).

알려진 채점 한계:

- `correct`는 **재현율만** 본다 — expected 문자열이 다 들어가면 엉뚱한
  후보를 추가로 나열한 답도 정답이다(2026-09-19 측정에서 inv-dead의
  `hashCode`·`toString` 부가 나열이 관찰됐다). 트랜스크립트 감사 없이
  정답률 차이를 강하게 주장하면 안 된다.
- `fileReads`는 `Read` 호출만 센다 — Grep·Glob 등 다른 읽기 도구는
  `toolCalls` 원시 집계에서만 보인다.
- 런마다 without·with를 교번 실행해 시간 의존 API 조건이 arm과 상관하지
  않게 한다(첫 매트릭스는 task 내 without 전부 → with 전부 순서였다 —
  n=4 중앙값으로 완화만 한 한계).

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

런 인자의 기본값: `--max-turns 24`, `--timeout-secs 900`,
`--permission-mode bypassPermissions`, `--disallowedTools Edit Write
NotebookEdit`(읽기 전용 과제), `--no-session-persistence`,
`--output-format stream-json --verbose`(파싱용).
모델·런 인덱스는 레코드에 남고 집계는 task × arm × model로 나뉜다 —
모델을 바꿔 돌려도 옛 기록과 섞이지 않는다.
`--disallowedTools`는 Edit/Write 도구만 막을 뿐 Bash 자체는 막지 않는다 —
"bypassPermissions + 프롬프트의 수정 금지" 조합이라 파일 수정 가능성은
남지만 두 팔 대칭이다. prepare는 기존 checkout의 `HEAD`가 tasks.json의
핀 리비전과 다르면 실패한다.

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
- **dartograph 사용 런과 정답이 겹친 과제는 nav-impact뿐이다.** without
  arm은 `_BookstoreState.build` 대신 익명 GoRoute builder를 답해 1/4만
  정답이었다. with arm은 3/4 정답인데, 그중 dartograph 사용 런은 2런이고
  둘 다 정답, 미사용 런은 2런 중 1런 정답이다 — arm 수준(3/4)과 실제
  사용 런 수준(2/2)을 구분해 읽어야 한다. 다만 n=4로는 이 차이가 통계적
  신호가 아니다(Fisher exact p≈0.46) — 셀당 ~10런 이상 전에는 방향성
  힌트로만 둔다.
- 도달성·호출자·조건부 export 등 나머지 과제는 두 팔이 사실상 동률이다 —
  grep으로 충분히 풀리는 질문에는 도구 오버헤드만 남는다(파일럿의
  nav-dead with 런은 턴·비용이 약 2배였다).
- inv-dead의 오답 2건은 양 팔 1건씩 max-turns(24) 초과다 — 대칭 실패.
- 이 측정은 **스킬 노출 방식의 개선 여지**(CLAUDE.md 안내·훅 제안 등)를
  시사하지, "dartograph가 에이전트를 빠르게 한다"는 근거로 쓸 수 없다.
  모델을 바꾸거나 과제를 더 어렵게 만들면 결과가 달라질 수 있다 — 같은
  조건의 재측정만 이 표에 추가한다.
