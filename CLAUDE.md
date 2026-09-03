# dartograph — 작업 규칙

이 저장소는 [cartograph](../cartograph) 의 자매 프로젝트다. cartograph 가 굳힌 작업 방식을 상속한다. 여기 적힌 것은 전역 규칙(`~/.claude/CLAUDE.md`)에 **더해지는** 것이다.

## 먼저 읽을 것

1. `docs/PRD.md` — 무엇을 만들고 무엇을 만들지 않는지. **"영구 무료" 절을 포함해서**
2. `docs/PLAN.md` — 지금 어느 Phase 인지
3. `docs/RESEARCH.md` — 확인된 사실과 확인되지 않은 주장
4. `../cartograph/CLAUDE.md`, `../cartograph/Sources/AGENTS.md` — 상속할 설계 원칙의 원문

## cartograph 에서 그대로 가져오는 것

`../kartograph/CLAUDE.md` 의 같은 절과 동일하다. 요약:

- 삭제 판정을 내지 않는다 · 모든 판정에 근거 · 분석 한계를 응답에 · 종료 코드 계약 `0/1/2/64` + 바이너리 검증 스크립트 · 오탐 코퍼스 첫날부터 · 베이스라인과 `--since` · `query` 와 `skill` 처음부터 · 커버리지 90%

## 이 프로젝트만의 규칙

- **도구 언어는 Dart.** `package:analyzer` 가 Dart 라 다른 선택이 없고, 배포는 `dart pub global activate dartograph` 와 pub.dev 다. Flutter SDK 에 의존하지 않는다 — 순수 Dart 패키지도 분석 대상이다
- **`analyzer` 버전을 고정하고 어댑터 뒤에 가둔다.** GLM 이 "API 가 버전마다 자주 바뀐다"고 했다(확인 필요). 사실이든 아니든, `analyzer` 를 직접 만지는 코드는 `lib/src/index/` 한 곳에만 둔다. cartograph 가 `libIndexStore` 를 `CartographIndexStore` 모듈 하나에 가둔 것과 같다
- **해석 결과를 캐시한다.** IndexStoreDB 와 달리 analyzer 는 파일로 남는 산출물이 없다. 매 실행마다 전체 해석을 하면 큰 프로젝트에서 느리다. cartograph 의 `SourceFactsCache`(내용 해시 키, 분석기 신원 포함) 를 같은 구조로 — 단 **측정한 뒤에** 붙인다. 작은 프로젝트에서 analyzer 가 충분히 빠르면 v0.1 은 캐시 없이 간다
- **part 파일과 생성 코드를 구분한다.** `.g.dart`, `.freezed.dart`, `.pb.dart` 는 `synthesized` 로 표시한다. 사용자 코드와 섞이면 "생성 코드가 미사용" 이라는 쓸모없는 보고가 쏟아진다
- **라이선스 약속을 코드로 지킨다.** `LICENSE` 는 MIT, README 첫 화면에 "상업적 사용 포함 영구 무료". 유료 티어 · 라이선스 키 · 텔레메트리 코드는 이 저장소에 들어오지 않는다

## 검증

- 커밋 전: `dart test`, 커버리지 게이트(`package:coverage`, 라인 90%), CLI 계약 스크립트, 픽스처 스크립트, 자기 분석(findings 0)
- PR 마다 GLM 리뷰(`packet-ask`). 리뷰의 주장은 코드로 확인한 뒤 반영한다
- 외부 프로젝트 도그푸딩: **바탕화면에 Flutter 프로젝트가 없다.** `docs/PLAN.md` 0.1 의 공개 프로젝트 목록을 쓴다

## 하지 않는 것

- `dart analyze` 의 `unused_element` 를 다시 만들지 않는다. 그것은 파일 · 라이브러리 안의 지역 판정이고, 이 도구는 프로젝트 전역 도달성이다. 둘의 차이를 README 에 적는다
- DCM 의 기능 목록을 따라가지 않는다. cartograph 의 기능 목록을 따라간다

## 커밋과 브랜치

전역 규칙과 같다. `main` 직접 커밋 금지, Conventional Commits, 본문은 한국어로 **왜**를 적는다. `AGENTS.md` 는 패키지 구조가 생기는 Phase 1 에서 쓴다.
