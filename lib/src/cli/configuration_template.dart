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

# Architecture layers and boundary rules.
# Used by `dartograph rules <rules-file> <package-root>`.
# layers:
#   - name: Presentation
#     match:
#       - "lib/ui/**"
#       - "lib/screens/**"
#   - name: Domain
#     match:
#       - "lib/domain/**"
#   - name: Data
#     match:
#       - "lib/data/**"

# rules:
#   - name: Presentation must not access Data directly
#     from: Presentation
#     deny:
#       - Data
#   - name: Domain must not depend on Presentation or Data
#     from: Domain
#     deny:
#       - Presentation
#       - Data

# Architecture metric thresholds for `dartograph metrics --strict`.
# thresholds:
#   max_distance: 0.3
''';
