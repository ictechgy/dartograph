# 결정: 검증 원장 (실행 이력 추적)

상태: **구현(미릴리스)** — `--record <dir>`와 `dartograph history`가
`lib/src/core/result_ledger.dart`·`lib/src/cli/dartograph_cli.dart`에 구현됐다.
`HANDOFF-PROGRESS.md` P0의 두 항목(증분 분석·검증 원장) 중 원장 절반이다.
증분은 [DECISION-incremental.md](DECISION-incremental.md)를 따른다.

## 1. 문제

CI·감사에서 "이 결과가 언제·어떤 입력·어느 버전으로 나왔는가"를 추적할 수 있어야
한다. 기존 분석 결과는 stdout으로 사라지고, 증분 캐시는 최적화라 이력이 아니다.

## 2. 결정

실행 하나를 append-only JSONL 한 줄로 남긴다.

- 옵션: `--record <dir>`. 지원 명령은 문제를 보고하는 분석·검증 명령 11종
  (graph·dead·query·compare·affected·impact·baseline·cycles·rules·metrics·runtime)이다.
- 파일: `<dir>/ledger.jsonl` 하나. 각 줄은 도구 버전·UTC 시각·명령·종료 코드·
  관측한 Git HEAD(없으면 null)·입력 플래그·문제 식별자다.
- 조회: `dartograph history --ledger <dir> [--commit <sha>] [--format text|json]`.

## 3. 이유

- **append-only**: 임시 파일 + rename을 쓰지 않는다. rename은 전체 파일 교체라
  이력 보존과 맞지 않는다. `FileMode.append`(POSIX `O_APPEND`)로 줄 단위 원자성을
  얻고, 기존 줄은 절대 다시 쓰지 않는다.
- **비밀 비노출**: `--env`·`--dart-define`은 값이 비밀일 수 있어 키만 남긴다.
  증분 캐시가 환경변수 값을 싣지 않는 것과 같은 경계다.
- **캐시 아님**: 원장 쓰기 실패는 분석 결과와 종료 코드를 바꾸지 않는다. stderr
  진단 한 줄만 남긴다(증분 캐시 쓰기 실패와 같은 경계).

## 4. 손상 복구

- 쓰기 중단으로 마지막 줄이 잘리면 읽기가 그 줄을 건너뛰고
  `ledger-skipped-lines: N` limitation으로 보고한다. 원장은 고치거나 지우지 않는다.
- 다음 `--record`는 파일이 개행으로 끝나지 않았으면 개행을 먼저 넣고 새 줄을 쓴다.
  그러지 않으면 새 항목이 잘린 줄에 이어 붙어 둘 다 잃는다.
- 파일이 없으면 빈 원장으로 읽는다(오류가 아니다).

## 5. 출력 계약 (history json)

`{"entries": [...], "limitations": [...], "skippedLines": n, "version": 1}`.
entry는 `command`·`commit`·`exitCode`·`failedItems`·`inputs`·`recordedAt`·`toolVersion`이고
`inputs` 키는 사전순으로 고정한다. text는 사람용 한 줄 요약이며 C0·DEL을 가시
이스케이프한다.

## 6. 결정성

원장은 `recordedAt`·Git HEAD 같은 관측값을 담으므로 그 자체는 결정적 산출물이
아니다. 제품 stdout의 결정성 계약과 무관하다(USAGE의 선언된 예외와 같은 성격).

## 7. 되돌리기

`--record`는 옵션이므로 주지 않으면 기존 경로 그대로다. 원장 디렉터리는 언제든
삭제해도 안전하다(분석에 영향 없음).