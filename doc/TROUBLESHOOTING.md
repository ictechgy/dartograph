# 문제 해결

dartograph를 처음 받았을 때, 또는 CI에 붙였을 때 자주 걸리는 지점을 모았다. 여기 없는
증상은 `--format json`의 `limitations` 배열을 먼저 읽는다 — dartograph는 모르는 것을
모른다고 출력에 남긴다.

## 1. 설치와 첫 실행

```bash
dart pub global activate dartograph
dartograph --version
```

- `dartograph` 명령을 못 찾으면 `~/.pub-cache/bin`이 `PATH`에 있는지 확인한다.
- 저장소 소스에서 바로 돌릴 때는 `dartograph` 대신 `dart run dartograph`를 쓴다.
- Dart SDK 3.11 이상이 필요하다. Flutter SDK는 필요 없다.

## 2. `dart analyze`가 수천 개의 가짜 오류를 낸다

**증상**: 존재하지 않는 심볼에 대한 오류가 2500건 이상 쏟아진다.

**원인**: 낡은 `.dart_tool/package_config.json`.

**해결**: 무엇보다 먼저 `dart pub get`을 실행한다. 그래도 남으면 `.dart_tool/`을 지우고
다시 받는다.

## 3. 종료 코드 읽기

| 코드 | 뜻 |
|---|---|
| 0 | 정상 |
| 1 | `--fail-on` 임계 초과(`impact`, `runtime`) 또는 미도달 대상(`dead --explain`) |
| 2 | 분석 실패(해석 불가, Git 출력 해석 실패, 계약 위반 문서 등) |
| 64 | 사용법 오류(옵션 조합 금지, 대상 없음, 잘못된 인자) |

CI에서는 `2`와 `64`를 실패로 취급하고, `1`만 별도 게이트로 다루는 편이 안전하다.

## 4. `impact`가 기대와 다르게 나온다

- **`--since <ref>`가 비교 대상을 못 찾는다.** 얕은 클론이면 비교 ref가 없다. CI에서는
  `actions/checkout`에 `fetch-depth: 0`을 준다.
- **`Changed files could not be computed: the git configuration defines a filter driver ...`**
  git 설정(저장소나 전역)의 `[filter "<이름>"]` 이름에 `=`가 있거나 UTF-8이 아니면 git이 그
  드라이버를 건너뛰게 할 수 없다. dartograph는 그 명령을 실행하지 않으려고 git을 부르지 않고 2로
  끝난다. 드라이버 이름을 바꾸거나 그 절을 지운다.
- **`--since`·`affected`의 변경 파일이 기대보다 많다.** git 조회가 stat 캐시를 새로 고치지 않아,
  내용은 같고 시각만 바뀐 파일과 git-lfs처럼 filter가 정규화하던 파일도 변경으로 센다. 신뢰하는
  checkout이면 먼저 `git status`를 실행한다.
- **`--changed <changes.json>` 형식 오류**는 64로 끝난다. 파일 경로와 형식을 확인한다.
- **결과가 비어 보인다.** `changed`가 비어 있으면 씨앗이 없다. `coverage`의
  `missedWithoutPrecheck`를 함께 읽는다 — 직접 변경만 봤을 때 놓쳤을 항목을 세는 필드다.
  `--limit`을 주면 이 목록도 앞 n개로 잘리므로(`impact-coverage-truncated:` limitation) 전체 수는
  `transitivelyImpacted`로 읽는다.
- **나열되지 않은 선언이 안전하다는 뜻이 아니다.** `limitations`를 반드시 함께 읽는다.

## 5. `runtime` 결과 해석

- **`unverified`는 실패가 아니다.** 판정할 수 없었다는 뜻이며 사유가 함께 나온다.
  대표적으로 `bare-library-name`(경로 없는 `DynamicLibrary.open` 라이브러리 이름)이다.
- **`config` 탐지가 많다.** 자기 저장소에서 돌리면 CLI 인자로 받은 경로가 다수 잡힌다.
  `<computed>`로 표시되는 항목은 신호가 약하므로 파일 리터럴 위주로 본다.
- **`--execute`가 이상 동작한다.** 컴파일 배포본(`dart compile exe`)에서는 과거에
  dartograph가 자기 자신을 재실행하는 결함이 있었다. 지금은 실행할 Dart를
  실행 중인 VM → `DART_SDK/bin/dart` → `PATH` 순으로 찾고, 모두 실패하면 실행하지 않고
  미판정 사유를 남긴다.
- **외부 자원 오탐.** `value.startsWith("https://")` 같은 비교 코드는 더 이상 보고하지
  않는다. `Uri.parse(<리터럴>)`이거나 알려진 네트워크 API 인자일 때만 보고한다.

## 6. `mcp`가 클라이언트에서 안 붙는다

- 서버는 **stdio**이고 프로토콜 버전은 `2024-11-05`다.
- **stdout에 로그를 섞으면 안 된다.** 사람용 출력은 전부 stderr로 간다. 클라이언트가
  JSON 파싱에 실패하면 래퍼 스크립트가 stdout을 오염시키고 있는지 확인한다.
- 알 수 없는 메서드는 `-32601`, 잘못된 JSON은 `-32700`, 잘못된 파라미터는 `-32602`로
  답하고 서버는 계속 동작한다. 서버가 죽으면 그 코드가 아니라 전송 계층 문제다.
- 도구는 읽기 전용이다. `changed`·`batch` 배열은 OS 임시 디렉터리에 잠깐 쓰고 호출이
  끝나면 지운다.

## 7. 심볼릭 링크와 경로

- `skill --install`, `init`, `baseline --write`는 쓰기 전에 임시 파일을 **배타적으로**
  만들고 rename으로 교체한다. 그 자리에 심볼릭 링크가 있으면 링크를 따라가지 않고
  링크 자체를 교체한다.
- 그래서 링크가 있으면 `--force`를 요구한다(매달린 링크 포함). 링크 대상을 덮어쓰는
  동작은 지원하지 않는다 — 의도된 안전장치다.
- 저장소가 제공하는 YAML 설정(`dartograph.yaml`, `pubspec.yaml`, `build.yaml`,
  `layers.yaml`, `--config` 파일)은 **1 MiB**까지만 읽는다(`package_config.json`은
  16 MiB). 초과하면 경로를 반향하지 않는 정적 메시지로 거절한다.
- 분석 입력이 정규 파일이 아닌 대상(문자·블록 장치, FIFO, 소켓)이면 읽기 전에 분석
  실패(종료 코드 2)로 멈춘다. 분석 트리의 링크뿐 아니라 import·part가 가리키는
  파일(숨김·`build` 디렉터리 안 파일, 절대 경로)도 같다. 진단은 모든 분석 명령에서 같다:
  `Analysis failed: an input is not a regular file (device, FIFO, or socket).`
  이런 대상은 길이를 0으로 보고해 크기 상한을 통과한 뒤 EOF 없이 읽히거나 영구
  대기한다. 링크나 import가 정규 파일을 가리키게 바꾸거나 지운다. 끊어진 링크는 지금처럼
  건너뛴다.
- 분석 입력 하나가 64 MiB를 넘으면 읽기 전에 분석 실패(종료 코드 2)로 멈춘다:
  `Analysis failed: an analysis input exceeds the 64 MiB read limit.`
  정상 Dart 소스는 생성 파일도 수 MB라, 이 진단은 대개 큰 호스트 파일이나 가상 파일
  (`/proc/...`)을 가리키는 링크·import에서 나온다.
- 결과에 `symlink-duplicate-directories: N …` 한계가 있으면 링크 경로 N개가 이미 다른
  경로로 읽은 디렉터리로 이어져 열지 않았다는 뜻이다. 링크를 거쳐 닿는 디렉터리는
  이름순으로 처음 만난 경로 하나로만 분석한다(실제 위치와 링크 하나는 둘 다 분석한다).
  그래서 건너뛴 경로 아래 선언은 `query`·`impact`·`dead`에서 '미발견'이다. 같은 소스가
  남은 경로의 ID로 나온다. 특정 경로를 남기려면 같은 디렉터리를 가리키는 다른 링크를
  지우거나, 그 경로가 이름순으로 먼저 오게 한다. 단계마다 다음 단계를 여러 번 가리키는
  링크 트리는 이 한계와 함께 디렉터리 수에 비례하는 시간 안에 끝난다.

## 8. 캐시

- 분석 캐시는 루트 안 전체 `.dart`(숨김 디렉터리 제외)와 설정, `package_config`, 의존
  패키지 `lib`, SDK 버전을 키로 한다. 도구 버전이 바뀌면 자동으로 무효화된다.
- 루트 **밖**을 가리키는 상대 import는 캐시 키에 들어가지 않는다(문서화된 경계다).
  밖의 파일만 고쳤는데 결과가 그대로면 이것을 의심한다.
- `--incremental <dir>`는 호출자가 지정한 디렉터리에 파일별 사실 캐시를 둔다. 손상·
  버전 불일치·쓰기 실패는 전체 해석으로 폴백하고 분석은 정상 수행한다. 결과가
  이상하면 그 디렉터리를 지우고 다시 돌린다(캐시는 최적화지 계약이 아니다).
  프로젝트마다 다른 디렉터리를 쓰고, 서로 다른 체크아웃이 한 디렉터리를 공유하지
  않게 한다 — 키가 파일 경로 기준이라 체크아웃이 다르면 잘못된 재사용이 날 수 있다.
- 결과에 `incremental-cache-not-read:` 한계가 있으면 캐시 파일 `facts.json`(문구가
  `the dup token cache file`이면 `dup`만 읽는 `tokens.json`)이 심볼릭 링크(장치·FIFO를
  가리키는 링크 포함)·FIFO·소켓이거나 1 GiB를 넘어서 열지 않았다는 뜻이다. 결과는 전체 해석과 같다. 그 실행의 캐시 쓰기가 그 자리를 정규 파일로 바꾸므로
  보통 다음 실행에서 사라진다. 계속 나오면 누가 그 자리에 링크를 다시 두는지 확인한다
  (예: 저장소가 캐시 디렉터리 안에 링크를 커밋했다).
- 분석 대상 안 디렉터리를 `--incremental <dir>`로 주는 것은 신뢰하는 저장소에만 한다.
  저장소가 그 자리에 커밋한 사실도 키가 맞으면 그대로 쓰인다. 신뢰하지 않는 저장소에는
  `--incremental-user-cache`를 쓴다. 사실 캐시가 사용자 캐시의
  `dartograph/<project-root-hash>/incremental`(`--workspace`면 `incremental-workspace`)에
  생긴다. 결과에 `incremental-cache-write-failed: no per-user cache directory is
  available …`가 있으면 `HOME`(Linux는 `XDG_CACHE_HOME`, Windows는 `LOCALAPPDATA`)이
  없거나 절대 경로가 아니라는 뜻이다. 그 변수를 설정하거나, 분석 대상 밖 디렉터리를
  `--incremental <dir>`로 명시한다.

## 9. 샌드박스·CI에서 `dart pub publish`가 실패한다

격리된 홈에서 `dart pub publish`는 pub.dev 자격 증명이 없고, OAuth 로그인 플로우가 임시
로컬 포트 바인딩을 필요로 해서 실패할 수 있다. 이 경우 게시는 자격 증명이 있는 호스트에서
실행하고, 검증(태그·Release·설치본·계약)만 CI나 다른 세션에서 이어받는다.

## 10. 되돌리기(롤백)

- **릴리스 단위**: 문제가 있는 버전은 pub.dev에서 withdraw하지 않고, 다음 패치 버전을
  올린다. 태그는 덮어쓰지 않는다.
- **작업 트리 단위**: 커밋되지 않은 변경은 `git checkout -- <path>`로 되돌린다
  (예: 잘못 덧붙은 문서). 브랜치 작업 자체를 버리려면 브랜치를 지우고 `main`에서
  다시 딴다 — `main`에는 직접 커밋하지 않는다.
- **CI 단위**: 새로 추가한 워크플로가 문제를 만들면 파일을 삭제하는 것만으로 비활성화된다.
  트리거를 좁혀 둔 이유가 이것이다(수동 실행 기본).
