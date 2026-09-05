# Fixture 규칙

[루트 규칙](../AGENTS.md)을 따른다. 이 폴더의 미사용 선언과 순환은 검증 입력이며 정리 대상이 아니다.

- false_positive_corpus/는 실제 meta·pragma·plugin·생성 코드 등을 사용한 보존/미도달 반례다.
- phase5_contract/는 cycles/rules/metrics와 batch의 종료 코드를 검증하는 입력이다.
- 기대 결과를 바꾸면 소비하는 테스트와 tool/verify-*.sh를 함께 확인한다.
- intentional dead 코드를 사용하게 만들거나 순환을 제거해 제품 버그를 숨기지 않는다.
- fixture의 생성 파일은 의도된 검증 자료다. 빌드 산출물 청소에서 실제 소스와 구분한다.
- pub get이 필요하면 임시 복사본에서 실행한다. .dart_tool과 pubspec.lock은 커밋하지 않는다.
- fixture는 제품 자기 분석과 게시 패키지에서 제외되어야 한다. 제외 규칙 변경 시 양쪽을 확인한다.
