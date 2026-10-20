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
`DARTOGRAPH_EXECUTABLE` environment variable). It passes
`--incremental-user-cache`, so it needs a dartograph CLI newer than 0.16.2;
with an older CLI both commands fail with a usage error and no diagnostics
appear.

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

The first analysis pass of a package loads its report synchronously: the
plugin runs `dead` and then `dup`, two CLI runs per package (the incremental
fact cache in dartograph's per-user cache directory, outside the project, makes
repeated runs cheaper). After that, reports refresh in the background, and only
when the package changed on disk:

- Once the refresh interval has passed, the next analysis pass checks the
  package for changes. The interval is 30 seconds, or ten times the last run
  time if that is longer, up to 30 minutes.
- A change is a different size, modification time, or set of the `*.dart`,
  `pubspec.yaml`, `analysis_options.yaml`, `dartograph.yaml`, and `build.yaml`
  files under the package, or of the `.dart_tool/package_config.json` that
  `dart pub get` writes (for a pub workspace member, the nearest one above the
  package). Hidden directories, `.dart_tool`, and `build` are otherwise
  ignored, and symbolic links are not followed, so an edit reached only through
  a link, or in a path dependency outside the package, is picked up at the next
  change inside the package.
- A refresh runs `dead` and `dup` together. At most two packages refresh at a
  time, so at most four CLI processes run in the background; the others wait
  their turn.
- A report where a command failed is retried after the interval even when
  nothing changed.

Findings reflect the files saved on disk, not unsaved editor buffers.

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
