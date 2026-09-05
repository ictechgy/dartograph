# Index 어댑터 규칙

[제품 모듈 규칙](../../AGENTS.md)을 따른다. package:analyzer import는 제품 코드 중 이 폴더에만 둔다.

- analyzer는 pubspec.yaml의 검증된 14.3.x 범위를 유지한다. API는 설치된 소스와 실제 컴파일로 확인한다.
- 심볼의 library URI·선언 경로 ID와 source 위치를 구분한다. part는 호스트 library에 귀속된다.
  익명 extension의 source·offset 보조 ID는 편집에 따라 달라질 수 있으므로 영구 식별자로 과장하지 않는다.
- 프로젝트 경로는 canonical root 기준 project: ID로 정규화한다. OS 경로 구분자·symlink·루트 밖 경로를 검증한다.
- main은 lib/·bin/·example/의 여러 진입점을 보수적으로 보존한다. 구현되지 않은 entry-point 설정을 안내하지 않는다.
- 테스트·실제 meta annotation·정확한 pragma·override·public barrel API·plugin entry point의 보존 근거를 유지한다.
  annotation은 prefix와 실제 library identity를 확인하며 이름만 같은 가짜 선언을 보존하지 않는다.
- 생성 파일 목록은 _generatedDartSuffixes를 따른다. protobuf sibling도 synthesized/보존 대상이며 사용자 part와 구분한다.
- 제외 디렉터리·분석 대상 목록을 임의로 복제하지 않는다. analyzer와 구문 bridge scanner의 실제 범위 차이는 한계로 문서화한다.

## 캐시와 분석 한계

- 캐시는 canonical root별로 분석 대상 밖 OS 사용자 캐시에 둔다. 읽기·쓰기 실패나 손상이 결과를 바꾸지 않아야 한다.
- 키는 프로젝트와 중첩 패키지의 설정·package config·의존성 내용·mtime·SDK·분석 신원을 반영한다.
  추출 의미가 바뀌면 캐시 identity/revision도 갱신한다. 입출력 전후 변경 검사를 성능 이유만으로 제거하지 않는다.
- 소스 오류·미해석 호출·조건부 구성은 관측된 파일과 함께 남긴다. 손상 캐시를 재분석해 복구하는 테스트를 유지한다.

## Bridge 사실

- [isthmus GRAPH-EXCHANGE](https://github.com/ictechgy/isthmus/blob/main/docs/GRAPH-EXCHANGE.md)가 교환 계약의 정본이다.
  관련 변경 시 현재 스키마를 확인하고 소비자와 왕복 검증한다. 자매 저장소를 임의로 수정하지 않는다.
- Flutter services import provenance·prefix shadowing·lexical scope·cascade를 확인한다. 타입 이름이나 같은 문자열만으로 사실을 확정하지 않는다.
- 동적 이름은 dynamic: true로 남긴다. 미귀속·잘못된 호출, 조건부 import·re-export, Event/Basic 채널은 기존 limitation 계약을 따른다.
- 위치는 프로젝트 상대 경로와 1-based UTF-8 byte column, 시각은 UTC 밀리초다. 제어 문자와 경로 탈출을 허용하지 않는다.
- symbol.qualifiedName은 지원되는 Dart 선언의 어휘적 이름이다. 컴파일러 USR을 발명하지 않는다.
  귀속을 지원하지 않는 호출도 위치를 유지하고 missing-caller-symbols로 알린다. 언어 간 조인은 isthmus가 소유한다.
