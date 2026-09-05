# 테스트 규칙

[루트 규칙](../AGENTS.md)과 [제품 계약](../lib/AGENTS.md)을 검증한다.
후자는 테스트 대상의 계약을 설명하는 참조이며 테스트 폴더의 상위 스코프는 아니다.

- 행동 변경은 실제 실패하는 회귀 테스트로 원인을 확인한 뒤 최소 구현으로 통과시킨다.
  테스트 실행 자체의 오류와 제품 결함을 구분한다. 문서만의 변경에는 구현을 복제하는 테스트를 만들지 않는다.
- 기대값은 손으로 검증한 fixture·리터럴을 사용한다. 제품 helper로 정답까지 계산하지 않는다.
- core/·index/·analysis/·export/·cli/는 제품 모듈을 따른다. analyzer 타입은 index 테스트 안에서만 사용한다.
- 오탐 수정은 보고해야 할 사례와 보존해야 할 사례를 함께 검증한다. 광범위한 suppression으로 테스트를 통과시키지 않는다.
- index/evidence_mutation_test.dart처럼 호출 제거/복원·이름 변경·미해석 입력을 실제 analyzer에 통과시켜 의미를 확인한다.
- 그래프 입력 순서를 바꿔 결정성을 확인한다. batch는 단일 결과와 동등해야 하며 순서·중복·모호함·부분 미발견·baseline을 검사한다.
- compare는 간선 제거뿐 아니라 root 제거·member witness·전후 한계도 검증한다. 없는 ID를 미도달로 확정하지 않게 한다.
- bridge는 provenance·scope·동적/누락 입력·UTF-8 위치를 검사한다. 합성 Swift fact 검증과 실제 Swift 컴파일러 검증을 구분한다.
- 분석 fixture의 소스를 런타임 코드로 실행하거나 실제 사용자 프로젝트를 수정하지 않는다. 임시 fixture와 격리 캐시를 사용하고 teardown에서 정리한다.
  임시 작업 디렉터리를 바꿨으면 반드시 복원하며, pub get --offline의 선행 캐시 조건을 확인한다.
- tool/check-coverage.sh로 전체 테스트와 제품 라인 커버리지 90%를 확인한다.
- 종료 코드는 [CLI 계약 스크립트](../tool/verify-cli-contract.sh)로 컴파일된 실행 파일에서도 확인한다.
  설치 경계는 [격리 활성화 검증](../tool/verify-global-activation.sh)으로 확인한다.
