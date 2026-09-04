# test 작업 규칙

루트 `AGENTS.md`와 `lib/AGENTS.md`의 계약을 실제 행동으로 검증한다.

- 모든 행동 변경은 실패하는 테스트를 먼저 실행해 RED 원인을 확인한 다음 최소 구현으로 GREEN을 만든다.
- 기대값은 제품 코드로 계산하지 않고 손으로 검증한 리터럴이나 fixture로 둔다.
- `test/core/`, `test/index/`, `test/analysis/`, `test/export/`, `test/cli/`는 제품 모듈을 그대로 따른다.
- analyzer fixture는 `test/index/` 아래에 두고, analyzer 타입을 다른 모듈 테스트로 흘리지 않는다.
- JSON과 그래프 출력은 입력 순서가 달라도 byte-for-byte 같아야 한다.
- 오탐 코퍼스는 보고해야 하는 사례와 보고하지 않아야 하는 사례를 모두 실행한다.
- 전체 테스트 뒤 `tool/check-coverage.sh`의 제품 코드 라인 커버리지 90% 게이트를 통과한다.
- CLI 종료 코드는 단위 상수만 비교하지 않고 `tool/verify-cli-contract.sh`로 빌드된 실행 파일을 호출해 검증한다.
