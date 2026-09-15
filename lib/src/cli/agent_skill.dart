/// 에이전트가 dartograph의 근거를 요청된 변경에 활용하도록 안내한다.
const agentSkillMarkdown = '''---
name: dartograph
description: >
  Inspect Dart/Flutter dependency and reachability evidence when reviewing
  apparently unused code, callers, retention reasons, or graph changes.
  Use for dartograph queries; not for formatting-only or unrelated edits.
---

# dartograph

Use the smallest query that answers the user's task. Follow the user's requested
scope and existing approvals; this skill does not add a separate approval step.
If invocation details are unclear, inspect `dartograph --help`.

- One declaration: `dartograph query <name-or-id> <package-root>`.
- Several declarations: `dartograph query --batch <requests.json> <package-root>`.
  Requests are a JSON array of 1–1000 non-empty strings, at most 1 MiB.
  Read every result; a batch exit 64 can mean a partial notFound.
- Existing findings: use `--baseline <file>` with query when that baseline applies.
- Two prepared checkouts: `dartograph compare <before-root> <after-root>`.
  Match SDK, dependencies and build configuration; compare does not prepare them.
  A removed reference on a prior path is observed evidence, not proof of one cause.
- Impact of pending changes: `dartograph affected <git-ref> <package-root>`
  lists the libraries changed since that revision and their transitive
  dependents with dependency-path evidence. It observes at library level;
  an unlisted declaration is not proven unaffected.
- Pre-change impact, deeper: `dartograph impact --since <ref>|--changed <json>|--symbol <id>`
  reports changed symbols, every symbol that transitively uses them with a
  shortest usage path, call sites into changed declarations, related test
  libraries, a risk score with factors, and a `coverage` block of what
  inspecting changed files alone would miss. Prefer it before an edit.
- Tool integration: `dartograph mcp` serves Model Context Protocol tools on
  stdio (`impact_query`, `dependency_query`, `verify_run`) for clients that
  speak MCP; it reuses the same analysis paths and modifies nothing.
- Traceable runs: add `--record <dir>` to an analysis command to append one
  JSON line per run to `<dir>/ledger.jsonl` (command, exit code, observed Git
  HEAD, input flags, reported problem ids); existing lines are never rewritten.
  `dartograph history --ledger <dir> [--commit <sha>]` reads it back.
  `--env`/`--dart-define` values are never recorded.
- Cross-language facts: use `dartograph bridges --format json <package-root>`
  and the project's existing isthmus workflow when the task crosses native code.

Read status, `limitations`, location and reachability together. `notFound`
means absence from the graph, not verified dead code; `ambiguous` requires
disambiguation. A state is not a deletion verdict. Empty limitations do not prove safety.
`publicApi` and `overrideContract` explain conservative retention;
`inlineIgnore` records a repository author's `// dartograph:ignore` directive
heading a declaration and must be respected like a baseline;
`suppressedByBaseline: true` records a team decision and must be respected.
Dart main functions may be multiple. Confirm the actual build target.
Without `dartograph.yaml` `entry_points`, other mains stay conservative roots;
declaring entry_points narrows retention to the mains it lists. Generated
sources, conditional imports, dynamic calls and unmatched string routes can
limit the evidence.
When generated or vendored Dart source lives in a local path dependency, add
its package root to `source_packages`; this is opt-in and must stay inside the
project. Do not crawl an external pub cache or infer package roots.

Reuse evidence for an unchanged snapshot. After an authorized change, run
validation appropriate to its risk and report the result plus unresolved limits.
Do not repeat full analysis for each symbol or broaden a routine task into a
whole-project audit. Never infer permission to delete from an analysis result.
''';
