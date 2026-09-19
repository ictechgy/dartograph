# 경쟁·대체재 분석과 dartograph의 위치

이 문서는 dartograph가 어떤 문제를 누구와 나눠 갖고 있는지, 어디가 실제로 비어 있는지를
기록한다. 출처는 공개 문서이며, 확인한 시점을 함께 적는다. 확인하지 않은 주장은 넣지 않는다.

## 1. 요약

- 대체재는 크게 세 무리다. ① 미사용 코드·의존성 탐지 린터(Knip, DCM,
  dead_code_analyzer), ② 영향 분석을 PR·서비스 단위로 붙인 도구(ContextQA, Augment
  Code), ③ 모노레포 빌드의 affected-only 실행(Turborepo, Nx, Bazel).
- **2026-08~09 사이 Dart 네이티브 신규 경쟁 도구가 넷 등장했다**: undead(Dart 팀
  Kevin Moore), ciach(LeanCode), dallow, dart_sentinel. "Dart에서 제대로 된 dead
  code 도구" 포지션은 더 이상 빈틈이 아니며 단일 기능으로는 차별화되지 않는다.
- "수정 전에 사람이 읽는 사전 점검 + AI가 호출하는 질의 도구(MCP/스킬) + 런타임에서야
  드러나는 의존성 검증"을 **하나의 오픈소스 CLI로 묶은 사례는 여전히 확인되지
  않는다.** dartograph의 방어력은 개별 기능이 아니라 이 결합과 근거(witness) 계약에 있다.
- 이번 세션에서 네 갭을 메웠다: `deps`(pubspec 의존성 위생 감사), `dead --closed-app`
  (독립 앱 모드), MCP resources/prompts, build_runner·JS/FFI·sealed 정밀도. 남은 갭은
  중복 코드 탐지, 함수 수준 복잡도, IDE 표면이다.
- **2026-09-18 추가 검증(ultra-research, Claude+Codex 2트랙·63개 소스)**: 직전 문단의
  "남은 갭" 셋은 이후 전부 구현됐다(`dup` 0.12.0, `metrics` complexity 0.12.0, IDE
  플러그인). 새로 확인한 경쟁자로 dcq_standalone(BSD-3, 375+ 룰 + dead-code +
  모노레포)이 있고, DCM의 무료 플랜은 `check-unused-code`·`check-dependencies`를
  **제외**한다(Pro+ 게이트) — dartograph와 가장 겹치는 DCM 명령이 유료라는 사실이
  확인됐다. 공식 `dart_mcp_server` 1.1.1(24도구)에는 사망코드·그래프·영향 도구가
  없어 경쟁이 아니라 보완 관계다. env/dart-define 도구(dart_define, define_env)는
  선언된 변수의 코드젠·검증이며, 코드가 실제로 읽는 입력을 정적 탐지해 환경과 대조하는
  출시 도구는 조사 범위에 없었다.

## 2. 방법과 한계

- 근거는 공개 문서·블로그·가격 페이지이며, 링크는 재확인한 것과 이전 세션이 확인한 것을
  구분해 표기한다(§5).
- 유료 제품의 내부 알고리즘, 비공개 로드맵, 실사용 벤치마크는 확인하지 않았다.
- 성능 수치는 도구마다 대상 저장소가 달라 직접 비교하지 않는다. 이 문서는 "기능이 어디에
  있는가"를 다루고, "얼마나 빠른가"는 dartograph 자체 측정으로만 주장한다.

## 3. 지형

| 도구 | 생태계 | 핵심 제공 | 영향 사전 점검 | AI 질의 노출 | 런타임 의존 검증 | 가격 |
|---|---|---|---|---|---|---|
| Knip | JS/TS | 미사용 파일·의존성·export | 부분(변경 파일 기준) | 있음(VS Code 확장 내장 MCP 서버) | 없음 | 오픈소스 |
| Serena | 언어 무관(LSP) | 시맨틱 검색·편집·리팩터링 | 없음 | 있음(MCP 툴킷) | 없음 | 오픈소스 |
| ContextQA Impact Analysis | SaaS | PR 단위 영향 테스트·위험 점수 | 있음(CI 실행) | 미확인 | 없음 | 상용 SaaS |
| Augment Code | SaaS | 서비스 간 시맨틱 영향 분석 | 있음 | 있음(에이전트 제품) | 없음 | 상용 SaaS |
| DCM | Dart/Flutter | 미사용 코드·파일·lint·metrics·deps·duplication | 없음 | 없음 | 없음 | 무료 티어 50k LOC(미사용 파일·l10n·exports만); `check-unused-code`·`check-dependencies`는 Pro+ 유료 |
| dead_code_analyzer | Dart/Flutter | 미사용 코드 탐지 | 없음 | 없음 | 없음 | 오픈소스 |
| undead | Dart/Flutter | analyzer 도달성·open/closed 모드·build.yaml/test/@JS 어댑터 | 없음 | 스킬(`npx skills add`) | 없음 | 오픈소스 |
| ciach | Dart/Flutter | LSP 기반 미사용 코드 + `--remove` 삭제 | 없음 | 없음 | 없음 | 오픈소스 |
| dallow | Dart/Flutter | dead-code·pubspec 드리프트·중복 블록·복잡도 | 없음 | 없음 | 없음 | 오픈소스 |
| dart_sentinel | Dart/Flutter | analysis server 플러그인·35룰·MCP 10도구·Claude Code hooks | 파일 단위(hot spots) | 있음(MCP·hooks·VS Code) | 없음 | 오픈소스 |
| dcq_standalone | Dart/Flutter | 375+ 린트 룰 + `dead-code`(모노레포·nearly-unused·low-usage-deps) | 없음 | 없음 | 없음 | 오픈소스(BSD-3) |
| dependency_validator | Dart | missing·under/over-promoted·unused deps·pub workspace | 없음 | 없음 | 없음 | 오픈소스 |
| lakos | Dart | 파일 단위 라이브러리 그래프 dot/json·사이클·metrics | 없음 | 없음 | 없음 | 오픈소스 |
| pubviz | Dart | 패키지(pubspec) 의존 시각화 dot/mermaid | 없음 | 없음 | 없음 | 오픈소스 |
| `dart analyze`·`unreachable_from_main` | Dart(SDK 내장) | private 미사용 선언·main 포함 라이브러리 내부 도달성 | 없음 | — | 없음 | SDK 포함 |
| dart_mcp_server (공식) | Dart/Flutter | SDK 내장 MCP 24도구(analyze·lsp·pub·tests·DTD) | 없음 | 있음(MCP) | 없음 | 오픈소스(SDK 포함) |
| dart_define·define_env | Dart/Flutter | env/define 선언 → 설정 코드젠·필수값 검증 | 없음 | 없음 | 선언 기반만(코드가 읽는 입력을 탐지하지 않음) | 오픈소스 |
| GlassWing | Flutter/Android(학술) | Dart↔Java 암시 호출 정적분석 프로토타입(ASE'25) | 해당 없음 | 없음 | 없음 | 연구 |
| kivgraph | 다언어(Dart 포함) | 크로스-레포 영속 그래프 DB·MCP | 있음(`get_blast_radius`) | 있음(MCP) | 없음 | 오픈소스 |
| Periphery | Swift | 미사용 코드 | 없음 | 없음 | 없음 | 오픈소스 |
| Turborepo / Nx / Bazel | 모노레포 빌드 | 변경 영향분만 실행·캐시 | 있음(빌드 그래프) | 없음 | 없음 | 오픈소스/상용 혼합 |
| Semgrep 등 | 다언어 | 보안 정적 분석 | 부분 | 부분 | 없음 | 오픈소스/상용 혼합 |
| cartograph | Swift | 의존 그래프·근거 질의 CLI | 자매 도구(별도) | 있음 | 별도 계약 | 오픈소스 |
| **dartograph** | **Dart/Flutter** | **의존 그래프·근거 질의 + `impact` + `runtime` + `mcp`** | **있음(수정 전, 심볼·호출 지점·테스트·위험도)** | **있음(MCP + 에이전트 스킬)** | **있음(동적 로딩·환경변수·설정·에셋·외부 자원)** | **MIT, 영구 무료** |

## 4. 차별점과 갭

### 4.1 차별점

1. **Dart 네이티브 + 근거 기반.** 텍스트 검색이 아니라 `package:analyzer`의 해석 결과를
   쓰고, 모든 답에 witness(근거 경로)를 붙인다. 삭제 판정을 내리지 않고 미도달·미발견·
   분석 불완전성을 구분한다(제품 계약). ciach는 `--remove`로 삭제를 수행하고 DCM은
   fix-from-CLI를 판다 — 삭제 금지는 선택이 아니라 dartograph의 계약이다.
   2026-09-18 추가: ciach는 도달성이 아니라 LSP `textDocument/references` 검색이다 —
   죽은 코드만 참조하는 선언은 여전히 "참조 있음"으로 남아 잡지 못한다. SDK 내장
   `unreachable_from_main` 린트도 `main`을 포함한 라이브러리(와 parts) 내부에서만
   도달성을 걷는다(라이브러리 로컬, stable since 3.1) — 프로젝트 전체·패키지 간
   심볼 도달성은 어느 쪽도 하지 않는다.
2. **세 요구의 결합.** "수정 전 사전 점검" + "AI 질의 도구" + "런타임 의존 검증"을 한 CLI로
   묶은 오픈소스는 확인되지 않았다. 경쟁 도구는 보통 이 중 하나만 한다. 심볼 단위 영향
   심볼·호출 지점·관련 테스트·위험도·coverage를 한 문서로 내는 것은 여전히 유일하다
   (dart_sentinel의 impact는 파일 단위 hot spot 목록이다). 공식 `dart_mcp_server`의
   24도구는 분석 실행·LSP·테스트·pub 관리 같은 개발 액션이며 사망코드·그래프·영향
   도구가 없어 dartograph의 읽기 전용 근거 질의와 보완 관계다.
3. **영구 무료·상업 이용 허용.** DCM 무료 플랜(1석·50k LOC·100룰)은 "미사용 파일·
   unused l10n·exports 완결성"까지만 포함하고, dartograph와 가장 겹치는
   `check-unused-code`(선언 단위)와 `check-dependencies`는 Pro+ 게이트다.
   fallow(TS/JS)는 런타임 실행 증거 레이어를 유료로 묶었다 — dartograph의 `runtime`
   검증은 무료다.
4. **에이전트 소비를 전제로 한 계약.** MCP 도구 결과의 스키마·종료 코드가 CLI와 같고,
   생성 스킬이 질의 순서를 안내한다. 도구 외에 `dartograph://usage`·`skill`·`config`
   리소스와 `impact-precheck`·`dead-code-review`·`dependency-audit` 프롬프트를 노출해
   Knip·dart_sentinel이 먼저 연 표면(도구만이 아닌 프로토콜 전체)과 파리티를 맞췄다.

### 4.2 갭과 리스크(정직하게)

- ~~중복 코드 탐지~~ — `dup` 명령으로 해소(0.12.0, 토큰 shingle 기반).
- ~~함수 수준 복잡도~~ — `metrics` complexity·hotSpots로 해소(0.12.0).
- **IDE 통합 깊이.** dart_sentinel은 analysis server 플러그인으로 실시간 진단·quick
  fix를 준다. dartograph도 `editors/analysis_plugin/`의 analysis server 플러그인이
  `dead`/`dup` 진단과 `dartograph:ignore` quick fix를 낸다 — 다만 CLI 결과를
  파일 위치로 옮기는 수준이며 실시간 AST 기반 quick fix 전체와는 결이 다르다.
- **모노레포 스캔 표면.** dallow는 `--recursive`로 워크스페이스를 한 번에 훑는다.
  dartograph는 패키지 하나를 분석하고 `--project`/workspace 감지는 `bridges`에만 있다.
  2026-09-18 추가: dcq_standalone은 멀티 패키지 인자로 모노레포 dead-code를 명시
  지원하고, dependency_validator는 pub workspace를 네이티브 지원한다 — 워크스페이스
  인식은 더 흔한 기대 기능이 됐다. (부분 구현) pub 워크스페이스 **멤버**는
  `<package-root>`로 직접 분석되고 analyzer가 루트 package_config를 공유한다.
  루트를 직접 지정하면 선언된 멤버가 `workspace-members-not-indexed` 한계로
  나열된다. 남은 갭: 루트에서 하위 패키지를 한 번에 집계하는 표면은 아직 없다.
- **영향 → 테스트 실행 연결.** (구현) `impact --format test-list`가 영향받는
  테스트 라이브러리 경로를 한 줄 하나씩 내 `dart test` 인자로 곧바로 쓸 수 있다
  (`--limit` 영향 없이 전체 유지). JS 생태계는 tia-js·sniffler 같은 test-impact
  실행 도구가 이미 성숙해 있다 — dartograph는 실행 대신 선택 목록을 낸다.
- **GRAPH-EXCHANGE 스펙의 공개 문서 부재.** `bridges`는 크로스랭귀지 채널 사실을
  만들지만, 조인 계약(GRAPH-EXCHANGE v1/v2)의 스펙 문서·예제가 저장소 밖 사용자에게
  열려 있지 않다. 채택 경로가 isthmus 자매 도구에 갇혀 있다.
- **런타임 검증의 신호 대 잡음.** 자기 저장소 기준 `config` 탐지의 다수가 CLI 인자 경로라
  신호가 약하다. 오탐을 줄이는 보수적 판정이 계속 필요하다(`--execute`·미판정 사유).
- **`dart install` 실측 완료(2026-09, Dart 3.13.3/macOS arm64).**
  `dart install 'dartograph@{path: <절대경로>}'`가 AOT 바이너리를 생성·설치하고,
  설치본 `--version`→`dartograph 0.10.0`, `dead --kinds file`→발견·종료 1을 확인했다.
  상대 `path` 지정자(`{path: .}`)는 SDK 헬퍼 패키지 이름 제약으로 실패한다.
  문서는 doc/USAGE.md 설치 절 참조.

## 5. 출처

2026-09-18 세션(ultra-research, Claude+Codex 2트랙 교차검증)에 확인한 것:

- DCM 플랜 게이트 — Free(1석·50k LOC·100룰)는 미사용 파일·l10n·exports까지만;
  `check-unused-code`·`check-dependencies` 문서 페이지는 Pro+ 배지.
  https://dcm.dev/pricing/ , https://dcm.dev/docs/cli/code-quality-checks/unused-code/ ,
  https://dcm.dev/docs/cli/code-quality-checks/check-dependencies/
- `unreachable_from_main` — 라이브러리 로컬 도달성(main 포함 라이브러리+parts만),
  stable since 3.1. https://dart.dev/tools/linter-rules/unreachable_from_main ,
  https://github.com/dart-lang/sdk/blob/main/pkg/linter/lib/src/rules/unreachable_from_main.dart
- `custom_lint` 아카이브(2026-03-24, GitHub 배너) → 공식 후계는 `analysis_server_plugin`
  (Dart 3.10+). https://github.com/invertase/dart_custom_lint ,
  https://dart.dev/tools/analyzer-plugins , https://pub.dev/packages/analysis_server_plugin
- 공식 `dart_mcp_server` 1.1.1 — 24도구 전수, 사망코드·그래프·영향 없음.
  https://pub.dev/packages/dart_mcp_server ,
  https://github.com/dart-lang/ai/blob/main/pkgs/dart_mcp_server/README.md
- ciach — LSP references + definition 이중 확인 방식, doc-only 분리, `--remove`.
  https://pub.dev/packages/ciach , https://github.com/leancodepl/ciach
- dcq_standalone/dart_code_quality(Bud-ro) — BSD-3, 375+ 룰, `dead-code` 모노레포·
  nearly-unused·low-usage-deps. https://pub.dev/packages/dcq_standalone ,
  https://github.com/Bud-ro/dart-code-quality
- dart_sentinel — 파일 단위 impact(`impact_analyzer`), MCP 10도구, ratchet.
  https://pub.dev/packages/dart_sentinel
- dependency_validator 5.x — missing/under/over-promoted/unused + pub workspace.
  https://pub.dev/packages/dependency_validator
- env/define 도구는 코드젠·선언 검증(dart_define, define_env).
  https://pub.dev/packages/dart_define , https://pub.dev/documentation/define_env/latest/
- GlassWing — Flutter↔Java 암시 호출 정적분석(ASE 2025, 연구 프로토타입).
  https://conf.researchr.org/details/ase-2025/ase-2025-papers/137/GlassWing-A-Tailored-Static-Analysis-Approach-for-Flutter-Android-Apps
- pubviz 6.3.0 — 활발(kevmoo.com). https://pub.dev/packages/pubviz
- JS test-impact 실행 도구: tia-js, sniffler, ast-impact-mapper-mcp.
  https://github.com/psturc/tia-js , https://www.npmjs.com/package/sniffler
- SonarQube Dart는 Developer Edition 이상, Semgrep Dart는 experimental, CodeQL은
  Dart 미지원. https://docs.semgrep.dev/supported-languages ,
  https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/
- dart_pubdev_mcp(pub.dev 레지스트리+AST 슬라이스+OSV), Flutter_MCP_Knowledge(9개
  분석기+공식 소스 인덱스). https://pub.dev/packages/dart_pubdev_mcp ,
  https://github.com/Saad0149/Flutter_MCP_Knowledge
- 반증된 주장: "Dart/Flutter 도구가 2026-07-16에 BSL로 전환" — 근거 없음, 채택 금지.

이번 세션(2026-09-16)에 재확인한 것:

- undead — analyzer 도달성, open/closed-app 모드, build.yaml·package:test·@JS
  어댑터, 에이전트 스킬. https://pub.dev/packages/undead ,
  https://kevmoo.com/ (도구 소개 글)
- ciach — LeanCode, analysis server(LSP) 구동, `--remove`, `dart install` 배포.
  https://pub.dev/packages/ciach , https://leancode.co/
- dallow — dead-code + pubspec 의존성 드리프트 + 중복 블록 + 순환 복잡도 + health
  score + `--recursive`. https://pub.dev/packages/dallow
- dart_sentinel — analysis server 플러그인, MCP 10도구·3리소스, Claude Code hooks,
  파일 단위 impact(hot spots), ratchet 모드. https://pub.dev/packages/dart_sentinel
- kivgraph — 크로스-레포 영속 그래프 DB, MCP `get_blast_radius`, Dart는 Dart
  Analysis Server 사용. https://pub.dev/packages/kivgraph
- Knip — 편집기 확장에 내장 MCP 서버 + `knip-configure` 프롬프트 + `knip://docs/`
  리소스. https://knip.dev/blog/for-editors-and-agents
- DCM 가격 — 무료 티어 "Up to 50k analyzed LOC". https://dcm.dev/pricing/
- fallow — dallow의 TS/JS 원조, 정적 분석 무료 + 유료 런타임 실행 증거 레이어.
  https://fallow.tools/

이전 세션(2026-09-14 AutoCoder)이 확인하고 기록한 것(재조사하지 않음):

- Knip MCP 패키지 https://www.npmjs.com/package/%2540knip%252Fmcp ,
  https://github.com/gtrias/knip-mcp-server
- Serena https://github.com/oraios/serena
- ContextQA Impact Analysis https://www.contextqa.com/platform/impact-analysis/
- DCM 미사용 코드 검사 https://dcm.dev/docs/cli/code-quality-checks/unused-code/
- dead_code_analyzer https://pub.dev/documentation/dead_code_analyzer/latest/
- Turborepo / Nx / Bazel affected-only CI
  https://daily.dev/blog/monorepo-turborepo-vs-nx-vs-bazel-modern-development-teams/ ,
  https://tianpan.co/forum/t/monorepos-at-scale-what-nx-turborepo-and-bazel-actually-deliver-honest-review/974
- Augment Code https://www.augmentcode.com/tools/microservices-impact-analysis
- OWASP 소스코드 분석 도구 목록 https://owasp.org/www-community/Source_Code_Analysis_Tools
- 학술(PR 기반 change impact analysis) https://link.springer.com/article/10.1007/s10664-024-10600-2
- 저장소 자체 조사: `doc/RESEARCH.md`(knip, dependency-cruiser, madge, cartograph,
  Periphery, DCM, lakos 비교)

## 6. 우선순위 백로그

| 순위 | 항목 | 근거 | 완료 판정 | 상태 |
|---|---|---|---|---|
| P0 | 증분 분석 + CI 게이트 | 요구 4, 대체재 대비 최대 열위 | 전체 분석 대비 실측 배수(목표 5배, 미달 시 실측 기재), CI 예시 워크플로 동작 | 출시(0.10.0 — warm 7.5배·leaf 1.9배·imported 약 1.0배). `.github/workflows/impact-precheck.yml`에 PR 트리거·PR 코멘트·SARIF·증분 캐시·검증 원장 예시 작성(CI 실행 미검증, 액션 SHA 고정) |
| P0 | 검증 원장(append-only JSONL) + `history` 조회 | 추적 가능성 요구 | 각 실행의 입력·버전·결과가 누적되고 덮어쓰기 불가 | 출시(0.10.0 — `--record <dir>`·`history --ledger`) |
| P1 | 런타임 오탐 추가 축소 | 4.2 신호 대 잡음 | 합성 픽스처 오탐 0, 미판정 사유 표기 | 완료(PR #108 — AOT `--execute` 해석·동명 API 오탐 차단·미판정 사유 노출 + 회귀 테스트) |
| P1 | MCP 스키마·예시 문서 강화 | Knip·Serena 선점 | 클라이언트 설정 예시 + 오류 코드 표 + 재현 호출 | 완료(doc/MCP.md에 도구 스키마·JSON-RPC 오류 코드 표·재현 호출 예시) |
| P1 | `deps` 의존성 위생 감사 | dallow `deps`·DCM `check-dependencies`·knip 미사용 deps — codebase intelligence 도구의 표준 기능 | 선언↔`package:` 관측 대조 4종 finding + 도구 계약(executables·build.yaml·analysis_options) 사용 인정 + limitation 보존 | 구현(0.11.0 — `deps` 명령·4종 finding·5형식·MCP `verify_run`, fixture·테스트 통과) |
| P1 | `dead --closed-app` | undead `--mode=closed-app` — 앱 시장(라이브러리보다 큰 사용자층) | 공개 API 보존만 끄고 나머지 루트 유지, limitation 명시, baseline 짝 | 구현(0.11.0 — `dead`·`baseline --write`·`--report-test-only`에 적용, `--report-redundant-public` 결합 거부) |
| P1 | MCP resources/prompts | Knip `knip://docs/`·`knip-configure`, dart_sentinel `sentinel://` 리소스 | `resources/list·read` + `prompts/list·get` + capabilities | 구현(0.11.0 — 정적 리소스 3종·프롬프트 3종, `-32002` 미지 URI) |
| P1 | 보존 정밀도: build_runner·JS/FFI·sealed | undead framework adapters | build.yaml 팩토리 루트, `externalBinding` 보존, sealed 하위 전이 구제 | 구현(0.11.0 — `RetentionReason.buildRunner`·`externalBinding`, `GraphNode.isSealed`, analyzer 14 `ClassBody` 순회 수정) |
| P2 | Flutter 프레임워크 바인딩(DI·bloc·router) 정밀도 | codegraph 17개 프레임워크 라우트 + `navigates` 간선 | DI/bloc/router가 참조하는 선언이 dead 도달성에서 누락되지 않을 것 | 측정 완료 — 실제 `get_it`·`bloc`과 스텁 픽스처에서 오탐 0, `impact --symbol`이 구현체에 도달. `visitNamedType`(타입 인자)·`visitInstanceCreationExpression`(생성)이 이미 간선을 만든다 — 별도 보존 사유 불필요, 회귀 `test/index/framework_bindings_test.dart`. 문자열/리플렉션 조회는 남는 한계 |
| P2 | 0.9.0 릴리스 패키징 | 오픈소스 배포 | 태그·CHANGELOG·`pub publish --dry-run` 통과 | 완료(게시 0.9.0, 태그 v0.9.0 = b2aad3a) |
| P2 | 다음 릴리스(0.10.0) 패키징 | 증분 발행 | 태그·CHANGELOG·dry-run | 완료(게시 0.10.0, 태그 v0.10.0 = 2b3a236) |
| P2 | 중복 코드 탐지 | dallow·DCM·fallow | 토큰/AST 수준 duplication + limitation | 구현(0.12.0 — `dup` 명령·토큰 shingle 기반 duplicate-block finding·`--min-tokens`·MCP `verify_run`, 리뷰 후보일 뿐 삭제 지시 아님) |
| P2 | 함수 수준 순환 복잡도 | dallow·DCM·dart_sentinel | `metrics`에 함수 복잡도 추가 | 구현(0.12.0 — `metrics` complexity·hotSpots 섹션, `thresholds.complexity` 게이트) |
| P2 | `dart install` AOT 설치 검증·문서화 | ciach 명시 지원 | 설치본으로 `--version`·`dead` 실측 + README 설치 절 | 완료(0.12.0 — AOT 설치·`--version`·`dead` 실측, USAGE·README 설치 절 갱신, 상대 path 제약 기록) |
| P3 | 에이전트별 AI 설정 생성(hooks·MCP) | dart_sentinel `setup-hooks`·`generate-ai-config`, codegraph 9개 에이전트 `install` | MCP 호출 없이 강제되는 훅 스크립트 + 여러 에이전트 배선 | 구현(0.12.0 — `setup` 명령. 이후 `--target claude|cursor|codex|opencode` 다중화 + `--uninstall` — claude는 PostToolUse 훅, cursor `.cursor/mcp.json`, opencode `opencode.json`, codex 전역 `$CODEX_HOME/config.toml`. 기존 키 보존·깨진 설정 보호) |
| P3 | IDE 표면(VS Code 확장·analysis server 플러그인) | dart_sentinel·Knip | 편집기 내 진단 | 구현(게시됨 — `ictechgy.dartograph` v0.1.0 Problems 진단 + `dartograph_analysis_plugin` v0.1.0 pub.dev 게시: `dartograph_dead_code`·`dartograph_duplicate_block` 진단·`dartograph:ignore` quick fix, `dart analyze`에서도 동작 확인. AST 수준 자동 수정은 미구현) |
| P2 | 영향 → 테스트 실행 연결 | tia-js·sniffler(JS test-impact 성숙), dart_sentinel 미지원 | `impact` 산출물이 `dart test` 선택 인자로 곧바로 쓰이는지(목록 포맷 또는 실행 연결), 종료 코드 계약 유지 | 구현(`impact --format test-list` — 한 줄 한 테스트 경로, `--limit` 영향 없음, 빈 목록 가드 문서화) |
| P2 | pub workspace·모노레포 스캔 표면 | dcq_standalone 멀티 패키지, dependency_validator workspace, dallow `--recursive` | 워크스페이스 루트에서 하위 패키지 분석 경로(단일 패키지 계약과 정합 여부 먼저 결정) | 부분 구현 — 멤버 직접 분석·조상 package_config 공유(캐시 지문·deps 감사·source_packages 포함), 루트 스캔 시 `workspace-members-not-indexed` 한계. 다중 패키지 집계는 미구현 |
| P2 | GRAPH-EXCHANGE 스펙·예제 공개 | bridges+isthmus 유일 결합, 채택 경로가 자매 도구에 갇힘 | 저장소 밖 소비자가 스펙 문서만으로 조인 구현 가능 | 구현(`doc/GRAPH-EXCHANGE.md` — 봉투·fact·정렬·조인 키·limitations·예제, 조인 계약 정본은 isthmus 링크) |
| P3 | SARIF·GitHub code scanning 연동 가이드 | DCM에도 SARIF 없음 — 결정적 SARIF가 차별점 | code scanning 업로드 예시 워크플로·문서 | 구현(USAGE `SARIF와 GitHub code scanning` 절 — 워크플로·`if: always()`·category 구분·상대 URI·무위치 결과 한계) |
