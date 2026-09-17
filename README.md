# dartograph

Queryable dependency graphs for Dart and Flutter codebases. Sister project of
[cartograph](https://github.com/ictechgy/cartograph) (Swift).

[한국어 README](README.ko.md)

**MIT licensed, and permanently free — commercial use included.** There will
never be paid tiers, license keys, seat or line-of-code limits, telemetry, or
account sign-in.

The name blends **Dart** and cartograph.

## Why

DCM (formerly dart_code_metrics) detects unused code and files in Flutter
projects — and went paid in 2023. Its free tier covers **one seat and up to 50k
lines of code**, so teams and larger projects have to pay.

dartograph fills that gap: **permanently free (MIT), commercial use included** —
just as cartograph does for Swift after Periphery went commercial.

- The source of truth is `package:analyzer`, the Dart team's official analyzer
  package — not text search.
- Unused code, unused files, dependency cycles, layer rules, and architecture
  metrics all come from one graph.
- Every answer carries its evidence. dartograph never renders a deletion
  verdict.
- `query` and `skill` are built in from day one, designed to be consumed by
  coding agents.

## Install

dartograph is a pure Dart CLI and does not require the Flutter SDK. It runs on
Dart SDK 3.11 or later.

```bash
dart pub global activate dartograph
# or, on Dart 3.11+, an AOT-compiled install:
dart install dartograph
dartograph --version
```

Releases are published on
[pub.dev](https://pub.dev/packages/dartograph) and
[GitHub Releases](https://github.com/ictechgy/dartograph/releases). Every
release passes the full test suite, the line-coverage gate, and a package
dry-run, and is dogfooded against real public Flutter plugins.

## Usage

Most commands take the root of the Dart package to analyze as the last argument.
The examples below assume a global install; from a source checkout, prefix each
command with `dart run` (for example, `dart run dartograph graph --format dot .`).

```bash
# initialize configuration template
dartograph init .

# graph & dead code
dartograph graph --format dot .
dartograph graph --format html .
dartograph dead --format text .

# baseline & narrowed CI reporting
dartograph baseline --write .dartograph-baseline.json .
dartograph dead --format github-actions \
  --baseline .dartograph-baseline.json --since origin/main .

# standalone apps: drop public-API retention; audit pubspec hygiene
dartograph dead --closed-app .
dartograph deps .

# symbol queries
dartograph query ApiClient --baseline .dartograph-baseline.json .
dartograph query --batch requests.json .

# change impact
dartograph compare ../before-checkout ../after-checkout
dartograph affected origin/main .

# change impact pre-check & runtime-only dependencies
dartograph impact --changed lib/api.dart .
dartograph runtime .

# duplicate code, cycles, layer rules, metrics
dartograph dup .
dartograph cycles --strict .
dartograph rules --config layers.yaml --strict .
dartograph metrics .

# Flutter bridge facts, agent skill & setup, MCP server
dartograph bridges --format json .
dartograph bridges --messages --format json .
dartograph bridges --events --format json .
dartograph skill
dartograph setup --install .
dartograph mcp
```

Full arguments, output formats, exit codes, and CI examples live in
[`doc/USAGE.md`](doc/USAGE.md) (Korean).

- `--since` builds the whole project graph first, then narrows reporting to the
  changed locations. It covers commits after the base ref, staged and unstaged
  edits, and untracked files; CI therefore needs the full Git history. Output
  formats are `text`, `json`, `github-actions`, and `sarif`.
- `--baseline <file>` suppresses the exact findings recorded by
  `baseline --write`, so known dead code does not fail CI and only new findings
  surface.
- `query` answers questions about a single symbol — neighbors in both
  directions, members, retention paths, baseline status, and limitations — using
  the same field names as cartograph, instead of dumping the whole graph.
- `affected <git-ref>` reports which libraries changed since a Git revision and
  which libraries transitively depend on them — each dependent backed by its
  shortest dependency path to a changed library as evidence.
- `compare <before> <after>` diffs two checkouts of the same package: added and
  removed vertices, edges, and retention roots, plus what became newly
  unreachable or newly reachable (a newly-unreachable declaration carries its
  before-path, removed edges, and removed roots as evidence). Unlike `--since`,
  it compares two whole graphs rather than filtering report locations.
- `bridges` emits Flutter `MethodChannel` creation and
  `invokeMethod`/`invokeListMethod`/`invokeMapMethod` facts in
  [`GRAPH-EXCHANGE`](https://github.com/ictechgy/isthmus/blob/main/docs/GRAPH-EXCHANGE.md)
  v1 — the bridge-fact format that
  [isthmus](https://github.com/ictechgy/isthmus) joins across platform
  boundaries; cartograph produces it too. Each fact
  carries MethodChannel provenance, lexical scope, UTF-8 positions, and UTC
  millisecond timestamps. Dynamic channel names remain facts; unattributed or
  malformed invocations, partial parses, and EventChannel/BasicMessageChannel
  are counted as limitations rather than read as facts in the default command.
- `bridges --messages` and `bridges --events` are opt-in development-source
  producers for BasicMessageChannel `send` calls and EventChannel
  `receiveBroadcastStream` listens. They emit bridge-facts v2 with
  `transport: "basic-message-channel"`/`"event-channel"`; they never turn a
  channel construction into a send or invent a MethodChannel method. Dynamic
  names retain their source expression. A `channelPrefix` is emitted only when
  the AST proves a decoded, non-empty leading literal in a string
  interpolation; it is a candidate prefix, not proof of a complete runtime
  address or instance identity. `--messages` and `--events` are mutually
  exclusive.
- `impact` reports which declarations and tests a change touches before it
  lands — from `--changed <file>`/`--symbol <id>`/`--since <ref>` — with the
  dependency paths as evidence. `runtime` finds inputs that only appear at run
  time (environment/dart-define reads, dynamic loads, config paths, assets,
  external URLs) and judges them against the current environment; `--execute`
  runs an entrypoint and records exit code and stderr as execution evidence.
- `--incremental <dir>` reuses cached analysis facts for CI-speed reruns, and
  `--record <dir>`/`history` keep an append-only ledger of run inputs,
  versions, and results.
- `skill` prints a ready-to-paste skill — or installs it into a directory with
  `--install <dir>` — that teaches a coding agent how to drive dartograph for
  evidence-backed answers.
- `setup` prints — or installs with `--install <root>` — Claude Code
  integration: a PostToolUse hook that runs an impact pre-check after Dart
  edits (no MCP call needed), plus the project `.mcp.json` server entry.
  Existing settings are merged, never overwritten.
- `dup` reports duplicated code blocks as token-structural review candidates,
  and `dead`/`deps`/`dup` accept `--kinds <csv>` to narrow reported finding
  kinds. `metrics` also reports function-level cyclomatic complexity and
  hot-spot rankings.
- `cycles`, `rules`, and `metrics` only report by default; findings become exit
  code 1 with `--strict`. Metrics are per-library Ca, Ce, instability,
  abstractness, and distance from the main sequence — each entry also carries
  its zone (`main-sequence`, `zone-of-pain`, `zone-of-uselessness`, or
  `isolated` for entries with no couplings at all) at the reported tolerance.
- `init` writes a commented `dartograph.yaml` configuration template to the
  project root (pass `--force` to overwrite an existing configuration).
- `deps` audits pubspec hygiene: dependencies declared but never imported,
  dev dependencies used from `lib/` or never imported, and `package:` imports
  with no declaration. Tool-contract dependencies — `executables`,
  `build.yaml` builders, `analysis_options` includes/plugins — count as used,
  and runtime/generated/asset references stay explicit limitations. Findings
  are a review list, never a deletion instruction.
- `dead --closed-app` turns off public-API retention for standalone apps
  (Flutter apps, CLI executables) — declarations unreachable from `main` are
  reported even when `lib/<package>.dart` exports them. Pair it with
  `baseline --write --closed-app`, and never run it on a published library.
- `dartograph mcp` also exposes MCP resources (`dartograph://usage`, `skill`,
  `config`) and prompts (`impact-precheck`, `dead-code-review`,
  `dependency-audit`, `duplication-review`) alongside the three query/verify
  tools.
- A zero-build VS Code extension is on the
  [marketplace](https://marketplace.visualstudio.com/items?itemName=ictechgy.dartograph)
  (source: `editors/vscode/`): it runs the CLI and surfaces
  `dead`/`deps`/`dup`/`impact` JSON findings as Problems diagnostics —
  evidence and limitations included, never a deletion verdict. The
  [`dartograph_analysis_plugin`](https://pub.dev/packages/dartograph_analysis_plugin)
  package brings `dead`/`dup` findings into `dart analyze` and IDE analysis
  servers as `dartograph_dead_code`/`dartograph_duplicate_block` diagnostics
  with a `dartograph:ignore` quick fix.

A `// dartograph:ignore` line comment suppresses dead reporting for the
declaration it heads (retained as `retentionReason: inlineIgnore`) — a decision
by the repository author, recorded in the graph itself.

dartograph does not decide what is safe to delete and never deletes code. The
evidence and limitations attached to every finding require human review. It is a
whole-project reachability tool, not a reimplementation of `dart analyze`'s
library-local `unused_element`.

## Analysis limitations and guarantees

Limitations:

- Conditional imports/exports: only the single configuration the analyzer picks
  is observed.
- String routes not connected to a route table are reported as limitations and
  never used as deletion evidence.
- Generated code older than its source is reported as a limitation; generated
  declarations themselves are conservatively retained.
- A package can contain several `main` functions. By default every `main` under
  `lib/`, `bin/`, and `example/` is retained. Declaring the real build targets
  under `entry_points` in `dartograph.yaml` narrows retention to the `main`
  functions of those files (a template can be generated with `dartograph init`).
- Local path dependencies are opt-in graph inputs through `source_packages` in
  `dartograph.yaml`; each declared package root must be inside the project and
  contain `pubspec.yaml` and `lib/`. This is useful for generated Pigeon/Dart
  source vendored under a project without crawling the whole pub cache.
- Public declarations and public members exported by `lib/<package-name>.dart`
  are retained as the external consumer API.
- Dynamic calls and native behavior cannot be fully proven by a static graph.
- `bridges` accepts only direct imports of `package:flutter/services.dart` as
  provenance. Usage through barrels that re-export Flutter services is excluded
  from facts and reported as the `flutter-services-reexports` limitation.

Guarantees:

- The analysis cache lives outside the analyzed project, in the OS user cache
  (`~/Library/Caches`, `$XDG_CACHE_HOME`/`~/.cache`, `%LOCALAPPDATA%`) under
  `dartograph/<project-root-hash>`. It is invalidated automatically when project
  or dependency contents, mtimes, package resolution, the Dart SDK, or the
  analysis revision change. A missing or corrupted cache never changes results;
  it only costs analysis time.
- For findings with more than 20 retention roots, dartograph records the total
  count, the first 20 as a sample, and `retentionRootsTruncated: true` to keep
  output bounded. The fact that evidence was truncated is never hidden.

## Documents

Repository design documents are written in Korean.

| Document | Contents |
|---|---|
| [`doc/PRD.md`](doc/PRD.md) | What, for whom, how far — and what it will never do |
| [`doc/PLAN.md`](doc/PLAN.md) | Phase-by-phase plan |
| [`doc/RESEARCH.md`](doc/RESEARCH.md) | Confirmed facts, unconfirmed claims, sources |
| [`doc/DECISION-analyzer.md`](doc/DECISION-analyzer.md) | Analyzer version, vertex IDs, generated code, caching decisions |
| [`doc/USAGE.md`](doc/USAGE.md) | Install, commands, exit codes, CI usage |
| [`doc/MCP.md`](doc/MCP.md) | MCP tools, resources, prompts, error codes |
| [`doc/TROUBLESHOOTING.md`](doc/TROUBLESHOOTING.md) | Common failure modes and fixes |
| [`doc/COMPETITIVE-ANALYSIS.md`](doc/COMPETITIVE-ANALYSIS.md) | Alternatives survey and the shipped gap list |

## Contributing and security

Contribution steps: [`CONTRIBUTING.md`](CONTRIBUTING.md) (Korean).
Vulnerability reports: [`SECURITY.md`](SECURITY.md) (Korean). Release changes:
[`CHANGELOG.md`](CHANGELOG.md); a Korean version is kept in
[`CHANGELOG.ko.md`](CHANGELOG.ko.md).

## License

MIT. **Permanently free, commercial use included.** This is a feature of the
project, not a footnote: the promise sits on the first screen of this README,
and the pledge never to change the license is recorded in `doc/PRD.md`.
