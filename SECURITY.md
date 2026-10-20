# Security Policy

## Supported versions

공개 릴리스 중 최신 `0.16.x`만 보안 수정을 받습니다.

## Reporting a vulnerability

취약점에 시크릿, 실제 사용자 데이터, 또는 재현 가능한 공격 정보가 포함되면 공개 issue에
올리지 마십시오. 저장소의 GitHub **Security advisories → Report a vulnerability**를 통해
비공개로 제보해 주십시오. 그 경로를 사용할 수 없다면 민감한 내용을 공유하지 말고 공개
issue로 비공개 연락 경로를 요청하십시오.

영향받는 버전, 공격 전제, 영향, 최소 재현 절차를 포함해 주십시오. 접수 사실과 다음 확인
시점을 7일 안에 회신하는 것을 목표로 합니다. 보안 수정도 MIT와 영구 무료 약속을 지키며,
텔레메트리나 계정 로그인을 해결책으로 추가하지 않습니다.

## Trust boundary

분석 대상 저장소는 신뢰하지 않는 입력이다. dartograph는 대상 코드를 실행하지 않으며,
사실 캐시는 대상 밖의 OS 사용자 캐시에 저장해 저장소가 cache hit 결과를 미리 위조하지
못하게 한다. 파일별 증분 캐시도 `--incremental-user-cache`로 같은 위치에 둔다. 사용자가
`--incremental <dir>`로 분석 대상 안 디렉터리를 명시하면 이 보장이 없다. 그 캐시는 키가
맞는 사실을 다시 해석하지 않고 쓰는데, 키는 공개된 입력의 해시뿐이라 저장소가 위조한
사실을 커밋해 둘 수 있다. 그래서 트리 안 증분 디렉터리는 신뢰하는 저장소에만 쓴다.
`setup --install`이 쓰는 Claude Code 훅, VS Code 확장의 기본 `dartograph.args`, 분석 서버
플러그인은 `--incremental-user-cache`를 쓴다. 예시 워크플로(`.github/workflows/impact-precheck.yml`)는
사실 캐시와 원장을 체크아웃 밖 `runner.temp` 아래에 둔다. 같은 사용자 권한으로 실행되는 다른
로컬 프로세스는 신뢰 경계 안에 있다.

심볼릭 링크는 analyzer와 마찬가지로 분석 트리 안에서 의도적으로 따라간다(링크된 소스의
사실을 놓치면 낡은 그래프·누락된 channel 사실로 이어지므로 캐시 키와 bridge 스캔에
포함한다). 결과적으로 저장소가 자기 밖을 가리키는 링크를 심으면 같은 사용자의 외부
파일이 그래프·limitations·bridge 사실에 실려 CI 아티팩트 등 출력으로 흘러갈 수 있다.
출력 경로의 파일은 이 채널을 염두에 두고 검토한다.

다만 링크를 거쳐 닿는 디렉터리는 정규 경로마다 한 번만 연다. analyzer 자체의 열거는 링크
순환만 막아서, 단계마다 다음 단계를 두 번 가리키는 링크 트리를 경로마다 다시 펼친다. 실제
파일 십여 개로 분석 단위가 깊이에 지수적으로 늘어 분석이 끝나지 않는다. dartograph는 분석
단위·캐시 키·`runtime`·`routes`·`bridges`·`schema` 열거에서 같은 규칙을 쓴다. 항목을
이름순으로 훑고, 링크 순환에는 들어가지 않는다. 같은 디렉터리에 다시 닿은 링크 경로는 열지
않고 그 수를 `symlink-duplicate-directories:` limitation으로 남긴다. 디렉터리의 실제 위치는
언제나 연다. 그래서 디렉터리 하나는 많아야 두 번(실제 위치와 링크 경로 하나) 열리고, 열거는
디렉터리 수에 비례한다.

다만 분석 입력이 정규 파일이 아닌 대상(문자·블록 장치, FIFO, 소켓)이면 dartograph는 그
파일을 열지 않고 종료 코드 2로 끝난다. 이런 대상은 길이를 0으로 보고해 크기 상한을 통과한
뒤 EOF 없이 읽히거나(메모리 소진) 영구 대기한다. 분석 전 열거가 보는 링크만이 아니다.
analyzer가 해석하며 여는 모든 파일을 읽기 직전에 확인한다. 여기에는 import·part가 가리키는
숨김·`build` 디렉터리 안 파일과 링크 없는 절대 경로 import(`import '/dev/zero';`)도 들어간다.
`schema`·`bridges`가 analyzer 없이 직접 훑는 소스와 `bridges`가 Flutter 출처 확인에 읽는
`package_config.json`도 같은 경계를 지난다. 이 분석 입력은 파일마다 64 MiB까지만 읽는다.
그래서 길이를 0으로 보고하는 가상 파일(`/proc/self/pagemap` 등)이나 큰 호스트 파일도 메모리를
소진하지 못한다. 캐시 키·증분 해시도 같은 입력을 같은 상한으로 읽는다. 저장소 설정 파일과
`--baseline` 파일도 열기 전에 정규 파일인지 확인하고 1 MiB(`package_config.json`은 16 MiB,
baseline은 64 MiB)까지만 읽는다. `--incremental <dir>`의 캐시 파일(`facts.json`, 그리고
`dup`만 읽는 `tokens.json`)은 링크를 따라가지 않고 확인한다. 심볼릭 링크(장치·FIFO를 가리키는
링크 포함)·FIFO·소켓이면 대상이 무엇이든 열지 않고, 정규 파일은 1 GiB까지만 읽는다. 거부한
캐시 대신 사실을 모두 다시 해석하고 `incremental-cache-not-read:` limitation을 남긴다.

`--since`·`affected`(MCP `since` 포함)의 변경 파일 계산, `impact --format language-traversal`의
깨끗한 HEAD `revision` 판독, `--record` 원장의 commit 관측은 분석 대상에서 git을 읽기 전용으로
실행한다. `.git`째로 받은 저장소라면 그 설정은 공격자가 고를 수 있다. 그래서 이 호출들은 저장소와
사용자 git 설정이 정한 명령을 실행하지 않는다. 호출마다 바로 앞에서 `git config`로 filter 드라이버
이름을 다시 모아 clean·smudge·process를 빈 명령으로, required를 false로 덮는다. 모든 호출에
`core.fsmonitor=false`·`log.showSignature=false`·`--no-optional-locks`를 붙인다. 작업 트리를 비교하는
diff에는 `diff.autoRefreshIndex=false`를 붙여 index를 다시 쓰지 않는다. index를 쓰면
`post-index-change` 훅이 돈다. diff에는 `--no-ext-diff --no-textconv`를, 작업 트리를 보는 diff와
status에는 `--ignore-submodules=all`을 붙여 서브모듈 저장소의 설정을 따르는 git을 띄우지 않는다.
`=`가 들었거나 UTF-8이 아닌 드라이버 이름은 `-c`로 덮을 수 없으므로 git을 실행하지 않는다
(fail-closed). 부분 클론에서 git은 조회에 필요한 객체가 없으면 promisor 원격에서 fetch를 띄우고,
그 fetch는 원격의 전송 설정이 정한 명령(ssh URL의 `core.sshCommand`, 로컬 경로 URL의
`remote.<이름>.uploadpack` 등)을 실행한다. 그래서 모든 호출에 `GIT_NO_LAZY_FETCH=1`을 주고, 같은
`git config` 목록에 promisor 원격(`extensions.partialClone`, `remote.<이름>.promisor`,
`remote.<이름>.partialCloneFilter`)이 있으면 `--no-lazy-fetch`를 붙인다. 이 옵션을 모르는
git(2.45 미만)이면 부분 클론에서 git을 실행하지 않는다(fail-closed). 이름 변경 감지는 옛 내용을
읽으므로 diff에는 `--no-renames`를 붙인다. 바뀐 파일 목록은 같다. 그 대가로 git-lfs처럼 filter가 정규화하던 파일은 stat 정보가 낡으면 바뀐 것으로
보이고, `--since`는 stat만 바뀐 파일도 변경으로 센다(보수적 방향). 깨끗한 HEAD 판정은 그런 파일이나
서브모듈이 있으면 revision을 싣지 않는다. PATH의 git 실행 파일과 git이 설정 파일을 읽는 동작
자체(include가 가리키는 파일 포함)는 여전히 신뢰 경계 안이다.

VS Code 확장은 실행할 CLI(`dartograph.executable`)를 사용자(원격) 설정에서만 받는다(machine
범위). 작업 공간 `.vscode/settings.json`의 값은 신뢰한 작업 공간에서도 무시된다. 값은 절대 경로나
PATH의 명령 이름이어야 한다. 상대 경로는 실행 디렉터리인 패키지 폴더를 기준으로 풀려 저장소가
커밋한 스크립트를 가리킬 수 있으므로 실행하지 않는다. Windows에서 Node(libuv)는 이름만 받은 실행
파일을 PATH보다 먼저 실행 디렉터리에서 찾는다. 그래서 확장이 PATH의 절대 경로 디렉터리에서 직접
찾아 그 경로를 실행한다. 확장은 제한 모드에서도 켜지지만 `dartograph.args`·`dartograph.runOnSave`도
사용자 설정 값만 쓴다.

MCP 도구 인자는 분석 대상 저장소의 문서에 심은 지시를 따른 에이전트가 보낼 수 있다. 그래서
`packageRoot`·`baseline`·`config`는 서버 작업 디렉터리 안의 실제 디렉터리·정규 파일로만
받는다([MCP](doc/MCP.md)).
