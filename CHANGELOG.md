# Changelog

A Korean version of this changelog is kept in [CHANGELOG.ko.md](CHANGELOG.ko.md).

## 0.7.0

- Added `graph --format anon` for privacy-preserving graph export (parity with
  dependency-cruiser's `anon` reporter). Package-relative paths and file paths
  are anonymized using deterministic, injective identifiers (`s0`, `s1`, ...)
  while preserving graph topology, file extensions, and a whitelist of standard
  Dart idiomatic vocabulary. Analyzer limitation strings are sanitized in a
  single alternation pass to prevent double-replacement leaks

- Added `dead --report-redundant-public` to identify public declarations that
  are never referenced outside their defining library (parity with Periphery's
  redundant public accessibility check). Follows the informational contract of
  `--report-test-only` (findings emitted as `info`, command exits with code 0).
  Does not combine with `--explain`, `--baseline`, or `--report-test-only`
  (usage 64); `--since` and machine-readable output formats are allowed.
  Conservative exclusions preserve retention roots, enum constants, override
  implementers, operators, and private container members

- Added architectural zone classification to `metrics` JSON output (parity
  with cartograph's `MetricsZone`). Each component metric entry now includes a
  `zone` field (`main-sequence`, `zone-of-pain`, `zone-of-uselessness`, or
  `isolated`). The boundary aligns with `--strict` threshold calculations

- In `graph --format dot`, vertices participating in circular dependencies are
  now highlighted in red (`color="#d9383a"`, `fontcolor="#d9383a"`) (parity
  with madge). Detected via Tarjan's SCC algorithm; DOT output for acyclic
  graphs remains byte-identical

- `GraphNode` now carries an explicit `isLibrary` boolean flag instead of
  relying on `.dart::` string heuristics in HTML exports and projections.
  Libraries whose file names contain `::` are now correctly classified. Analysis
  cache serialization schema version incremented to `v3` (cache identity
  unchanged) for automatic re-analysis of prior caches without changing
  serialized JSON, DOT, or Mermaid outputs

- Fixed grammatical agreement in `bridges` limitations across all three
  diagnostic families (`unscanned-*` plural nouns for N ≥ 2 and dynamic-*
  singular verb agreement for N = 1)

## 0.6.0

- **Breaking change (library API)**: the public library surface
  (`package:dartograph/dartograph.dart`) was trimmed to what is actually
  supported. CLI behavior and exit codes are unchanged.
  - `querySymbol` was removed — a one-shot wrapper around `SymbolQuerySession`
    used only by `tool/` benchmarks. Construct a `SymbolQuerySession` and call
    `query` instead
  - `CodeGraph.usageEdgesFrom` was removed (no product caller; filter
    `CodeGraph.edges` instead)
  - `SymbolQuerySession.analysis` (a `ReachabilityResult` field) is no longer
    public. The session now exposes `deadDeclarations` (an unmodifiable
    `List<DeadFinding>`) for the `query --baseline` flow, so no public member
    references an unexported type. Reachability questions are answered by
    `SymbolQuerySession.query`, whose document carries each symbol's
    reachability state. `ReachabilityResult`/`ReachabilityExplanation` stay
    internal; `DeadFinding` is now exported

- `bridges` pub workspace detection now validates membership. A package whose
  pubspec declares `resolution: workspace` joins the nearest ancestor
  `workspace:` root when that root plausibly lists it — explicit paths are
  matched after URL normalization, while glob entries and non-list `workspace:`
  values are conservatively accepted. Only a well-formed explicit-path list that
  omits the package falls back to the scan root, with a new
  `pub-workspace-member-not-listed` limitation so a misconfigured workspace never
  silently skews the isthmus join basis

- SARIF output no longer corrupts already-absolute source URIs. A dead finding
  whose source is `file:` (an out-of-root path) or `package:` (a dependency) is
  passed through unchanged instead of being split on `/` and re-encoded (which
  turned `file:///a.dart` into `file%3A///a.dart`). Project-relative sources keep
  the existing per-segment encoding (backslash- and percent-safe)

- HTML graph output now classifies a library whose file name contains `::`
  correctly, using the `.dart::` declaration boundary instead of any `::`. Such a
  library is no longer shown as a member, and its display name is no longer
  truncated at the first `::`

- README revised for clarity (English original and Korean twin); no behavior
  change

## 0.5.0

- `bridges` gained `--project <shared-root>` and pub workspace auto-detection
  (isthmus monorepo join request #38; GRAPH-EXCHANGE delegates the shared-root
  declaration to producer options)
  - `--project` keeps the scan on the positional package root while the
    document's `project` field and `location.path` become relative to the shared
    root (POSIX realpath; it must be an existing directory containing the
    package root, else usage 64). Sibling packages of a pub monorepo (e.g. a
    `*_platform_interface` holding the MethodChannel and the plugin package
    holding the native side) can now emit the exact same `project` string the
    isthmus strict-equality join requires — no hand-rewriting documents, which
    breaks provenance
  - A package whose pubspec declares `resolution: workspace` picks up its pub
    workspace root (nearest ancestor pubspec with a `workspace:` key — the
    Melos definition) without `--project`. Precedence: `--project` > workspace
    detection > scan root. Detection failures fall back to the scan root and
    report `pub-workspace-root-not-found`/`pub-workspace-pubspec-unparsed`
    limitations so a skewed join basis is never silent
  - Without a workspace declaration or `--project` the output is byte-identical
    to before (project = realpath of the scan root, paths relative to it) —
    existing bridge goldens pass unmodified
  - The bridges control-character rejection **message** now reads "a fact value
    or source path contains control characters" — message-only, no behavior
    change: source paths have been validated since 0.3.0, and empty names are
    skipped into the `empty-bridge-names` limitation rather than throwing, so
    the old "is empty" attribution was unreachable/wrong

- Indexing got measurably faster with byte-identical output (audit P1/P2/P9/P10;
  measured with the new `tool/benchmark_index.dart` A/B harness — sha256 of graph,
  dead, query, retention, and test-only outputs identical before/after):
  - Element-to-ID resolution is memoized per relationship-collector pass; it used
    to recompute path normalization and name chains for every identifier visit
  - `CodeGraph.nodes`/`edges` read views are cached and invalidated on mutation
    instead of re-sorting on every access; `_addPublicApiRoots` hoists its node-id
    list out of the per-export loop
  - The edge comparator is shared between `CodeGraph` and `GraphSnapshot`
    (single determinism implementation), pubspec.yaml is read once per index, and
    declaration source paths are computed once per declaration
  - Synthetic benchmark (600 files, 4,923 nodes / 14,726 edges, Dart 3.13.3,
    macos_arm64, min of 3 cold runs): index 1456 ms -> 1053 ms (-28%). Machine-
    specific; relative comparison only, not an SLA

- Two more measured hot-path fixes with byte-identical output (audit P4/P8;
  harness now also times `rules` evaluation and hashes its violations):
  - `LayerRuleEvaluator` caches compiled glob RegExps per pattern instead of
    recompiling for every node × layer × pattern (first-match assignment scans
    all patterns for unmatched nodes). Benchmark: rules evaluation on 4,923
    nodes 10.8 ms -> 3.0 ms (-72%), violations hash identical
  - `dead --since` resolves each unique finding source's symlink once instead
    of once per finding (findings of one file shared the syscall before)

- Reachability/query hot loops got indexed with byte-identical output (audit
  P3/P5/P6; same A/B harness, all six artifact hashes identical):
  - `ReachabilityResult` gains `isReachable` (set lookup) and `reachableMemberOf`
    (dot-prefix witness index built once, deterministic first-in-sorted-order
    semantics preserved) — `query` batches and `compare` losses no longer run a
    linear scan per query/loss. Synthetic benchmark: 100-query batch on 4,923
    nodes 10.7 ms -> 1.7 ms (-84%)
  - The double sort of reachable ids per `analyze` is gone (5.7 ms -> 4.7 ms on
    the benchmark), and `compareGraphs` hoists its limitation dedup+sort out of
    the per-loss loop

## 0.4.1

- `--since`/`affected` Git change matching is now bidirectional for symlinked
  sources: both the link path itself (the link file changed or was retargeted)
  and the resolved physical target (the target changed) are matched against the
  changed set — previously only the resolved path was compared, so a changed
  link file silently fell out of scope (measured)
- A `dartograph.yaml` declaring `entry_points` now reports an
  `entry-points: main retention roots narrowed to N declared build target(s)`
  limitation — a configuration added by a pull request can no longer hide dead
  code indistinguishably from a clean repository
- SECURITY.md documents the symlink ingestion channel: dartograph follows links
  inside the analysis tree like the analyzer does, so a repository that plants
  links can pull same-user files from outside itself into its graph output and
  CI artifacts
- Output fidelity fixes from the audit (all additive or misinformation-only changes)
  - `dead --format json` gains a `report` field (`dead`/`test-only`) so a stored
    artifact is machine-classifiable without the exit code — the four report
    formats are now lossless-symmetric
  - `dead --format github-actions` emits a `::notice ... suppressed by baseline`
    line when the baseline suppressed findings (the other three formats already
    reported the count; zero stays byte-identical)
  - `graph --format json` nodes carry `isEnumConstant: true` for enum constants
    (conditional-field convention like `line`/`column`; the cache document
    already had it — the public exchange format can now reproduce the
    enum-constant retention decision)
  - SARIF file findings no longer invent a `region` of line 1 column 1 —
    `region` is optional in SARIF and fabricating position evidence violates
    the evidence contract (declaration findings keep their real region)
  - The determinism contract now names its second declared exception: the
    `generated-code-staleness` limitation is an mtime observation (git does not
    preserve mtimes, so its presence can differ across fresh clones; findings,
    nodes, and edges are unaffected) — documented in USAGE and lib/AGENTS.md
- The analysis cache key now hashes every `.dart` file under the package root
  (excluding `.dart_tool`/`.git`/`build`), not only the five standard source
  directories — the analyzer also reads outside the standard directories
  through the import closure (e.g. `tool/`), and a key that missed them reused
  a stale analysis after such a file changed (reproduced: resolution
  limitations vanished). Hidden directories (e.g. `.fvm` toolchain links) are
  pruned from the walk so key computation cannot balloon into hashing a whole
  Flutter SDK, and nested-package discovery widens to pubspecs outside the
  standard directories. Relative imports that leave the root remain a
  documented coverage boundary. `toolVersion` is part of the cache identity, so
  upgrading to 0.4.1 invalidates existing caches automatically (one reanalysis)
- Hardened the CLI error boundary: `Error`s (TypeError, RangeError, …) escaping
  from analyzer/yaml internals are contained at the command boundary as an
  analysis failure (exit 2) — no more stack traces echoing internal paths or an
  undocumented exit 255. This also closes per-command catch asymmetries (e.g.
  `_runBaseline` had no `on ArgumentError`; compare/query leaked ArgumentErrors)
- The bridges control-character policy rejection now reports "Bridges extraction
  failed: …" instead of "unable to index the package" (correct attribution — the
  rejection is an extraction policy, not an indexing failure)
- Non-UTF8 `git` output (possible filenames on Linux) folds into the
  ChangedFilesException diagnosis ("Changed files could not be computed…")
  instead of surfacing as a misattributed indexing failure
- Unified the control-character and injection policy across every human and CI
  output surface (audit follow-up: newline-bearing filenames could cut a Mermaid
  label into two statements, forge text diagnostic lines, and pass ESC/bidi
  characters through to GitHub Actions logs)
  - Mermaid: CR·LF become the documented entity codes (`#13;`·`#10;`) so labels
    always stay on one physical line; a literal `#10;` in the source round-trips
    thanks to the leading `#`→`#35;` substitution
  - DOT: raw CR is now escaped like LF (a display-level line break; statement
    structure is preserved)
  - text reports: C0·DEL characters in paths, ids, evidence, and limitations
    become visible escapes (`\n`·`\r`·`\t`·`\xNN`) — a second `path:line:col:`
    diagnostic line can no longer be forged and terminal ANSI injection is
    neutralized
  - GitHub Actions: percent encoding extends beyond the spec minimum (`%`, CR,
    LF, `:`·`,` in properties) to C0·DEL·C1, U+2028/2029, and the bidi controls
    (U+202A–202E·U+2066–2069) — same `%0D`/`%0A` convention, normal inputs
    unchanged
  - SARIF: the artifact `uri` is built from per-path-segment encoding instead of
    `Uri(path:)`, which silently corrupted `back\slash.dart` into
    `back/slash.dart` and misattributed a literal `%41.dart` as `A.dart`
  - The policy table is documented on the export module
    (`lib/src/export/graph_exporter.dart`). Only pathological inputs change
    bytes; normal paths and ids are byte-identical

## 0.4.0

- Added `// dartograph:ignore` inline comments (absorbing Periphery's comment command)
  - When the body of a line comment above a declaration **starts** with the marker
    (doc comments and block comments are not directives), the declaration's dead report
    is suppressed. Prose that merely mentions the marker does not trigger suppression, and a
    reason can follow as in `// dartograph:ignore — reason`. A trailing comment at the end of a line
    (`void foo() {} // dartograph:ignore`) is not interpreted as suppressing the next
    declaration (misattribution guard). For variables and fields, the marker on the
    enclosing declaration applies
  - A suppressed declaration becomes a retention root with `retentionReason: inlineIgnore`,
    so `dead --explain`, `query`, and compare answer with that evidence. The user directive
    takes precedence over other retention reasons. Because it is a reachability root, what
    the suppressed declaration references also disappears from the report — use a baseline
    to suppress a single finding. Only the declaration itself is suppressed; it does not
    propagate to members or files
  - Retention-root extraction semantics changed, so the analysis cache identity is bumped
    to v5. Old caches are reanalyzed automatically (serialization format unchanged)
- Added `--level <file|type|symbol>` and `--collapse <n>` to `graph` (absorbing cartograph's
  `graph --level` and dependency-cruiser's `--collapse`)
  - `--level file` folds declarations into their libraries, `type` folds members into
    top-level declaration containers, and `symbol` (the default) draws the graph as is.
    Self-loops created by folding are dropped and edges are deduplicated after
    representative substitution. The default output is byte-for-byte identical to before
  - dartograph analyzes a single package, so cartograph's module resolution does not exist
    (folding to the package yields one vertex) — `file` is the coarsest level
  - `--collapse <n>` summarizes the file-level graph to the leading n path segments
    (`project:lib/src/a.dart` becomes `project:lib/src` at n=2). Folder vertices are
    aggregates without location fields. Combining with a level other than `--level file`,
    a missing value, duplicates, an unknown resolution, values below 1, and non-integers
    are usage errors (64)
- Added `html` to `graph --format` (absorbing cartograph's `graph --format html`)
  - A single self-contained HTML file with no external CDN, script, or font references at
    all. It opens on air-gapped networks and in CI artifacts; the graph facts ride in a
    `<script type="application/json">` payload and render with an inline canvas
    force-directed layout, search, pan, and zoom
  - Above 400 vertices the most connected vertices are kept first, and the truncation is
    stated on the page and in the payload (`truncatedFrom`). Use `--format dot` for the
    full graph
  - `<` in the payload becomes `\u003c` (a valid JSON escape) so dartograph's own node IDs
    like `<no-library>` cannot break script-tag tokenization. Limitations ride both in a
    collapsible header list and in the payload
- Added the `affected <git-ref> <package-root>` command (absorbing dependency-cruiser's
  `--affected`)
  - Seeds the libraries to which files changed since a Git reference (commit, branch, tag,
    `HEAD~1`, …) are attributed, walks import/export edges in reverse, and answers with the
    transitively dependent libraries as JSON. Changes to part files are attributed to the
    host library
  - Each affected library carries `path` and `depth` evidence — the shortest dependency
    chain to the nearest changed library — and `changed` (seeds) and `affected` (dependents)
    do not overlap. The impact radius is a library (file) level observation
  - Changed Dart files that belong to no analyzed library are reported as the
    `changed-dart-files-without-library` limitation. Git failures get the same diagnosis and
    exit code 2 as `--since`; a successful report exits 0 regardless of the impact count
- Added `dead --report-test-only` (cartograph parity)
  - Recomputes reachability without the test-directory (`test/`, `integration_test/`, …)
    retention roots and selects production declarations reached only from tests. This is
    not dead code — it is the observation that "tests are the only caller"
  - Reported at `info` severity (text `info:`, github-actions `::notice`, sarif `note`,
    ruleId `test-only-declaration`), and the exit code is 0 even with findings (it never
    fails the build). Declarations inside test directories and `@visibleForTesting`
    production declarations are conservatively excluded
  - Does not combine with `--explain` (a single-target query) or `--baseline` (which
    suppresses dead findings) — usage 64; `--since` and `--format` are allowed
- Added `cycles --explain <symbol-id>` and `rules --explain <symbol-id>` (cartograph
  evidence parity)
  - `cycles --explain` emits as JSON the cycles a vertex takes part in as a strongly
    connected component and each cycle's `breakCandidate` (candidate edge to break). A
    vertex belongs to at most one strongly connected component, so the answer is 0 or 1
    cycles
  - `rules --explain` emits as JSON the layer the vertex is assigned to, the
    `matchedPattern` and `matchedCandidate` that decided the assignment, and the `rules`
    starting from that layer. With no matching layer those fields are null/empty lists
    (`--config` is still required)
  - Both `--explain` forms are single-vertex queries and do not combine with `--strict`
    (usage 64). An ID absent from the graph is answered with `known: false` and exit code
    64; a known ID exits 0 regardless of participation
- Added `--depth <n>` and `--limit <n>` to `query` (cartograph SymbolQueryDocument parity)
  - `--depth` (default 1) follows usage relations (`usedBy`, `dependsOn`) with BFS up to n
    hops; each neighbor's `depth` field says how many steps it is from the queried symbol.
    All edge kinds reaching one neighbor ride in `edges`, and a neighbor reachable through
    several paths is reported once at its shortest depth
  - `--limit` caps the number of neighbors per direction; when it omits neighbors, that
    direction's `truncated` becomes `true` and omitted neighbors are not expanded further.
    Containment (`members`, `declaredIn`) is always one hop
  - The defaults (depth 1, no limit) preserve the previous output, with one **narrow
    breaking change**: usage edges pointing at a symbol itself (recursion) are excluded
    from that symbol's own neighborhood, matching cartograph (the old 1-hop walk included
    them). Values below 1, non-integers, missing values, and duplicate flags are usage
    errors (64). Combines with `--batch` and `--baseline`
- Fixed a false positive that reported `operator` declarations in use as dead
  - Operator syntax (`a + b`, `a[i]`, `-a`, `a++`, `a += b`) resolves through tokens
    rather than identifiers, so no usage edges were created; operator declarations on
    classes and extension types were wrongly reported unreachable while being consumed
  - Resolved operators are now recorded as `call` edges. The `a[i] = v` write keeps its
    existing reference path, and the `[]`/`[]=` that compound assignment and increment
    (`m[i] += v`, `m[i]++`) read and write through are recorded as operator calls too.
    Built-in operators (dart:core) have no nodes and gain no edges; unused operators and
    read operators consumed only by writes keep being reported (bidirectional corpus
    regression)
  - Extraction semantics changed, so the analysis cache identity is bumped to v4. Old
    caches are reanalyzed automatically (serialization format unchanged)
- Input error messages are now distinguished per cause so they never point at the wrong one
  - A missing baseline file yields "Baseline is invalid: create it with dartograph
    baseline --write" instead of "unable to index the package"
  - A missing or invalid `rules --config` file yields "Analysis failed: unable to read the
    rules configuration." (distinguished from indexing failure; the `Analysis failed:`
    prefix is kept)
  - A `baseline --write` write failure (destination creation, permissions) yields "Baseline
    write failed: unable to write the baseline file." instead of "unable to index the
    package" (indexing already succeeded)
- Dead-file findings for percent-encoded filenames keep their file-level limitations
  - `%20` and friends preserved by `Uri.path` are decoded so they match the source
    limitations the analyzer built from real paths; previously those files' limitations
    silently vanished from findings
- Mermaid output escapes `<`, `>`, `&`, `"`, `\`, and `#` in its own node IDs with HTML
  entity codes
  - Fixes Mermaid mistaking `<no-library>` and `<unnamed-extension@...>` for HTML tags,
    caused by reusing the DOT backslash escape
  - Quotes cut a quoted string in half and break label structure, so they become the
    entity codes Mermaid documents (`#quot;`, backslash `#92;`, `#` itself `#35;`)
- `--help` now states that `--explain` requires `--format json` and does not combine with
  `--baseline` or `--since`
- The agent `skill` output gains an `affected` entry and `inlineIgnore` evidence wording
  (updated alongside the new features)

## 0.3.0

- Fixed unreachable false positives for enum constants consumed only through `.values`
  - Enum constants have only enum→constant `member` edges, which do not count as usage,
    and container rescue runs member→container only, so constants could not be saved.
    With consumption like `Status.values` that never references individual constants, even
    constants of a reachable enum were wrongly reported `dead`
  - A reachable enum now retains its constants, and `explain` returns the `retained by its
    reachable enum` evidence together with a real path to the enum. If the enum itself is
    unreachable, its constants keep being reported
  - Node serialization gains the enum-constant flag, bumping the cache schema to v2. Old
    caches are rejected at decode and reanalyzed
- Fixed silent-miss and total-failure defects in Flutter channel fact extraction
  - When `static final _channel = MethodChannel(...)` was declared after its uses inside a
    class or other declaration body, method-invoke facts were dropped entirely and downgraded to
    `unresolved-receiver-invocations` counts without position or symbol. Declaration-body
    fields are now prescanned, so resolution no longer depends on declaration order;
    shadowing by a same-named top-level channel is still respected
  - A single empty channel or method name such as `MethodChannel('')` used to fail the
    whole `bridges` document without file or line information. Only that fact is now
    skipped and aggregated into the `empty-bridge-names` limitation while the remaining
    facts are emitted normally. Names containing control characters are still rejected
    entirely
- Fixed `dead --since` missing changed files under `diff.relative=true` and in
  sub-packages
  - `git diff` prints cwd-relative paths, which were joined with the repository root,
    misaligning paths and silently dropping all findings (exit 0). `git` now runs with
    `-c diff.relative=false` so paths are always repository-root relative
- Fixed option-shaped values being accepted as paths
  - `baseline --write --force .` actually created a file named `--force` and reported
    success; it is now rejected as a usage error (64) before indexing and writing
  - Calls with a missing value now yield usage errors (64) instead of analysis failures
    (2): the package root of `query`, `bridges`, and `graph`, and the values of
    `rules --config` and `dead --baseline`/`--since`
  - `compare` only checked for `--`, so an existing short option like `compare -h .` was
    accepted as a path; single-dash values are rejected too
  - **Narrow breaking change**: calls that used to work by passing a path starting with
    `-` (e.g. `baseline --write -b.json .`) now exit 64. Pass `./-name` instead.
    `bridges` keeps the existing `--` escape. This was an undocumented implicit allowance,
    and `query --batch` had the same restriction from the start
- Fixed `dead --explain` asserting a container retained by a member was unreachable
  - `explain` answered "unreachable from all retention roots" with exit code 1 for
    declarations that `dead` in the same run excluded from findings
  - It now returns the `retained by a reachable member` evidence with the witness member
    and a real path to that member, and exits 0
  - `query`'s `retainedByMember` state and `compare`'s witness notation are unchanged
- Symlinked Dart sources are included in analysis-cache inputs and the bridge scan
  - The analyzer follows both file and directory links, but they were missing from the
    input list, so editing a link target left the cache key unchanged and returned a stale
    graph; fixed
  - Platform-channel facts of linked sources, missed for the same reason, are now
    extracted too
  - Directory links record the already-followed real paths so cycles do not loop forever
  - Broken links keep being excluded (there is no target)
- Added the `dartograph.yaml` `entry_points` option to declare real build targets and
  narrow `main` retention roots
  - Without it, the previous conservative policy (every `main` under `lib/`, `bin/`,
    `example/`) is kept
  - Empty documents and comment-only documents declare no entry points and are treated the
    same (default policy); only a non-empty non-mapping document is rejected
  - Empty, absolute, outside-root, non-string, out-of-scope (not under `lib/`, `bin/`,
    `example/`), missing, or non-`.dart` paths are reported as analysis failures instead
    of being silently ignored
  - An entry point that exists but has no `main` is reported as the
    `configured-entry-point-without-main` limitation
  - Retention-root semantics changed, so the analysis-cache identity is bumped to v3 and
    the configuration is included in the cache key

## 0.2.0

- Per-source limitations (analysis errors, unresolved invocations, conditional
  configurations) attached to findings
- `query --batch` and the library-facing `SymbolQuerySession`, sharing one index and
  reachability computation
- `compare`, explaining graph changes between two checkouts and the reachability paths
  that disappeared
- Supported Dart declaration names added to bridge facts, with isthmus round-trip evidence
  verified in both directions
- Source-mutation regression evaluation and query-session performance measurement tooling

## 0.1.1

- UTC millisecond generation timestamps and UTF-8 byte positions per isthmus
  GRAPH-EXCHANGE v1
- MethodChannel extraction following Flutter services import provenance and lexical scope
- cascade and invokeListMethod/invokeMapMethod support, dynamic-name facts, and
  unattributed/invalid-call limitations
- EventChannel, BasicMessageChannel, conditional imports, and re-exports reported as
  limitations instead of false facts
- Usage through Flutter services re-exports is preserved toward the documented miss
  instead of being guessed
- explain's not-found and file evidence hardened; analyzer identity, generated code, and
  nested-dependency cache decisions hardened
- Invalid CLI calls distinguished from Git failures; option-shaped skill paths rejected

## 0.1.0

- Deterministic symbol- and file-level dependency graphs on Dart analyzer 14.3.0
- `dead`, `query`, `cycles`, `rules`, and `metrics` with evidence and limitations
- DOT, Mermaid, JSON, text, GitHub Actions, and SARIF output
- `--since` combining a baseline with a Git change scope
- Corruption-tolerant persistent fact cache keyed by contents and analyzer identity
- Retention rules: package-barrel public API, multiple mains, overrides, generated code,
  tests, plugins
- `bridges`, exporting Flutter platform-channel exchange facts
- `skill`, printing and installing safety guidance for agents
- Exit codes `0/1/2/64`, a false-positive corpus, and a 90% line-coverage gate
- Retention-root evidence for large projects bounded by count, a 20-item sample, and a
  truncation flag

dartograph is MIT licensed and permanently free, commercial use included. It provides no
deletion verdicts and no automatic deletion.
