# 제품 코드 규칙

[루트 규칙](../AGENTS.md)을 따르며 제품 모듈 사이의 경계를 유지한다.

## 모듈 소유권

- src/core/: 그래프·ID·불변 snapshot·캐시 인터페이스. 다른 제품 모듈과 analyzer에 의존하지 않는다.
- src/index/: analyzer 타입을 core 사실로 변환하는 유일한 어댑터. [세부 규칙](src/index/AGENTS.md)을 따른다.
- src/analysis/: core 사실만 질의한다. analyzer·소스·Git을 직접 읽지 않는다.
  baseline 파일 입출력은 기존 BaselineStore 경계에 두며 분석 알고리즘과 섞지 않는다.
- src/export/: 결과를 직렬화한다. 새로운 보존·미도달 판정을 만들지 않는다.
- src/cli/: 인자·입출력·실패 분류·종료 코드. 분석 의미는 하위 모듈에 둔다.
- dartograph.dart: 지원할 라이브러리 API만 공개한다. analyzer 내부 타입은 노출하지 않는다.

## 질의와 근거 계약

- GraphSnapshot의 정점 중복·간선 endpoint 검증과 결정적 정렬을 보존한다. usage와 구조적 member 간선을 구분한다.
- query는 cartograph의 기존 SymbolQueryDocument 필드 의미를 유지한다. 미발견과 모호한 후보를 구분하고 임의 선택하지 않는다.
- SymbolQuerySession과 batch는 그래프·도달성·이웃 색인·baseline을 재사용한다. 요청 순서·중복·개별 상태를 보존한다.
- dead --explain의 미발견은 known: false와 코드 64다. 살아 있는 파일·멤버 보존은 실제 witness를 제시한다.
- --since는 전체 그래프를 분석한 뒤 보고 위치를 좁힌다. compare는 준비된 두 checkout을 비교한다.
  참조·루트 변화와 이전 경로를 보여주되 단일 원인의 증명으로 표현하지 않는다. rename은 삭제/추가다.
- 소스별 한계는 파일 수준 관측이다. 전역 영향 경고를 유지하고 다른 파일이나 특정 선언의 안전성을 추론하지 않는다.
- baseline은 정확한 finding 지문만 억제한다. 경로·이름 유사성으로 억제 범위를 넓히지 않는다.
- JSON 키·목록은 결정적이어야 한다. bridge 생성 시각과 `generated-code-staleness`의
  mtime 관측(USAGE에 선언) 같은 명시된 예외만 허용한다.
  GitHub Actions·SARIF·DOT·Mermaid의 각 출력 문법에 맞춰 escaping한다.
- CLI 코드는 0/1/2/64다. dead finding은 1, cycles/rules/metrics는 strict에서만 1이다.
  batch에 미발견이 있으면 64지만 모든 개별 결과를 반환한다. 변경 시 도움말·사용법·CLI 계약 테스트를 함께 갱신한다.
