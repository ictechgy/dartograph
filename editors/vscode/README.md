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

The default `dartograph.args` passes `--incremental-user-cache`, which needs a
dartograph CLI newer than 0.16.2. With an older CLI every run fails with a usage
error in the *dartograph* output channel: upgrade the CLI, or set
`dartograph.args` to `[]` until you can. Avoid pointing `--incremental` at a
directory inside a workspace you do not trust; a repository can commit cache
files there.

## Commands

| Command | What it does |
|---|---|
| `dartograph: Analyze Workspace` | Runs `dead`, `deps`, and `dup` on every workspace folder containing `pubspec.yaml`, and maps findings to Problems. |
| `dartograph: Check Impact of Current File` | Runs `impact --changed` with the open Dart file and marks impacted symbols and related tests. |
| `dartograph: Clear Findings` | Clears dartograph diagnostics. |

## Settings

| Setting | Default | Scope | Meaning |
|---|---|---|---|
| `dartograph.executable` | `dartograph` | `machine`: user or remote settings only | The CLI: an absolute path, or a command name looked up in the absolute directories on `PATH`. Relative paths such as `./tools/dartograph` are rejected with a message in the *dartograph* output channel. |
| `dartograph.runOnSave` | `false` | `window`: user or workspace settings (user settings only in Restricted Mode) | Re-run the workspace analysis shortly after a Dart file is saved. |
| `dartograph.minTokens` | `40` | `window`: user or workspace settings | Minimum token window reported by `dup`. |
| `dartograph.args` | `["--incremental-user-cache"]` | `window`: user or workspace settings (user settings only in Restricted Mode) | Extra arguments appended to every invocation. The default keeps the incremental fact cache in dartograph's per-user cache directory, outside the workspace. |

VS Code ignores `dartograph.executable` in a workspace `.vscode/settings.json`,
even in a trusted workspace, so a checked-out repository cannot point it at a
script it ships. A relative path would resolve inside the package folder, so it
is not run either. A command name is looked up only in the absolute directories
on `PATH`, and the extension runs the path it finds: on Windows Node would
otherwise look in the package folder before `PATH`, and on other systems an
empty or relative `PATH` entry (a leading, trailing, or doubled `:`, or `.`)
would resolve inside the package folder. On those systems only an executable
regular file counts, and an empty `PATH` means `/usr/bin:/bin`.

The CLI runs in the package folder and looks up the programs it needs by name
too: the script that `dart pub global activate` installs starts with
`#!/usr/bin/env sh` and runs `dart`, and the CLI runs `git` for `--since` and
`--record`. So on Linux and macOS the extension also passes the CLI a `PATH`
that keeps only its absolute directories, in order (`/usr/bin:/bin` if none is
left). Keep the directories these programs need on `PATH` as absolute paths.
On Windows the extension passes its environment unchanged: Windows can look in
the package folder before `PATH` when the CLI starts a program by name, so there
only the CLI itself is guaranteed not to come from the package folder.

## Workspace Trust

The extension supports Restricted Mode with limits. In an untrusted workspace
it still runs, but it takes `dartograph.executable`, `dartograph.args`, and
`dartograph.runOnSave` only from your user settings. Trusting the workspace
applies the workspace's own `dartograph.args` and `dartograph.runOnSave`. The
CLI analyzes the workspace's sources without running the project's code. On
Linux and macOS neither the CLI nor the programs it starts by name are looked
up in the package folder (see above); on Windows this holds only for the CLI
itself.

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
node test/executable.test.js
node test/extension.test.js
```

Package with `vsce package` (requires `npm i -g @vscode/vsce`), or copy this
directory into `~/.vscode/extensions/` for local use.
