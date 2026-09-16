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
| DCM | Dart/Flutter | 미사용 코드·파일·lint·metrics·deps·duplication | 없음 | 없음 | 없음 | 무료 티어 50k LOC, 이후 유료 |
| dead_code_analyzer | Dart/Flutter | 미사용 코드 탐지 | 없음 | 없음 | 없음 | 오픈소스 |
| undead | Dart/Flutter | analyzer 도달성·open/closed 모드·build.yaml/test/@JS 어댑터 | 없음 | 스킬(`npx skills add`) | 없음 | 오픈소스 |
| ciach | Dart/Flutter | LSP 기반 미사용 코드 + `--remove` 삭제 | 없음 | 없음 | 없음 | 오픈소스 |
| dallow | Dart/Flutter | dead-code·pubspec 드리프트·중복 블록·복잡도 | 없음 | 없음 | 없음 | 오픈소스 |
| dart_sentinel | Dart/Flutter | analysis server 플러그인·MCP 10도구·Claude Code hooks | 파일 단위(hot spots) | 있음(MCP·hooks·VS Code) | 없음 | 오픈소스 |
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
2. **세 요구의 결합.** "수정 전 사전 점검" + "AI 질의 도구" + "런타임 의존 검증"을 한 CLI로
   묶은 오픈소스는 확인되지 않았다. 경쟁 도구는 보통 이 중 하나만 한다. 심볼 단위 영향
   심볼·호출 지점·관련 테스트·위험도·coverage를 한 문서로 내는 것은 여전히 유일하다
   (dart_sentinel의 impact는 파일 단위 hot spot 목록이다).
3. **영구 무료·상업 이용 허용.** DCM이 무료 티어를 50k LOC로 묶은 뒤 Dart 생태계에 남은
   빈틈을 겨냥한다. fallow(TS/JS)는 런타임 실행 증거 레이어를 유료로 묶었다 —
   dartograph의 `runtime` 검증은 무료다.
4. **에이전트 소비를 전제로 한 계약.** MCP 도구 결과의 스키마·종료 코드가 CLI와 같고,
   생성 스킬이 질의 순서를 안내한다. 도구 외에 `dartograph://usage`·`skill`·`config`
   리소스와 `impact-precheck`·`dead-code-review`·`dependency-audit` 프롬프트를 노출해
   Knip·dart_sentinel이 먼저 연 표면(도구만이 아닌 프로토콜 전체)과 파리티를 맞췄다.

### 4.2 갭과 리스크(정직하게)

- **중복 코드 탐지가 없다.** dallow·DCM·fallow가 토큰/AST 수준 duplication을 낸다.
  그래프 위의 근거 질의라는 제품 계약과는 다른 계열의 기능이라 도입 여부가 열려 있다.
- **함수 수준 복잡도가 없다.** `metrics`는 아키텍처 수준(CCD·instability)만 낸다.
  순환 복잡도는 dallow·DCM·dart_sentinel이 제공한다.
- **IDE 통합 깊이.** dart_sentinel은 analysis server 플러그인으로 실시간 진단·quick
  fix를 주고 VS Code 확장·Claude Code hooks가 있다. dartograph는 CLI·MCP가 중심이고
  편집기 확장은 없다(자매 cartograph와 같은 선택).
- **모노레포 스캔 표면.** dallow는 `--recursive`로 워크스페이스를 한 번에 훑는다.
  dartograph는 패키지 하나를 분석하고 `--project`/workspace 감지는 `bridges`에만 있다.
- **런타임 검증의 신호 대 잡음.** 자기 저장소 기준 `config` 탐지의 다수가 CLI 인자 경로라
  신호가 약하다. 오탐을 줄이는 보수적 판정이 계속 필요하다(`--execute`·미판정 사유).
- **`dart install` 실측 완료(2026-09, Dart 3.13.3/macOS arm64).**
  `dart install 'dartograph@{path: <절대경로>}'`가 AOT 바이너리를 생성·설치하고,
  설치본 `--version`→`dartograph 0.10.0`, `dead --kinds file`→발견·종료 1을 확인했다.
  상대 `path` 지정자(`{path: .}`)는 SDK 헬퍼 패키지 이름 제약으로 실패한다.
  문서는 doc/USAGE.md 설치 절 참조.

## 5. 출처

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
| P1 | 런타임 오탐 추가 축소 | 4.2 신호 대 잡음 | 합성 픽스처 오탐 0, 미판정 사유 표기 | 진행 중(결함 3건 수정 + 회귀 테스트) |
| P1 | MCP 스키마·예시 문서 강화 | Knip·Serena 선점 | 클라이언트 설정 예시 + 오류 코드 표 + 재현 호출 | 완료(doc/MCP.md에 도구 스키마·JSON-RPC 오류 코드 표·재현 호출 예시) |
| P1 | `deps` 의존성 위생 감사 | dallow `deps`·DCM `check-dependencies`·knip 미사용 deps — codebase intelligence 도구의 표준 기능 | 선언↔`package:` 관측 대조 4종 finding + 도구 계약(executables·build.yaml·analysis_options) 사용 인정 + limitation 보존 | 구현(미릴리스 — `deps` 명령·4종 finding·5형식·MCP `verify_run`, fixture·테스트 통과) |
| P1 | `dead --closed-app` | undead `--mode=closed-app` — 앱 시장(라이브러리보다 큰 사용자층) | 공개 API 보존만 끄고 나머지 루트 유지, limitation 명시, baseline 짝 | 구현(미릴리스 — `dead`·`baseline --write`·`--report-test-only`에 적용, `--report-redundant-public` 결합 거부) |
| P1 | MCP resources/prompts | Knip `knip://docs/`·`knip-configure`, dart_sentinel `sentinel://` 리소스 | `resources/list·read` + `prompts/list·get` + capabilities | 구현(미릴리스 — 정적 리소스 3종·프롬프트 3종, `-32002` 미지 URI) |
| P1 | 보존 정밀도: build_runner·JS/FFI·sealed | undead framework adapters | build.yaml 팩토리 루트, `externalBinding` 보존, sealed 하위 전이 구제 | 구현(미릴리스 — `RetentionReason.buildRunner`·`externalBinding`, `GraphNode.isSealed`, analyzer 14 `ClassBody` 순회 수정) |
| P2 | 0.9.0 릴리스 패키징 | 오픈소스 배포 | 태그·CHANGELOG·`pub publish --dry-run` 통과 | 완료(게시 0.9.0, 태그 v0.9.0 = b2aad3a) |
| P2 | 다음 릴리스(0.10.0) 패키징 | 증분 발행 | 태그·CHANGELOG·dry-run | 완료(게시 0.10.0, 태그 v0.10.0 = 2b3a236) |
| P2 | 중복 코드 탐지 | dallow·DCM·fallow | 토큰/AST 수준 duplication + limitation | 구현(미릴리스 — `dup` 명령·토큰 shingle 기반 duplicate-block finding·`--min-tokens`·MCP `verify_run`, 리뷰 후보일 뿐 삭제 지시 아님) |
| P2 | 함수 수준 순환 복잡도 | dallow·DCM·dart_sentinel | `metrics`에 함수 복잡도 추가 | 구현(미릴리스 — `metrics` complexity·hotSpots 섹션, `thresholds.complexity` 게이트) |
| P2 | `dart install` AOT 설치 검증·문서화 | ciach 명시 지원 | 설치본으로 `--version`·`dead` 실측 + README 설치 절 | 완료(미릴리스 — AOT 설치·`--version`·`dead` 실측, USAGE·README 설치 절 갱신, 상대 path 제약 기록) |
| P3 | Claude Code hooks·툴별 AI 설정 생성 | dart_sentinel `setup-hooks`·`generate-ai-config` | MCP 호출 없이 강제되는 훅 스크립트 | 구현(미릴리스 — `setup` 명령: PostToolUse 훅 스크립트·settings.json·`.mcp.json` 병합 설치, 기존 키 보존·깨진 설정 보호) |
| P3 | IDE 표면(VS Code 확장·analysis server 플러그인) | dart_sentinel·Knip | 편집기 내 진단 | 미착수 — CLI·MCP 중심 선택과 상충, 별도 결정 필요 |
