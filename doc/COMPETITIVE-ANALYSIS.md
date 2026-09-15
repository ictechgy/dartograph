# 경쟁·대체재 분석과 dartograph의 위치

이 문서는 dartograph가 어떤 문제를 누구와 나눠 갖고 있는지, 어디가 실제로 비어 있는지를
기록한다. 출처는 공개 문서이며, 확인한 시점을 함께 적는다. 확인하지 않은 주장은 넣지 않는다.

## 1. 요약

- 대체재는 크게 세 무리다. ① 미사용 코드·의존성 탐지 린터(Knip, DCM,
  dead_code_analyzer), ② 영향 분석을 PR·서비스 단위로 붙인 도구(ContextQA, Augment
  Code), ③ 모노레포 빌드의 affected-only 실행(Turborepo, Nx, Bazel).
- Dart/Flutter 생태계에서 그래프 기반 분석을 제공하는 것은 DCM(유료 전환)과
  dead_code_analyzer(pub.dev) 정도로 얕다. Dart 네이티브이면서 **근거(witness)를 함께
  내는** CLI는 확인되지 않는다.
- "수정 전에 사람이 읽는 사전 점검 + AI가 호출하는 질의 도구(MCP/스킬) + 런타임에서야
  드러나는 의존성 검증"을 **하나의 오픈소스 CLI로 묶은 사례는 확인되지 않는다.** 이 묶음이
  현재 dartograph의 가장 좁고 뚜렷한 차별점이다.
- 남은 정직한 약점은 **검증 원장(실행 이력의 append-only 기록) 부재**다. 증분 분석은
  구현됐지만(미릴리스) 널리 import되는 파일을 바꾸면 폐쇄가 전체에 가까워 이득이 줄고,
  affected-only 실행을 제품화한 모노레포 빌드 도구와는 달리 검증 원장이 없다(→
  `doc/DECISION-incremental.md` 및 `HANDOFF-PROGRESS.md` P0).

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
| DCM | Dart/Flutter | 미사용 코드·파일·lint·metrics | 없음 | 없음 | 없음 | 무료 티어 50k LOC, 이후 유료 |
| dead_code_analyzer | Dart/Flutter | 미사용 코드 탐지 | 없음 | 없음 | 없음 | 오픈소스 |
| Periphery | Swift | 미사용 코드 | 없음 | 없음 | 없음 | 오픈소스 |
| Turborepo / Nx / Bazel | 모노레포 빌드 | 변경 영향분만 실행·캐시 | 있음(빌드 그래프) | 없음 | 없음 | 오픈소스/상용 혼합 |
| Semgrep 등 | 다언어 | 보안 정적 분석 | 부분 | 부분 | 없음 | 오픈소스/상용 혼합 |
| cartograph | Swift | 의존 그래프·근거 질의 CLI | 자매 도구(별도) | 있음 | 별도 계약 | 오픈소스 |
| **dartograph** | **Dart/Flutter** | **의존 그래프·근거 질의 + `impact` + `runtime` + `mcp`** | **있음(수정 전, 심볼·호출 지점·테스트·위험도)** | **있음(MCP + 에이전트 스킬)** | **있음(동적 로딩·환경변수·설정·에셋·외부 자원)** | **MIT, 영구 무료** |

## 4. 차별점과 갭

### 4.1 차별점

1. **Dart 네이티브 + 근거 기반.** 텍스트 검색이 아니라 `package:analyzer`의 해석 결과를
   쓰고, 모든 답에 witness(근거 경로)를 붙인다. 삭제 판정을 내리지 않고 미도달·미발견·
   분석 불완전성을 구분한다(제품 계약).
2. **세 요구의 결합.** "수정 전 사전 점검" + "AI 질의 도구" + "런타임 의존 검증"을 한 CLI로
   묶은 오픈소스는 확인되지 않았다. 경쟁 도구는 보통 이 중 하나만 한다.
3. **영구 무료·상업 이용 허용.** DCM이 무료 티어를 50k LOC로 묶은 뒤 Dart 생태계에 남은
   빈틈을 겨냥한다.
4. **에이전트 소비를 전제로 한 계약.** MCP 도구 결과의 스키마·종료 코드가 CLI와 같고,
   생성 스킬이 질의 순서를 안내한다.

### 4.2 갭과 리스크(정직하게)

- **증분 분석은 구현됐지만 미릴리스이고, 검증 원장이 없다.** 파일별 사실 캐시와
  `--incremental <dir>`가 색인 명령에 배선됐고 산출물은 전체 분석과 byte 동일하다.
  다만 널리 import되는 파일을 바꾸면 역방향 폐쇄가 전체에 가까워 이득이 줄고(실측
  0.94~1.04배), 실행 이력을 append-only로 남기는 원장은 아직 없다.
- **MCP는 이미 선점됐다.** Knip·Serena가 먼저 나갔다. 표준화된 스키마, 명확한 오류 코드,
  재현 가능한 호출 예시가 없으면 "또 하나의 MCP 서버"로 읽힌다.
- **IDE 통합 깊이.** 상용 도구는 편집기 안에서 즉시 보여준다. dartograph는 CLI·MCP가
  중심이고 편집기 확장은 없다(자매 cartograph와 같은 선택).
- **런타임 검증의 신호 대 잡음.** 자기 저장소 기준 `config` 탐지의 다수가 CLI 인자 경로라
  신호가 약하다. 오탐을 줄이는 보수적 판정이 계속 필요하다(`--execute`·미판정 사유).

## 5. 출처

이번 세션(2026-09-14)에 재확인한 것:

- Knip — 편집기 확장에 내장 MCP 서버. https://knip.dev/blog/for-editors-and-agents
- DCM 가격 — 무료 티어 "Up to 50k analyzed LOC". https://dcm.dev/pricing/

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
| P0 | 증분 분석 + CI 게이트 | 요구 4, 대체재 대비 최대 열위 | 전체 분석 대비 실측 배수(목표 5배, 미달 시 실측 기재), CI 예시 워크플로 동작 | 증분 구현(미릴리스 — warm 7.5배·leaf 1.9배·imported 약 1.0배). CI 예시는 수동 트리거로 작성(실행 미검증) |
| P0 | 검증 원장(append-only JSONL) + `history` 조회 | 추적 가능성 요구 | 각 실행의 입력·버전·결과가 누적되고 덮어쓰기 불가 | 구현(미릴리스 — `--record <dir>`·`history --ledger`, 테스트·CLI 계약 통과) |
| P1 | 런타임 오탐 추가 축소 | 4.2 신호 대 잡음 | 합성 픽스처 오탐 0, 미판정 사유 표기 | 진행 중(결함 3건 수정 + 회귀 테스트) |
| P1 | MCP 스키마·예시 문서 강화 | Knip·Serena 선점 | 클라이언트 설정 예시 + 오류 코드 표 + 재현 호출 | 부분(doc/MCP.md에 설정 예시·오류 표가 있고, 재현 호출은 보강 여지) |
| P2 | 0.9.0 릴리스 패키징 | 오픈소스 배포 | 태그·CHANGELOG·`pub publish --dry-run` 통과 | 완료(게시 0.9.0, 태그 v0.9.0 = b2aad3a) |
| P2 | 다음 릴리스(0.10.0) 패키징 | 증분 발행 | 태그·CHANGELOG·dry-run | 미착수(증분은 브랜치에만 있음) |
