# AGENTS.md

이 저장소에서 작업하는 코딩 에이전트를 위한 안내입니다. 작업 규칙의 **정본**입니다.
Claude Code 전용 사항은 [CLAUDE.md](CLAUDE.md), 진행 상태와 다음 할 일은 [HANDOFF.md](HANDOFF.md)에 있습니다.

> 이 저장소는 [cartograph](https://github.com/ictechgy/cartograph)(Swift)의 자매 프로젝트입니다.
> cartograph가 굳힌 작업 방식을 상속합니다.

공통 규칙은 이 파일에 두고 제품 코드와 테스트 규칙은 범위별 AGENTS.md로 나눕니다.
- `doc/` — PRD · 계획 · 리서치 · 결정 기록
- `experiments/` — Phase 0의 일회성 검증 스크립트. 제품 코드가 아닙니다. 결과는 `doc/DECISION-*.md`에
- `lib/AGENTS.md` — 제품 모듈 경계
- `test/AGENTS.md` — 행동 검증과 fixture 규칙

---

## 이 프로젝트가 하는 일

Dart/Flutter 코드베이스의 의존성 그래프를 공식 분석기(`package:analyzer`)로 만들고, 그 위에서 미사용 코드 · 파일 · 순환 · 레이어 규칙 · 지표를 **근거와 함께** 답하는 **영구 무료** CLI입니다. DCM이 유료화되며 남긴 자리(팀 · 50k LoC 초과 · 라이선스 키 없는 CI)를 채웁니다.

핵심 설계는 cartograph와 같습니다. **그래프가 산출물이고, 나머지는 전부 그 위의 질의입니다.**

## 먼저 읽을 것

1. `doc/PRD.md` — **"영구 무료 약속" 절을 포함해서.** 이 절은 삭제하지 않습니다
2. `doc/PLAN.md` — 지금 어느 Phase인지
3. `doc/RESEARCH.md` — 확인된 사실과 확인되지 않은 주장

## 영구 무료 약속 (코드로 지키는 규칙)

- `LICENSE`는 MIT이고 바꾸지 않습니다. README 첫 화면에 "상업적 사용 포함 영구 무료"를 적습니다
- 유료 티어 · 라이선스 키 · 좌석 수 · LoC 제한 · 텔레메트리 · 계정 로그인 코드는 이 저장소에 **들어오지 않습니다.** PR에 그런 것이 보이면 닫습니다
- 이유: Periphery와 DCM이 각각 상업화되며 생긴 자리를 채우는 것이 이 프로젝트 군의 존재 이유입니다. 같은 길을 가면 존재 이유가 없습니다

## cartograph에서 그대로 가져오는 것

cartograph의 같은 절과 동일합니다. 요약:

- 삭제 판정 없음 · 모든 판정에 근거 · 분석 한계를 응답에(`notFound` 포함) · 종료 코드 계약 `0/1/2/64` + 산출물 검증 스크립트 · 오탐 코퍼스 첫날부터(수정을 끄고 실패하는지 확인) · 베이스라인과 `--since` · `query`는 cartograph `SymbolQueryDocument`와 필드 이름까지 같게 · `skill`은 `../cartograph/Skills/cartograph/SKILL.md`를 출발점으로 · 커버리지 90% · JSON 키 정렬 · 가지치기 목록 한 벌

## 이 프로젝트만의 규칙

- **도구 언어는 Dart.** `package:analyzer`가 Dart라 다른 선택이 없고, 배포는 `dart pub global activate dartograph`와 pub.dev입니다. Flutter SDK에 의존하지 않습니다 — 순수 Dart 패키지도 분석 대상입니다
- **`analyzer`는 검증한 14.3.x 범위에 고정하고 어댑터 뒤에 가둡니다.** `analyzer`를 직접 import하는 코드는 `lib/src/index/` 한 곳에만 둡니다. cartograph가 `libIndexStore`를 `CartographIndexStore` 모듈 하나에 가둔 것과 같습니다. API가 자주 바뀐다는 주장은 Phase 0에서 실측합니다
- **해석 결과 캐시는 v0.1 범위입니다.** 분석 대상 밖의 OS 사용자 캐시에 canonical root 해시 디렉터리를 만들고, 내용·mtime·의존 패키지·analyzer package config·Dart SDK·분석 revision을 키로 완성된 사실을 저장합니다. 캐시 읽기·쓰기·손상이 분석 정확성을 바꾸면 안 됩니다
- **part 파일과 생성 코드를 구분합니다.** `.g.dart`, `.freezed.dart`, `.pb.dart`는 `synthesized`. 사용자 코드와 섞이면 "생성 코드가 미사용"이라는 쓸모없는 보고가 쏟아집니다
- **`main`은 여러 개일 수 있습니다.** `flutter run -t lib/main_dev.dart`. v0.1은 `lib/`, `bin/`, `example/`의 모든 `main`을 보수적 루트로 보므로 실제 build target을 함께 확인합니다
- **`dart analyze`의 `unused_element`를 다시 만들지 않습니다.** 그것은 라이브러리 안의 지역 판정이고 이 도구는 프로젝트 전역 도달성입니다. 차이를 README에 적습니다
- **DCM의 기능 목록을 따라가지 않습니다.** cartograph의 기능 목록을 따라갑니다
- **isthmus를 위한 `bridges` 명령은 v0.1 범위입니다.** `MethodChannel`/`invokeMethod` 리터럴을 `../isthmus/docs/GRAPH-EXCHANGE.md` 형식으로 냅니다. isthmus Phase 0이 이미 임시 추출기를 만들었습니다(`../isthmus/experiments/phase-0/dart/`) — 그것이 이 명령의 초안입니다

## 검증

Phase 1부터. 작업을 끝냈다고 말하기 전에 반드시 실제로 실행하고 출력을 확인합니다.

- `dart test`, 커버리지 게이트(`package:coverage`, 라인 90%), CLI 계약 스크립트, 픽스처 스크립트, 자기 분석(findings 0)
- PR마다 GLM 리뷰. 리뷰의 주장은 코드로 확인한 뒤 반영, 거절은 이유와 함께
- 도그푸딩: **바탕화면에 Flutter 프로젝트가 없습니다.** `doc/PLAN.md` 0.1의 공개 프로젝트를 씁니다

## 커밋

Conventional Commits, 본문은 한국어로 **왜**. `main`에 직접 커밋하지 않습니다. 스코프는 `core`, `index`, `analysis`, `export`, `cli`; 그 전에는 `docs`, `experiment`.

## 코드 스타일

- 주석은 한국어, 식별자는 영어. 사용자에게 보이는 출력 문자열은 영어
- 모든 public 선언에 문서 주석. *무엇을*이 아니라 *왜*
- 함수는 하나의 역할만. 빈 `catch` 금지. 오류 메시지에는 원인과 해결 방향
- `dart format` 기본값. `analysis_options.yaml`에 `package:lints/recommended.yaml`
