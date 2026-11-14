#!/bin/bash
# Loads scripts/seed-demo.sql into a test server: scripts/seed-demo.sh [port] (default 18101).
set -euo pipefail
port=${1:-18101}
here=$(cd "$(dirname "$0")" && pwd)
url="http://127.0.0.1:${port}/"
statement=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in --*|"") continue ;; esac
  statement+="$line"$'\n'
  if [[ "$line" == *";" ]]; then
    out=$(curl -s -u ccinn:ccinn-pass "$url" --data-binary "${statement%;*}")
    if [[ "$out" == Code:* ]]; then echo "failed: ${statement:0:80}… → $out" >&2; exit 1; fi
    statement=""
  fi
done < "$here/seed-demo.sql"
# Many small inserts into a table with merges stopped: a part-count warning.
for i in $(seq 1 14); do curl -s -u ccinn:ccinn-pass "$url" --data-binary "INSERT INTO shop.tiny_parts VALUES ($i, now())" >/dev/null; done
curl -s -u ccinn:ccinn-pass "$url" --data-binary "SYSTEM FLUSH LOGS" >/dev/null || true
echo "seeded shop on port ${port}"
