## 0.1.1

- Compatibility: the plugin runs `dead` and `dup` with `--incremental-user-cache` instead of `--incremental .dartograph/cache`, so the incremental fact cache lives in dartograph's per-user cache directory outside the package and a repository can no longer plant cache files that the plugin trusts. It needs a dartograph CLI newer than 0.16.2; with an older CLI both commands fail with a usage error and no diagnostics appear.
- Reports refresh only when the package changed on disk. After the refresh interval, a background check compares the size, modification time, and set of the `*.dart`, `pubspec.yaml`, `analysis_options.yaml`, `dartograph.yaml`, and `build.yaml` files under the package and the `.dart_tool/package_config.json` that `dart pub get` writes, and re-runs the CLI only when they differ; symbolic links are not followed. The interval is 30 seconds, or ten times the last run time if that is longer, up to 30 minutes. At most two packages refresh at a time, and a refresh runs `dead` and `dup` together. A report where a command failed is still retried after the interval. Previously every package re-ran `dead` and then `dup` every 30 seconds while its files were analyzed, even when nothing changed, with no limit across packages. The first analysis pass still runs `dead` and then `dup` synchronously.

## 0.1.0

- `dartograph_dead_code` warning diagnostics from `dartograph dead --format json`
- `dartograph_duplicate_block` info diagnostics from `dartograph dup --format json`
- Quick fix adding `// dartograph:ignore` above a flagged declaration
- TTL-cached CLI reports with failure/empty-report distinction and
  `DARTOGRAPH_EXECUTABLE` override
