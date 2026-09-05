# 검증 도구 규칙

[루트 규칙](../AGENTS.md)을 따른다. 명령 선택과 CI 게이트 구성은 [CONTRIBUTING.md](../CONTRIBUTING.md)가 정본이다.

- 실제 종료 코드를 보존한다. 스캐너 부재·실패를 빈 결과나 성공으로 바꾸지 않는다.
- verify-cli-contract.sh는 native executable 또는 명시된 설치 바이너리를 검사한다. 새 CLI는 정상/실패 경로를 추가한다.
- verify-global-activation.sh는 package copy와 별도 PUB_CACHE를 사용한다. 사용자의 전역 설치를 변경하지 않는다.
- temporary directory는 mktemp 등으로 만들고 소유한 정확한 경로만 정리한다. 셸 인자는 배열·인용으로 전달한다.
- benchmark_query.dart는 결과 동등성도 검사한다. 입력 크기·SDK·측정 조건을 기록한다.
- verify_bridge_query.dart는 명시된 isthmus 경로를 받아 합성 왕복을 검증한다. 의존 도구를 임의 설치하지 않는다.
- Bash/POSIX, rg·dart 등 필요한 실행 환경은 로컬과 CI 양쪽에서 확인한다.
