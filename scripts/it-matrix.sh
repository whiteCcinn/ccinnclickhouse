#!/bin/bash
# Runs the integration suite against each ClickHouse version in turn (one container at a time):
#   scripts/it-matrix.sh 22.8 23.8 24.8 25.8 26.8
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/.."
swift build --build-tests >/dev/null 2>&1 || { echo "build failed"; exit 1; }
summary=()
for version in "$@"; do
  name="ccinnch-it-${version//[^0-9a-z]/-}"
  if ! "$here/ch-up.sh" "$version" 18101; then summary+=("$version: server did not start"); continue; fi
  "$here/seed-demo.sh" 18101 || { summary+=("$version: seed failed"); docker rm -f "$name" >/dev/null; continue; }
  output=$(CCINNCH_IT_URL=http://127.0.0.1:18101 swift test --skip-build --filter IntegrationTests 2>&1)
  echo "$output" | grep -E '✘|Test run' | sed "s/^/[$version] /"
  summary+=("$version: $(echo "$output" | grep 'Test run' | tail -1)")
  docker rm -f "$name" >/dev/null
done
printf '%s\n' "${summary[@]}"
