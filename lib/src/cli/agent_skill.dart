/// 에이전트가 dartograph의 비판정 출력을 안전하게 소비하는 스킬이다.
const agentSkillMarkdown = '''---
name: dartograph
description: Query Dart dependency facts before changing apparently unused code.
---

# dartograph

Before changing a declaration, run `dartograph query <name> <package-root>`.

- A state is not a deletion verdict. Unreachable only describes graph reachability.
- Read `limitations` in the same response, including when status is `notFound`.
- `publicApi` means the package's representative library exports the declaration for external callers.
- `suppressedByBaseline: true` records a team decision and must be respected.
- Dart main functions may be multiple. Confirm the actual build target before narrowing roots.
- Generated Dart can be stale; rebuild when `generated-code-staleness` is reported.
- `overrideContract` means framework or runtime dispatch can call the override.
- Conditional imports expose one analyzer-selected configuration only.
- String routes without a route-table match remain limitations, not deletion evidence.

Passing these checks is not permission to delete. Change only what the user requested,
and report the reachability evidence and limitations for human judgment.
''';
