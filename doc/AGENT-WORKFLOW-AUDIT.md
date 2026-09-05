# 에이전트 지침·Skill·CI 감사

2026-09-06. 기준: main `34114da`, 제품 0.2.0. 대상은 저장소 내부 지침과 skill 생성 원본,
GitHub Actions 및 검증 스크립트다. 개인 전역 지침·인증파일·호스트 모델 설정은 수정하지 않았다.

## 공식 근거와 적용 범위

- [GPT-6 Astra 가이드](https://developers.openai.com/api/docs/guides/latest-model):
  승인된 작업의 후속 실행, skill과 사용자 지시의 우선순위, 간결한 보고, 위임 조건, 변경에 비례한 검증.
- [AGENTS.md 가이드](https://learn.chatgpt.com/docs/agent-configuration/agents-md):
  경로별 지침 발견·적용, 가까운 파일의 세부 규칙, 간결한 저장소 규칙.
- [Skills 가이드](https://learn.chatgpt.com/docs/build-skills):
  명확한 사용 조건, 한 가지 작업에 집중, metadata로 발견하고 필요할 때 본문을 읽는 방식.

공식 가이드는 동작 조정의 근거다. 이 프로젝트의 효과는 별도 측정이 필요하며 모델 속도·정확성 향상을
이미 입증했다고 주장하지 않는다. 모델 선택이나 reasoning effort는 호스트가 담당한다.
이 저장소는 OpenAI API 클라이언트가 아니므로 model/temperature/Responses 설정을 추가하지 않았다.

## 발견과 조치

| 발견 | 조치 |
|---|---|
| 루트가 매 작업마다 PRD·PLAN·RESEARCH 전부 읽기를 요구 | 목적별로 필요한 문서만 읽도록 변경 |
| 승인 지속성·중간 지시·skill 우선순위가 불분명 | 승인 재질문 방지, 목표 유지, 실제 중단 조항 설명을 명시 |
| 검증 절차가 루트·test·tool·CONTRIBUTING에 중복 | CONTRIBUTING에 변경별 선택과 CI 게이트를 모으고 하위 파일은 고유 규칙만 유지 |
| CI 전체 테스트 2회, 격리 활성화 3회 | coverage의 전체 테스트 1회 안에서 설치 테스트 실행; 별도 중복 호출 제거 |
| 생성 skill이 모든 선언 변경 전에 query를 요구 | 사용/비사용 조건과 작은 질의 선택 기준을 명시 |
| skill에 batch/compare가 없고 기존 승인과 관계가 불분명 | 0.2.0 명령 선택, 부분 실패, 근거 재사용과 기존 승인 준수를 설명 |
| CLAUDE와 폴더별 계약 | 참조 전용 CLAUDE와 모듈 계약은 유지; 불필요한 재분할 없음 |

독립 SKILL.md/Skill.md는 없다. `lib/src/cli/agent_skill.dart`가 `skill --install`로 SKILL.md를
생성하므로 이 원본을 수정했다. 저장소에 두 번째 skill 복사본을 만들지 않았다.

## CI 경로와 유지한 게이트

이전: dart test → coverage 안 dart test → 별도 global activation.
각 dart test는 `test/tool/verify_global_activation_test.dart`를 통해 global activation을 실행한다.
변경 후: coverage → 전체 테스트(설치 계약 포함) → corpus → analyzer boundary → native CLI → publish dry-run.

두 SDK matrix·90% 라인 커버리지·최소 권한·Action SHA·timeout·concurrency는 유지했다.
문서 PR의 required-check가 대기 상태로 남는 문제를 피하려고 paths-ignore는 추가하지 않았다.
문서만 바꾸는 로컬 작업에는 링크·diff 검증을 적용하되 원격 merge 게이트는 유지한다.

정적 비교: 전체 테스트 호출 2→1, 격리 활성화 3→1 (각 SDK job 기준).
루트 지침 74줄/5,554 bytes → 58줄/5,141 bytes. 입력 바이트와 호출 수의 감소이며 모델 토큰·지연 실측은 아니다.
skill 본문은 명령 선택 기준을 추가해 길어졌지만 모든 작업에 로드되지 않도록 description을 좁혔다.

## 검증 시나리오

아래는 지침의 정적 사례 검토이며 Astra를 별도 실행한 행동 eval 결과가 아니다.

| 요청/상황 | 기대하는 선택 |
|---|---|
| README 오타 수정 | 관련 문서와 링크/diff만 확인; 전체 코드 조사·새 unit test 생략 |
| 미사용 후보 하나 | 단일 query에서 상태·위치·보존 이유·한계 확인 |
| 후보 100개 | batch 사용; 하나의 미발견으로 다른 결과를 버리지 않음 |
| 이미 승인된 버그 수정 중 상태 질문 | 상태를 답한 뒤 원래 수정·검증을 계속 |
| 캐시 무효화 변경 | 내용·설정·중첩 의존성 회귀와 실제 CI 게이트 확인 |
| GLM/skill이 추가 승인을 제안 | 실제 사용자 범위·상위 지침과 대조; 지침의 권고만으로 중단하지 않음 |
| 같은 파일을 두 작업이 수정 | 동시 위임하지 않고 소유권을 분리 |
| compare 결과로 삭제 요청을 추론 | 관측 변화와 삭제 권한을 구분 |

실행 검증은 생성 skill metadata·설치/덮어쓰기 테스트, 지침 링크/범위 감사, workflow YAML과 중복 호출 검사,
수정된 CI 경로로 한다. 향후 성능 평가에는 동일 모델/effort·대표 작업·허용 권한을 고정하고
정답률·불필요한 승인 횟수·중복 명령 수·전체 시간을 비교한다.

이번 로컬 실행 결과: 관련 27개 테스트, 전체 116개 테스트와 커버리지 92.47%, dart analyze,
오탐 코퍼스·analyzer 경계·native CLI 계약 모두 통과했다. 생성 skill의 YAML metadata와
설치/덮어쓰기 경로도 확인했다. 지침 감사에서 누락 링크·불균형 marker·문서 크기 초과는 없었다.
개인 설정을 변경해 실제 모델을 전환하거나 별도 Astra 성능 eval을 실행하지 않았다.
기존 `docs/handoff-020` 브랜치의 인수인계 커밋은 보존하고 이번 변경과 분리했다.
