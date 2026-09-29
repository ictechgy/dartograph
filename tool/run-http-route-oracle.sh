#!/usr/bin/env bash
# 모의 서버 오라클을 다시 실행한다(네트워크: pub.dev에서 fixture 의존성을 받는다).
#
# 1. fixtures/http_routes를 임시 디렉터리에 복사하고 실제 http·dio·retrofit·chopper를
#    pub get으로 받는다(버전은 fixture pubspec에 고정).
# 2. bin/oracle.dart가 127.0.0.1의 임시 포트 HttpServer에 모든 요청을 모아 기록한다
#    (HttpOverrides 프록시 — 외부로 나가는 요청은 없다).
# 3. 같은 복사본을 실제 패키지로 해석해 routes 사실을 내고 tool/route_oracle.dart로
#    대조 표를 출력한다. 불일치가 있으면 1로 끝난다.
# 4. 기록을 fixtures/http_routes/oracle/recorded.json에 저장한다. 기본 CI는 이
#    스크립트를 돌리지 않고, test/index/route_oracle_test.dart가 커밋된 기록을
#    스텁 해석 사실과 대조한다.
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dart_bin=${DART:-dart}
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/dartograph-route-oracle.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT
app="$temporary_directory/app"

cp -R "$repo_root/fixtures/http_routes" "$app"
rm -f "$app/analysis_options.yaml"
rm -rf "$app/.dart_tool" "$app/pubspec.lock"
(cd "$app" && "$dart_bin" pub get >/dev/null && "$dart_bin" run bin/oracle.dart "$temporary_directory/recorded.json")
(cd "$repo_root" && "$dart_bin" run dartograph routes --role client \
  --wrappers "$app/http-wrappers.json" --format json "$app" >"$temporary_directory/facts.json")
set +e
(cd "$repo_root" && "$dart_bin" run tool/route_oracle.dart \
  "$temporary_directory/facts.json" "$temporary_directory/recorded.json")
status=$?
set -e
cp "$temporary_directory/recorded.json" "$repo_root/fixtures/http_routes/oracle/recorded.json"
exit "$status"
