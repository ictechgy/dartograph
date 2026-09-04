# dartograph

Dart/Flutter 코드베이스를 위한 질의 가능한 의존성 그래프. [cartograph](../cartograph)(Swift)의 자매 프로젝트다.

**MIT 라이선스이며 상업적 사용을 포함해 영구 무료다.** 유료 티어 · 라이선스 키 ·
좌석 수 · LoC 제한 · 텔레메트리 · 계정 로그인은 영원히 없다.

이름은 **Dart** + cartograph.

## 무엇을 하려는가

Flutter 의 미사용 코드 · 파일 검사는 DCM(구 dart_code_metrics)이 가지고 있고, DCM 은 2023 년에 유료로 전환했다. 무료 티어가 있지만 **1인 · 50k LoC 이하** 다. 팀이거나 그보다 큰 프로젝트면 돈을 내야 한다.

dartograph 는 그 자리를 **상업적 사용을 포함해 영구 무료(MIT)** 로 채운다. Periphery 가 상업화되며 남긴 자리를 cartograph 가 채운 것과 같은 이유다.

- `package:analyzer` — Dart 팀이 배포하는 공식 분석기 — 를 원천으로 쓴다. 텍스트 검색이 아니다
- 미사용 코드 · 파일 · 순환 의존 · 레이어 규칙 · 지표를 한 그래프 위에서 낸다
- 모든 판정에 근거를 붙인다. 삭제 판정은 내지 않는다
- 에이전트가 소비할 것을 전제로 `query` 와 `skill` 을 처음부터 갖춘다

세 자매 프로젝트 중 **가장 싸게 만들 수 있다.** 원천이 공식이고 안정적이며 활발하다(2026-09 기준 `analyzer` 14.3.0).

## 상태

**Phase 2 완료.** analyzer 그래프 위에서 보존 근거를 추적하고 `dead --explain`으로
도달 경로 또는 미도달 근거를 출력한다. 다음은 기존 코드베이스 도입 경로다.

| 문서 | 내용 |
|---|---|
| [`docs/PRD.md`](docs/PRD.md) | 무엇을 · 누구를 위해 · 어디까지 · 무엇을 하지 않을지 |
| [`docs/PLAN.md`](docs/PLAN.md) | 단계별 계획 |
| [`docs/RESEARCH.md`](docs/RESEARCH.md) | 확인된 사실 · 확인되지 않은 주장 · 출처 |
| [`docs/DECISION-analyzer.md`](docs/DECISION-analyzer.md) | analyzer 버전 · 정점 ID · 생성 코드 · 캐시 결정 |

## 라이선스

MIT. **상업적 사용을 포함해 영구 무료다.** 이것은 이 프로젝트의 기능이지 각주가 아니다 — README 첫 화면에 적고, 라이선스를 바꾸지 않겠다는 약속을 `docs/PRD.md` 에 남긴다.
