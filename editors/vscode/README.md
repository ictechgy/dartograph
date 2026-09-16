# dartograph for VS Code

Editor surface for [dartograph](https://github.com/ictechgy/dartograph), the
permanently free (MIT) dependency-graph and evidence-query CLI for Dart.

The extension shells out to the `dartograph` executable and renders its JSON
reports in the **Problems** panel. It does not replace the Dart analyzer —
findings are graph evidence with stated limitations, never a deletion verdict.

## Install

The extension is on the
[marketplace](https://marketplace.visualstudio.com/items?itemName=ictechgy.dartograph)
— search for **dartograph** in the Extensions view. It also needs the CLI:

```sh
dart pub global activate dartograph
```

## Commands

| Command | What it does |
|---|---|
| `dartograph: Analyze Workspace` | Runs `dead`, `deps`, and `dup` on every workspace folder containing `pubspec.yaml`, and maps findings to Problems. |
| `dartograph: Check Impact of Current File` | Runs `impact --changed` with the open Dart file and marks impacted symbols and related tests. |
| `dartograph: Clear Findings` | Clears dartograph diagnostics. |

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `dartograph.executable` | `dartograph` | Path to the CLI. |
| `dartograph.runOnSave` | `false` | Re-run the workspace analysis shortly after a Dart file is saved. |
| `dartograph.minTokens` | `40` | Minimum token window reported by `dup`. |
| `dartograph.args` | `["--incremental", ".dartograph/cache"]` | Extra arguments appended to every invocation. |

## Reading the findings

- **dead** findings are warnings like `declaration: not reachable from
  retained roots`. They are observations with evidence, not deletion advice.
- **deps** findings are pinned to `pubspec.yaml` because the audit reports
  package names, not source ranges.
- **dup** findings are informational ranges spanning each duplicated block.
- Report `limitations` are written to the *dartograph* output channel —
  absence of findings is not proof of safety.

## Build and test

The extension is plain CommonJS JavaScript with no build step.

```sh
node --check extension.js
node test/mapper.test.js
```

Package with `vsce package` (requires `npm i -g @vscode/vsce`), or copy this
directory into `~/.vscode/extensions/` for local use.
