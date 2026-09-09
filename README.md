# dartograph

Queryable dependency graphs for Dart and Flutter codebases. The sister project
of [cartograph](https://github.com/ictechgy/cartograph) (Swift).

[한국어 README](README.ko.md)

**MIT licensed, and permanently free — commercial use included.** There will
never be a paid tier, license keys, seat or line-of-code limits, telemetry, or
account sign-in.

The name blends **Dart** and cartograph.

## Why

DCM (formerly dart_code_metrics) has unused-code and unused-file
detection for Flutter — and went paid in 2023. Its free tier covers **one seat
and up to 50k lines of code**; teams and larger projects have to pay.

dartograph fills that gap as **permanently free (MIT), commercial use
included** — the same reason cartograph exists after Periphery went commercial.

- The source of truth is `package:analyzer` — the official analyzer published by
  the Dart team — not text search.
- Unused code, unused files, dependency cycles, layer rules, and architecture
  metrics all come from one graph.
- Every answer carries its evidence. dartograph never renders a deletion
  verdict.
- `query` and `skill` are built in from day one, designed to be consumed by
  coding agents.

**Releases are published on
[pub.dev](https://pub.dev/packages/dartograph) and
[GitHub Releases](https://github.com/ictechgy/dartograph/releases).** Every
release passes the full test suite, the line-coverage gate, a package dry-run,
and dogfooding against real public Flutter plugins. `bridges` conservatively
produces MethodChannel provenance, lexical scope, UTF-8 positions, UTC
millisecond timestamps, and dynamic/unresolved limitations per isthmus
GRAPH-EXCHANGE v1.

## Install

dartograph is a pure Dart CLI and does not require the Flutter SDK. It runs on
Dart 3.11 or later.

```bash
dart pub global activate dartograph
dartograph --version
```

From a source checkout, run the same commands via `dart run dartograph`.

## Usage

Pass the root of the Dart package to analyze as the last argument.

```bash
dart run dartograph graph --format dot .
dart run dartograph graph --format html .
dart run dartograph dead --format text .
dart run dartograph baseline --write .dartograph-baseline.json .
dart run dartograph dead --format github-actions \
  --baseline .dartograph-baseline.json --since origin/main .
dart run dartograph query ApiClient --baseline .dartograph-baseline.json .
dart run dartograph query --batch requests.json .
dart run dartograph compare ../before-checkout ../after-checkout
dart run dartograph affected origin/main .
dart run dartograph skill
dart run dartograph bridges --format json .
dart run dartograph cycles --strict .
dart run dartograph rules --config layers.yaml --strict .
dart run dartograph metrics .
```

With a global install, replace `dart run dartograph` with `dartograph` on every
line. Full arguments, output formats, exit codes, and CI examples live in
[`doc/USAGE.md`](doc/USAGE.md) (Korean).

- `--since` builds the whole project graph first, then narrows reporting to the
  changed locations. It covers commits after the base ref, staged and unstaged
  edits, and untracked files; CI needs the full Git history. Report formats are
  `text`, `json`, `github-actions`, and `sarif`.
- `query` answers for a single symbol — both-direction neighbors, members,
  retention paths, and limitations — using the same field names as cartograph,
  instead of dumping the whole graph.
- `affected <git-ref>` answers which libraries changed since a Git revision and
  which libraries transitively depend on them, each with its shortest dependency
  path as evidence.
- `bridges` emits Flutter `MethodChannel` creation and
  `invokeMethod`/`invokeListMethod`/`invokeMapMethod` facts in isthmus
  `GRAPH-EXCHANGE` version 1. Dynamic names stay facts; unattributed or invalid
  calls and partial parses stay visible as limitation counts. EventChannel and
  BasicMessageChannel are outside the current join scope and are counted as
  limitations rather than mistaken for facts.
- `cycles`, `rules`, and `metrics` only report by default; findings become exit
  code 1 with `--strict`. Metrics are per-library Ca, Ce, instability,
  abstractness, and distance from the main sequence.

A `// dartograph:ignore` line comment suppresses dead reporting for the
declaration it heads (retained as `retentionReason: inlineIgnore`) — a decision
by the repository author, recorded in the graph itself.

dartograph does not decide what is safe to delete and never deletes code.
Every finding's evidence and `limitations` need human review. It is a
whole-project reachability tool, not a reimplementation of `dart analyze`'s
library-local `unused_element`.

## Analysis limitations

- Conditional imports/exports: only the single configuration the analyzer picks
  is observed.
- String routes not connected to a route table are reported as limitations and
  never used as deletion evidence.
- Generated code older than its source is reported as a limitation; generated
  declarations themselves are conservatively retained.
- There can be multiple `main` functions. By default every entry point under
  `lib/`, `bin/`, and `example/` is retained. Declaring the real build targets
  in `dartograph.yaml` `entry_points` narrows retention to the `main` functions
  of those files.
- Public declarations and public members exported by `lib/<package-name>.dart`
  are retained as the external consumer API.
- Dynamic calls and native behavior cannot be fully proven by a static graph.
- `bridges` accepts only direct imports of `package:flutter/services.dart` as
  provenance. Usage through barrels that re-export Flutter services is excluded
  from facts and reported as the `flutter-services-reexports` limitation.

The analysis cache lives outside the analyzed project, in the OS user cache
(`~/Library/Caches`, `$XDG_CACHE_HOME`/`~/.cache`, `%LOCALAPPDATA%`) under
`dartograph/<project-root-hash>`. It is invalidated automatically when project
or dependency contents, mtimes, package resolution, the Dart SDK, or the
analysis revision change. A missing or corrupted cache never changes results —
it only costs analysis time.

Findings with more than 20 retention roots record the total count, a sample of
the first 20, and `retentionRootsTruncated: true` to keep output bounded. The
fact that evidence was truncated is never hidden.

## Documents

Repository design documents are written in Korean.

| Document | Contents |
|---|---|
| [`doc/PRD.md`](doc/PRD.md) | What, for whom, how far — and what it will never do |
| [`doc/PLAN.md`](doc/PLAN.md) | Phase-by-phase plan |
| [`doc/RESEARCH.md`](doc/RESEARCH.md) | Confirmed facts, unconfirmed claims, sources |
| [`doc/DECISION-analyzer.md`](doc/DECISION-analyzer.md) | Analyzer version, vertex IDs, generated code, caching decisions |
| [`doc/USAGE.md`](doc/USAGE.md) | Install, commands, exit codes, CI usage |

## Contributing and security

Contribution steps: [`CONTRIBUTING.md`](CONTRIBUTING.md) (Korean).
Vulnerability reports: [`SECURITY.md`](SECURITY.md) (Korean). Release changes:
[`CHANGELOG.md`](CHANGELOG.md); a Korean version is kept in
[`CHANGELOG.ko.md`](CHANGELOG.ko.md).

## License

MIT. **Permanently free, commercial use included.** This is a feature of the
project, not a footnote: the promise sits on the first screen of this README,
and the pledge never to change the license is recorded in `doc/PRD.md`.
