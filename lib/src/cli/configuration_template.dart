/// `dartograph init`이 생성하는 주석 달린 기본 `dartograph.yaml` 템플릿이다.
const configurationTemplate = '''
# Dartograph configuration
# Docs: https://github.com/ictechgy/dartograph

# Real build targets whose main() functions should be retained.
# By default, dartograph conservatively retains all main() functions
# under lib/, bin/, and example/. Declare entry_points to narrow retention
# to specific application entry points.
# entry_points:
#   - lib/main.dart

# Local path dependency package roots whose lib/ sources should be included.
# Keep this opt-in; the default analysis scope does not crawl vendor packages.
# source_packages:
#   - vendor/shared_preferences_android

# Report scope for dead, deps, and dup findings (gitignore-style globs
# matched against the source path after its project:/package: scheme).
# include narrows the scope to matching sources; exclude then removes
# matches. The dependency graph itself is unchanged — these keys only
# decide which findings get reported.
# include:
#   - lib/**
# exclude:
#   - lib/generated/**

# Retention roots declared by name or file glob — the config-file form of
# "// dartograph:ignore". retained_names matches the declaration name
# (including "Class.member"); retained_files retains every declaration in
# matching files.
# retained_names:
#   - '*.fromJson'
# retained_files:
#   - lib/gen/**

# Thresholds that metrics --strict gates on.
# thresholds:
#   distance: 0.3      # max |D'| before strict fails (default 0.3)
#   complexity: 40     # max function cyclomatic complexity
''';
