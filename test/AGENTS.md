# 테스트 규칙

[루트 규칙](../AGENTS.md)을 따르고 [제품 계약](../lib/AGENTS.md)을 검증한다.
검증 명령·커버리지·실행 빈도의 정본은 [CONTRIBUTING.md](../CONTRIBUTING.md)다.

- 의미가 바뀌는 버그 수정은 실패 재현 후 최소 수정으로 통과시킨다. 문구만 검사하는 테스트를 추가하지 않는다.
- 기대값은 손으로 검증한 fixture·리터럴을 사용한다. 제품 helper로 정답까지 계산하지 않는다.
- core/·index/·analysis/·export/·cli/는 제품 모듈을 따른다. analyzer 타입은 index 테스트 안에 둔다.
- 오탐은 보고/보존 양쪽을 검증한다. suppression 확대로 실패를 숨기지 않는다.
- 이름 변경·호출 제거/복원·미해석 입력은 실제 analyzer를 통과시켜 관측 차이를 확인한다.
- batch의 순서·중복·모호함·부분 미발견·baseline과 단일 질의 동등성을 확인한다.
- compare의 간선/root 제거·member witness·전후 한계를 검사한다. 그래프 입력 순서를 바꿔 결정성을 확인한다.
- bridge의 provenance·scope·동적/누락 입력·UTF-8 위치를 검사하고 합성/실제 compiler 검증을 구분한다.
- 분석 fixture를 런타임으로 실행하거나 실제 사용자 프로젝트를 수정하지 않는다.
  임시 디렉터리·격리 캐시·변경한 cwd를 정리/복원하고 offline 의존성의 선행 조건을 확인한다.
