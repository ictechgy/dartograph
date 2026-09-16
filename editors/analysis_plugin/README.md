# dartograph_analysis_plugin

Analysis server plugin that surfaces
[dartograph](https://github.com/ictechgy/dartograph) graph findings as
diagnostics — in the IDE and in `dart analyze` — plus a quick fix to suppress a
dead-code finding with `// dartograph:ignore`.

Findings are evidence-backed observations, never a deletion verdict.

## Requirements

```sh
dart pub global activate dartograph
```

The plugin runs the `dartograph` executable on PATH (override with the
`DARTOGRAPH_EXECUTABLE` environment variable).

## Enable

In the analyzed project's `analysis_options.yaml`:

```yaml
plugins:
  dartograph_analysis_plugin: ^0.1.0
```

Or while developing locally:

```yaml
plugins:
  dartograph_analysis_plugin:
    path: /path/to/dartograph/editors/analysis_plugin
```

## Diagnostics

| Code | Source report |
|---|---|
| `dartograph_dead_code` | `dead --format json` — unreachable declarations and files |
| `dartograph_duplicate_block` | `dup --format json` — token-structural duplicate blocks |

The first analysis pass loads the report synchronously (one CLI run per
package; the incremental cache under `.dartograph/cache` keeps it fast).
Reports refresh in the background after a short TTL, so findings track edits
on subsequent analysis passes.

## Quick fix

On a `dartograph_dead_code` diagnostic at a declaration, the **Add
'// dartograph:ignore'** fix inserts the suppression comment — a decision
recorded in the graph as `retentionReason: inlineIgnore`. File-level findings
do not offer the fix because the comment only applies to declarations.

## Development

```sh
dart pub get
dart analyze
dart test
```
