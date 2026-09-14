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
''';
