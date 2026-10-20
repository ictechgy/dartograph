# Changelog

## Unreleased

- Fix "dartograph: Check Impact of Current File". It always failed with "dartograph impact failed — see output" because the changed list was passed to `impact --changed` as inline JSON instead of a file path. The list is now written to a temporary `changes.json` that is deleted after the run. Impacted symbols with `high` risk are now shown as warnings; they were shown as information with `risk: undefined`.
- Compatibility: the default `dartograph.args` is now `["--incremental-user-cache"]`, which keeps the incremental fact cache in dartograph's per-user cache directory instead of `.dartograph/cache` inside the workspace, so a repository can no longer plant cache files that the extension trusts. It needs a dartograph CLI newer than 0.16.2; with an older CLI every run fails with a usage error in the output channel, so upgrade the CLI or set `dartograph.args` to `[]`. An explicit `dartograph.args` setting is kept.
- Compatibility: `dartograph.executable` is now machine-scoped: it can be set only in user or remote settings, and VS Code ignores it in a workspace `.vscode/settings.json`, even in a trusted workspace. Move a workspace value to your user settings. Relative paths such as `./tools/dartograph` are no longer run, and the *dartograph* output channel says why; use an absolute path or a command name on `PATH`. A command name is looked up only in the absolute directories on `PATH`, never in the package folder: on Windows the package folder is no longer searched before `PATH`, and elsewhere an empty or relative `PATH` entry (such as a trailing `:` or `.`) is skipped. If no executable is found there, the output channel says so. On Linux and macOS the CLI also gets a `PATH` with only those absolute directories (`/usr/bin:/bin` if none is left), so the `sh` and `dart` that the `dart pub global activate` script runs and the `git` that the CLI runs for `--since` and `--record` are not found in the package folder either; keep the directories they need on `PATH` as absolute paths. On Windows the environment is passed unchanged, so there only the CLI itself is guaranteed not to come from the package folder.
- The extension declares limited support for untrusted workspaces. In Restricted Mode it now runs, using only your user settings for `dartograph.executable`, `dartograph.args`, and `dartograph.runOnSave`; it used to stay disabled there.

## 0.1.2

- Replace the node D icon with the selected Scout bird mascot.
- Remove the superseded vector source; the extension's analysis behavior is unchanged.

## 0.1.1

- Add the node D icon to the extension and Marketplace listing.
- Exclude unselected icon drafts and vector source from the extension package.

## 0.1.0

- Initial release with workspace findings, change impact, and optional analysis on save.
