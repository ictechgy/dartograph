/// 에이전트가 dartograph의 비판정 출력을 안전하게 소비하는 스킬이다.
const agentSkillMarkdown = '''---
name: dartograph
description: Query Dart dependency facts before changing apparently unused code.
---

# dartograph

Before changing a declaration, run `dartograph query <name> <package-root>`.

- A state is not a deletion verdict. Unreachable only describes graph reachability.
- Read `limitations` in the same response, including when status is `notFound`.
- Public API is not automatically a retention root; callers may live outside the package.
- `suppressedByBaseline: true` records a team decision and must be respected.
- Dart main functions may be multiple. Check configured `entry_points` before narrowing roots.
- Generated Dart can be stale; rebuild when `generated-code-staleness` is reported.
- Conditional imports expose one analyzer-selected configuration only.
- String routes without a route-table match remain limitations, not deletion evidence.

Passing these checks is not permission to delete. Change only what the user requested,
and report the reachability evidence and limitations for human judgment.
''';
