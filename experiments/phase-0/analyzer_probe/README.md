# analyzer Phase 0 probe

`package:analyzer` 14.3.0의 resolved unit에서 그래프 대상 선언과 참조를
읽을 수 있는지 확인하는 일회성 실험이다. 대상 패키지의 코드를 실행하지 않는다.

## 실행

분석 대상은 먼저 해당 SDK로 `pub get`을 마쳐 유효한
`.dart_tool/package_config.json`을 갖고 있어야 한다.

```sh
dart pub get
dart test
dart run bin/probe.dart /path/to/package
```

출력은 JSON 한 줄이다. `declarations`는 v0.1 그래프 범위의 선언 수이고,
`references`는 `SimpleIdentifier`가 그 선언 종류로 해석된 횟수다. 이 참조 수는
Phase 0 비교용이며 완성된 그래프 간선 수가 아니다. `diagnostics`가 0이 아닌 측정은
성능·참조 수 결정의 근거로 쓰지 않는다.

Fixture는 다음 경계를 고정한다.

- `part` 파일은 호스트 라이브러리 URI에 귀속된다.
- 분석 제외된 `.g.dart`도 직접 해석하고 `generatedFiles`로 표시한다.
- 조건부 export는 공개 `AnalysisContextCollection`의 현재 구성에서 선택된 분기만 본다.
- 이름 없는 extension은 canonical fragment offset으로 서로 구분한다.
- `test/`처럼 `package:` URI가 없는 파일은 프로젝트 상대 `project:` URI를 쓴다.
