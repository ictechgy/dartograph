# 검증 도구 규칙

[루트 규칙](../AGENTS.md)을 따른다. 이 폴더는 개발·배포 검증이며 제품 CLI의 분석 의미를 소유하지 않는다.

- 명령의 실제 종료 코드를 검사한다. 스캐너 부재·실패가 빈 finding이나 성공으로 바뀌면 안 된다.
- check-coverage.sh는 전체 테스트를 포함한다. 같은 검증을 근거 없이 반복하지 않는다.
- verify-cli-contract.sh는 빌드한 바이너리 또는 명시적으로 전달한 설치 바이너리를 실행한다.
  새 공개 명령은 정상·오류 경로와 출력 계약 테스트를 함께 추가한다.
- verify-global-activation.sh는 별도 package copy와 PUB_CACHE를 사용한다. 실제 사용자의 전역 설치를 변경하지 않는다.
- temporary directory는 mktemp 등으로 만들고 정확한 소유 경로만 정리한다. 셸 인자는 배열·인용으로 전달한다.
  SDK 디렉터리나 광범위한 사용자 경로를 삭제 대상으로 삼지 않는다.
- benchmark_query.dart는 결과 동등성도 검사한다. 합성 수치는 입력 크기·SDK·측정 조건과 함께 보고한다.
- verify_bridge_query.dart는 명시된 isthmus 실행 경로를 받아 합성 왕복을 검증한다. 자동 다운로드·설치를 추가하지 않는다.
- shell 검증은 Bash/POSIX 도구에 의존한다. OS와 rg·dart의 존재를 확인하고 CI에도 선행 조건을 명시한다.
