# Handoff

_Last updated: 2026-11-03_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다(2026-10-11 원문은 그 파일 끝 절).

## Current Status

- 발행본은 **0.17.0**이다. pub.dev 버전 목록은 0.16.1 다음이 0.17.0이며, 준비했던 0.16.2는
  게시하지 않고 0.17.0에 포함했다(CHANGELOG 0.16.2 절에 표기). GitHub Release `v0.17.0`과
  analysis server 플러그인 `dartograph_analysis_plugin` 0.1.1도 발행됐다.
- `main` 위의 `[Unreleased]` 변경(브랜치 `ccr-37904670-hxdjsx`, 리뷰·머지 대상):
  - 오탐 수정(실제 analyzer fixture로 재현 후 수정): 필드 재정의, 감싼 선언의 annotation,
    두 인자 `vm:entry-point` pragma, 명시적 setter, typedef 사용, 구조적 보존 선언의 사용 간선
    고정점(enum 상수 인자 등), 공유 생성 파일 접미사, YAML plugin 진입점, 폰트·자산 의존.
  - 한계: `public-libraries:`(게시 패키지의 대표 밖 공개 라이브러리).
  - 적합성 벡터를 isthmus `c76e105`로 다시 벤더링하고 `sql-relations` 14케이스를 실행한다.
  - CI: analyzer 하한(14.3)·상한 밖 신규 마이너 감지 예약 잡, impact-precheck 예시의 push 게이트.
  - 자기 분석: `tool/module_layers.yaml` 모듈 의존 방향 `rules --strict`, 모듈 간 순환 없음.
- 분석 캐시 신원은 `v30`이다. 발행 전이라 toolVersion은 0.17.0 그대로다.

## Next Steps

- 위 브랜치의 리뷰·CI·머지 후 다음 릴리스(0.18.0 후보)는 CONTRIBUTING의 절차를 따른다.
- 이번 범위에서 일부러 뺀 후속(보존을 좁히거나 계약을 바꾸는 변경이라 근거·결정이 필요):
  - 문서 주석 참조(`/// [Foo]`)를 사용 간선에서 빼기, 조건부 구성의 import 폐쇄 축소,
    생성 코드 루트의 조건부화 — 보존을 좁히므로 반대 방향 코퍼스와 실제 프로젝트 델타가 먼저다.
  - typedef 정점화(미사용 typedef 보고·`query` 지원) — 새 판정을 낳는다.
  - `generated_files` 설정 키 — 단위 사실 캐시 키 설계가 필요하다.
  - 0.15.0~0.16.1 게시본은 analyzer `<15.0.0`이라 새 설치가 미검증 14.6·14.7로 해석될 수
    있다. 현재 `lib`은 14.7.0에서 정적 분석 오류가 없음을 확인했으나, 옛 게시본의 컴파일과
    retract 여부는 게시 권한이 있는 환경에서 판단한다.
- 측정으로 기각한 프레임워크 보존 추가나 P7 최적화를 새 근거 없이 재개하지 않는다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. 발행본은 0.17.0이고
`[Unreleased]` 변경은 위 브랜치의 PR로 리뷰·머지 중이야. 머지 전이면 CI와 리뷰 지적을
확인하고, 머지 뒤 릴리스는 CONTRIBUTING 절차를 따라. Next Steps의 제외 항목은 보존을
좁히거나 계약을 바꾸므로 근거 없이 착수하지 마.
