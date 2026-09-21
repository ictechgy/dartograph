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
| 지시 파일 | 레포 출하분 그대로 | 레포 출하분 + `setup --install`의 관리 `<!-- dartograph:begin -->` 블록(CLAUDE.md 또는 AGENTS.md) |
| 나머지 | 동일 — `--setting-sources project`, 동일 모델·턴 상한·도구 제한 | |

`--setting-sources project`는 사용자 수준 설정·메모리·MCP를 두 팔 모두에서
제외한다(측정: 사용자 CLAUDE.md가 memory_paths에 나타나지 않음,
mcp_servers `[]`). 레포가 출하한 AGENTS.md·CLAUDE.md 본문은 두 팔이
동일하게 받는다 — with 팔은 그 위에 관리 블록이 덧붙는데, 그 차이 자체가
측정하려는 처치(treatment)다.

## 오염·유효성 규칙

- without 런에서 `dartograph` Bash 호출이나 `mcp__dartograph*` 호출이
  하나라도 잡히면 **contaminated** — 집계에서 제외하고 수를 공개한다.
- Bash는 명령 실행 위치로 판별한다. 경로·grep 패턴·`which`/`command -v`
  조회는 사용으로 세지 않는다. 동적으로 조립된 shell 명령까지 완전히 해석하지
  않으므로 원시 입력 감사도 필요하다. 2026-09-21의 경로 오탐 보정은 아래 결과에 있다.
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

런당: `correct`(expected 근거 문자열 전부 포함 **및** `isError == false`, `exitCode == 0`),
`numTurns`, `durationMs`, `costUsd`, `fileReads`, `bashCalls`, `toolCalls`
종류별 수, `dartographCalls`, `inputTokens`/`outputTokens`, `exitCode`,
`isError`, `runError`, `run` 인덱스.
`dartographCalls`는 호출을 시도한 tool-use 블록 수다. Bash 입력 하나에서 여러 CLI
명령을 실행해도 1회로 세며, MCP는 각 tool-use를 센다. 호출 성공이나 답변 정확성을
뜻하지 않는다. 모델 ID는 `resolvedModel`, 판별 규칙은 `usageDetection`에 기록한다.
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

## 2026-09-21 확대 실험 조건

본 실험 **64회 완료**. [결과·채점 감사·계측 보정](benchmarks/ADOPTION-20260921.md)을
확인한다. 기존 adoption 셀의 Haiku·4과제·with 조건을 두 모델·8과제·양쪽 조건으로 넓혔다.
과제 자체를 새로 만든 것은 아니며, 첫 매트릭스의 전체 8과제를 현재
adoption 배선에 다시 적용한다. 기존 결과·원시 기록과 출력 디렉터리를
분리하고, 과거 without 수치를 새 with 수치의 동시 대조군으로 쓰지 않는다.

| 조건 | 설정 |
|---|---|
| CLI | dartograph 0.15.0, 양쪽 조건에 같은 SDK와 저장소 리비전 |
| 모델 | Claude `haiku`, `sonnet`; system과 assistant 응답의 모델 ID 확인 |
| 과제 | `tasks.json`의 8개 전체: nav 3개·ppf 2개·inv 3개 |
| 파일럿 | 모델별 연결 확인 1회, 본 실험과 별도 집계(아래 사전 점검 결과 참조) |
| 본 실험 | 모델 × 과제 × with/without × 2회 = 64회 |
| 호출 한도 | 파일럿 포함 최대 66회, 런당 24턴·stdout 유휴 900초(총 실행시간 제한 아님) |
| 비용 설정 | 런당 `--max-budget-usd 0.50`; API 호출 단위 초과 가능성이 있어 정확한 청구 상한은 아님 |
| 해석 | n=2/셀의 기술 통계; 속도·정답률의 일반적 개선을 주장하지 않음 |

실행 전에는 공개 저장소의 고정 리비전과 의존성·생성 코드 준비 상태를
확인한다. with 복사본에는 0.15.0의 `setup --install`과 `skill --install`을
다시 적용하고, without 복사본에는 dartograph 배선이 없음을 확인한다.
두 조건의 제품 소스가 같고 상위 디렉터리 지시 파일이 개입하지 않는지도
검사한다. 기존 `prepare`는 이미 존재하는 배선을 갱신하지 않으므로
명시적으로 재설치해야 한다. 공개 코드의 외부 모델 전송 범위와 실행 승인을
받은 후 파일럿으로 인증·모델·MCP 사용을 확인하고 본 실험을 시작한다.

```sh
# 위 준비를 마친 공개 저장소 3쌍과 새 결과 디렉터리의 절대 경로다.
BENCH_REPOS=/absolute/path/to/repos
BENCH_RESULTS=/absolute/path/to/results-adoption-20260921
# 검증한 0.15.0 바이너리를 둔다. without의 PATH 필터가 제거할 경로다.
BENCH_TOOLS="$BENCH_REPOS/.pub-cache/bin"
# 2026-09-21 연결 파일럿 2회는 별도 순수 Dart fixture로 실행했다.
# 아래 본 실험은 호환 Flutter SDK 준비와 Claude 한도 회복 후 실행한다.
for model in haiku sonnet; do
  PATH="$BENCH_TOOLS:$PATH" dart run tool/agent_benchmark/agent_benchmark.dart run \
    --repos "$BENCH_REPOS" --tasks tool/agent_benchmark/tasks.json \
    --out "$BENCH_RESULTS/matrix-$model" --model "$model" \
    --runs 2 --max-budget-usd 0.50
  dart run tool/agent_benchmark/agent_benchmark.dart score \
    --out "$BENCH_RESULTS/matrix-$model"
done
```

사용률은 task × model별 with 런 중 실제 호출한 비율로 집계한다. 오류·
오염·treatment-not-delivered·budget 종료를 모두 남기고, 정답률·비용·시간은
같은 과제·모델의 양쪽 조건을 비교한다. expected 문자열 채점의 과잉 답변
한계는 유지되므로 원시 답변도 함께 감사한다. 재실행 때 기존 run은
재사용하고, 의도적으로 추가 측정하려면 새 출력 디렉터리 또는
`--runs-offset`을 사용한다. 같은 출력 디렉터리에 여러 프로세스가 동시에
기록하지 않도록 모델별 디렉터리를 유지한다.

### 2026-09-21 사전 점검 결과

공개 GitHub 저장소 3개를 위 고정 리비전으로 새로 준비했고, 각 checkout의
HEAD와 변경 없음 상태를 대조했다. 8과제의 expected는 실제 호출·참조·
조건부 export를 읽어 다시 확인했다. 현재 환경의 기존 Flutter 3.32.2 /
Dart 3.8.1은 대상들의 최소 요구 버전보다 낮아 의존성 준비에 쓸 수 없었다.

그래서 파일럿은 저장소의 공개 `fixtures/closed_app` 복사본에서 MCP 연결과
모델 실행 가능 여부를 확인하는 과제로 분리했다. 이 과제는 도구 사용을
명시적으로 요청하므로 adoption 사용률 비교에 포함하지 않는다.
0.15.0 소스(`8c314aa`)의 고정 바이너리, 모델당 1회, 최대 8턴·$0.50 설정이다.

| 요청 모델 | CLI init이 표시한 모델 ID | MCP 연결 | 실제 도구 호출 | 종료 코드 | 보고 비용 |
|---|---|---|---|---|---|
| haiku | `claude-haiku-4-5-20251001` | connected | 0 | 1 | $0 |
| sonnet | `claude-sonnet-5` | connected | 0 | 1 | $0 |

두 실행 모두 `rate_limit`과 주간 사용 한도 초과를 반환했다. 서비스는
한국시간 낮 12시 초기화를 안내했지만 본 실험 실행 가능 여부는 회복 후
다시 확인해야 한다. 두 응답은 `is_error: true`이며 **모델의 과제 오답이나
제품 효과 측정값이 아니다**. 이 사전 점검 당시 본 실험 64회는 시작하지 않았다.
사용자가 한도 회복을 알린 뒤 본 실험을 완료했으며 아래 측정 기록과 구분한다.

개인 계정 정보 없이 상태·checkout 리비전·바이너리 해시를 로컬
`.git/evidence-adoption-20260921/`에 보존했다. 그 디렉터리는 Git 제출 대상이
아니며, 재개 경로는 `preparation.json`과 `STATUS.json`에서 확인한다.
새 측정은 기존 실패 파일럿을 덮어쓰지 않고 별도 본 실험 디렉터리에 기록한다.

### 2026-09-21 SDK·대조군 준비 완료

사용자가 공식 SDK CDN 접근과 의존성 준비를 승인했다. 아카이브 목록과
stable SDK ZIP 경로가 404를 반환해 공식 Git 태그를 checkout하고, SDK의
bootstrap 스크립트로 해당 엔진 리비전의 Dart SDK를 받았다. 기존 사용자
SDK와 전역 PATH는 변경하지 않았다.

| 대상 | 준비용 Flutter / Dart | 의존성 준비 | 대상 `flutter analyze --no-pub` |
|---|---|---|---|
| navigation_and_routing | 3.47.2 / 3.13.2 | pub workspace의 package config, 248개 경로 확인 | No issues found |
| path_provider_foundation | 3.47.2 / 3.13.2 | 본체·example pub get, 본체 51개 경로 확인 | No issues found |
| Invoice Ninja | 3.44.1 / 3.12.1 | `--enforce-lockfile`, 기존 lockfile 불변, 237개 경로 확인 | No issues found |

Flutter 태그는 각각 `d3b14c876900e553bc736ca19295fc09e3853e8e`와
`924134a44c189315be2148659913dda1671cbe99`로 확인했다. 이 SDK는 실험 대상의
준비에 사용한다. dartograph 자체는 기존 Dart 3.13.3 환경과 0.15.0 고정
바이너리를 유지한다.

with 복사본에만 `setup`·`skill`을 설치한 뒤 두 조건의 추적된 Dart 파일·
pubspec·lockfile을 바이트 단위로 비교했다(samples 523개, packages 4,110개,
Invoice Ninja 2,322개). without에는 dartograph MCP·스킬이 없음을 확인했다.

준비된 with 패키지 3개에 실제 MCP `dependency_query`를 호출해 9개 핵심
심볼의 `found` 응답과 종료 코드 0을 확인했다. 각 대상의 질의 응답에는
limitations가 1·6·76개 남아 있으며 삭제 안전성이나 전체 그래프 완전성을
의미하지 않는다. 사전 질의는 분석 캐시를 채우므로 이후 시간 수치는
cold 인덱싱 성능으로 해석하지 않는다. 이 점검에 외부 모델 호출은 없었다.

원장은 로컬 `.git/evidence-adoption-20260921/`의 `arms.json`,
`environment-ready.json`, `mcp-preflight.json`과 대상별 원시 응답에 있다.
SDK·checkout 경로는 `preparation.json`에 저장했다. 이후 본 실험의 원문은
`matrix-{haiku,sonnet}/`, 사용량 보정본은 `corrected-{haiku,sonnet}/`에 있다.

경로 오탐이 있는 원장도 transcript가 남아 있으면 `recount_usage.dart <results-dir>`로
사용량만 다시 계산할 수 있다. 원본을 덮어쓰지 말고 stdout을 새 파일로 보존한다.
이 도구는 외부 모델을 호출하지 않으며 원문 누락·오류를 호출 0으로 취급하지 않는다.

## 측정 기록

실행할 때마다 하단 표에 조건(모델·런 수·날짜·dartograph 버전)과 결과를
남긴다 — 불리한 수치를 지우지 않는다.

| 날짜 | 모델 | 런/arm | dartograph | 결과 |
|---|---|---|---|---|---|
| 2026-09-19 | claude haiku | 4 (nav-dead 5 — 파일럿 포함) | 0.14.0 (path activate, 4857136) | 오염 0/66. 정답률 차이는 nav-impact뿐(with 3/4, without 1/4). with arm의 dartograph 사용은 4/33 — 스킬·MCP가 있어도 에이전트가 안 부른 경우가 대부분 |
| 2026-09-20 | claude haiku | 4, with만 (adoption 셀: nav-impact·inv-dead·inv-callers·inv-impact) | 0.14.0 (path activate, feat/agent-adoption a44f048+) | with arm의 dartograph 사용 11/16 (이전 같은 과제 2/16). inv-dead 4/4 사용·4/4 정답(이전 0/4 사용·3/4). inv-callers는 grep으로 충분해 0/4 사용·4/4 정답 유지 |
| 2026-09-21 | claude haiku 4.5 | 2, 8과제·양쪽 조건 (32회) | 0.15.0 (`8c314aa`, 고정 바이너리) | 사용량 오탐 보정 후 with 사용 12/16, without 0/16. 기대 문자열 충족 14/16→16/16이나 nav-impact의 명명 차이로 생긴 점수 차이여서 정확도 개선으로 단정하지 않음. [전체 결과](benchmarks/ADOPTION-20260921.md) |
| 2026-09-21 | claude sonnet 5 | 2, 8과제·양쪽 조건 (32회) | 0.15.0 (`8c314aa`, 고정 바이너리) | with 사용 7/16, without 0/16. 기대 문자열 충족 14/16→15/16, with에서 비용 한도 실패 1회 포함. [전체 결과](benchmarks/ADOPTION-20260921.md) |

### 2026-09-20 adoption 셀 해석

처치 정의가 바뀌었다 — 이전 매트릭스의 with arm은 MCP+스킬뿐이었고,
이번 셀부터 `setup --install`이 지시 파일(CLAUDE.md/AGENTS.md)에 싣는
관리 라우팅 블록과 넓어진 스킬 description이 추가됐다. 결과는 별도
`results-adoption/` 디렉터리에 기록해 이전 66런과 집계를 섞지 않는다.

- **adoption은 확실히 올랐다**: with arm 사용률이 4/33(12%)에서
  11/16(69%)로. inv-dead·nav-impact는 8/8, inv-impact는 3/4다.
- **정답률은 inv-dead에서만 움직였다**(3/4→4/4). inv-callers는 사용 0인데
  전부 정답 — 블록이 "grep으로 충분한 질문"까지 호출을 강제하지는
  않았다는 신호다(불필요 호출 인플레이션 없음).
- 사용 런의 비용은 올랐다(inv-dead 중앙 $0.168, 이전 without $0.217보다는
  낮다) — 도구 호출이 턴·토큰을 늘리는 구조는 그대로다.
- n=4라 정답률 차이는 여전히 통계적 신호가 아니다. **사용률 상승이
  adoption 개선의 직접 증거**이고, 정답률 개선은 방향성 힌트로만 둔다.
- 한계: 측정한 모델은 haiku 하나, 과제는 4개뿐이다. without arm은
  재실행하지 않았다(처치와 무관해 이전 기록을 그대로 비교).

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
  신호가 아니다(Fisher exact p≈0.49) — 셀당 ~10런 이상 전에는 방향성
  힌트로만 둔다.
- 도달성·호출자·조건부 export 등 나머지 과제는 두 팔이 사실상 동률이다 —
  grep으로 충분히 풀리는 질문에는 도구 오버헤드만 남는다(파일럿의
  nav-dead with 런은 턴·비용이 약 2배였다).
- inv-dead의 오답 2건은 양 팔 1건씩 max-turns(24) 초과다 — 대칭 실패.
- 이 측정은 **스킬 노출 방식의 개선 여지**(CLAUDE.md 안내·훅 제안 등)를
  시사하지, "dartograph가 에이전트를 빠르게 한다"는 근거로 쓸 수 없다.
  모델을 바꾸거나 과제를 더 어렵게 만들면 결과가 달라질 수 있다 — 같은
  조건의 재측정만 이 표에 추가한다.
