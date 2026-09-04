# Handoff

_Last updated: 2026-09-05 01:49 KST by Codex_

## Goal

- Dart/Flutter 의존성 그래프와 isthmus용 bridge facts를 근거·한계와 함께 제공하는 영구
  무료 MIT CLI를 유지한다.

## Current Status

- `main`의 기준 커밋은 `7d3d601`(PR #2)다.
- dartograph `0.1.1`은 pub.dev와 GitHub Release `v0.1.1`에 공개됐다.
- pub.dev에서 격리 설치한 0.1.1 바이너리의 전체 CLI 계약이 통과했다.
- 필수 후속 구현이나 배포 blocker는 없다.

## Completed

- `bridges --format json [--] <root>`가 isthmus GRAPH-EXCHANGE v1을 직접 생산한다.
- MethodChannel은 Flutter services import provenance와 lexical scope를 확인한다.
- `invokeMethod`, `invokeListMethod`, `invokeMapMethod`, cascade를 추출한다.
- 위치는 project-relative UTF-8 byte column, 시각은 UTC millisecond 형식이다.
- 미귀속·잘못된 호출, Event/Basic 채널, 조건부 import와 re-export를 limitation으로 남긴다.
- analyzer cache identity·중첩 의존성·protobuf 생성 코드, reachability explain, CLI 오류 경계를
  0.1.1에서 함께 보강했다.
- GLM max 전체 diff 리뷰와 후속 리뷰에서 release blocker 0건을 확인했다.

## Key Files & State

- `lib/src/index/bridge_index.dart`: bridge provenance, scope, facts, limitations.
- `lib/src/export/bridge_exporter.dart`: 결정적 GRAPH-EXCHANGE JSON과 UTC millisecond 시각.
- `lib/src/index/analyzer_graph_index.dart`: analyzer adapter와 cache identity.
- `lib/src/analysis/reachability_analyzer.dart`: dead/explain 도달성.
- `test/cli/agent_surface_cli_test.dart`: bridge 계약의 주 회귀 테스트.
- `.github/workflows/ci.yml`: Dart 3.11.0/3.13.3 matrix와 ripgrep 경계 게이트.

## Important Context / Decisions

- Facts:
  - isthmus v1은 `method-invoke.channel: null`을 허용하지 않는다. 해석할 수 없는 receiver는
    거짓 fact 대신 `unresolved-receiver-invocations` limitation으로 센다.
  - EventChannel과 BasicMessageChannel은 현재 isthmus 조인 범위가 아니므로 fact로 내지 않는다.
  - Flutter services re-export barrel의 importer는 직접 provenance를 증명할 수 없어 생략하며,
    scan-wide `flutter-services-reexports` limitation으로 알린다.
  - cache identity는 `dartograph-analysis-$toolVersion-cache-v1`이라 patch upgrade가 이전 facts를
    재사용하지 않는다.
- Assumptions:
  - cross-repository integration은 cartograph 0.5.3, dartograph 0.1.1, isthmus 0.1.3 이상이다.

## Verification

- Ran: `dart format --output=none --set-exit-if-changed .`
  - Result: pass, 80 files unchanged.
- Ran: `dart analyze` and `dart test`
  - Result: pass, no analysis issues and 105 tests.
- Ran: corpus, coverage, analyzer boundary, compiled CLI, isolated activation gates
  - Result: pass; product line coverage 91.85%.
- Ran: `dart pub publish --dry-run`
  - Result: pass, 53 KB archive, 0 warnings.
- Ran: GitHub PR #2 CI on Dart 3.11.0 and 3.13.3
  - Result: both matrix jobs passed, including hosted-package dry-run.
- Ran: hosted pub.dev activation of dartograph 0.1.1
  - Result: version and full CLI contract passed.
- Ran: isthmus synthetic and pinned public Flutter plugin roundtrips
  - Result: both passed with cartograph 0.5.3 and dartograph 0.1.1.

## Blockers & Open Questions

- No blocker.
- Optional: resolve local re-export barrels with analyzer elements when there is demand.
- Optional: add Pigeon-specific static extraction only after generated API shapes are measured.

## What Worked

- The hardened product extractor reused the Phase 0 provenance and scope model, then added focused RED
  tests for timestamps, UTF-8 columns, cascades, prefix shadowing, patterns, and conditional imports.
- A pinned public battery plugin verifies original Swift USRs and original Dart call locations.

## What Did Not Work / Avoid

- Do not emit `channel: null` on a Dart method invocation; isthmus correctly rejects it.
- Do not treat type names alone as Flutter provenance or flatten constants across lexical scopes.
- Ubuntu runners do not guarantee `rg`; CI installs ripgrep before the analyzer-boundary script.
- Run local commands with the Dart SDK directory in `PATH`; compiled pub wrappers invoke `dart` by name.

## Next Steps

1. No required work remains for the 0.1.1/isthmus producer milestone.
2. Start any Pigeon, re-export resolution, or additional channel work with a failing public-source fixture.
3. Coordinate GRAPH-EXCHANGE semantic changes in isthmus before changing emitted fact kinds.

## Resume Prompt

Open this repository at `/Users/jinhongan/Desktop/dartograph`, read `HANDOFF.md` and applicable
`AGENTS.md` files, then continue from: `No required 0.1.1 work remains; choose an explicit optional
follow-up before changing code.`
