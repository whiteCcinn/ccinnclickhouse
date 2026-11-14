#!/bin/bash
# Starts one ClickHouse test server: scripts/ch-up.sh <version> [host-port] [extra docker args…]
# Container: ccinnch-it-<version>, HTTP on 127.0.0.1:<port> (default 18101), memory-capped, low-memory config.
# Users: ccinn/ccinn-pass (full access) and reader/reader-pass (server profile readonly=1).
set -euo pipefail
version=${1:?usage: ch-up.sh <version> [port]}
port=${2:-18101}
shift $(( $# >= 2 ? 2 : 1 ))
here=$(cd "$(dirname "$0")" && pwd)
image=${CCINNCH_IMAGE:-clickhouse/clickhouse-server:$version}
name="ccinnch-it-${version//[^0-9a-z]/-}"
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" --memory 768m --memory-swap 768m \
  -p "127.0.0.1:${port}:8123" -e CLICKHOUSE_SKIP_USER_SETUP=1 \
  -v "$here/docker/config.d/ccinn-lowmem.xml:/etc/clickhouse-server/config.d/ccinn-lowmem.xml:ro" \
  -v "$here/docker/users.d/ccinn-users.xml:/etc/clickhouse-server/users.d/ccinn-users.xml:ro" \
  "$@" "$image" >/dev/null
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${port}/ping" >/dev/null; then
    echo "$name ready on http://127.0.0.1:${port} ($(curl -s -u ccinn:ccinn-pass "http://127.0.0.1:${port}/" --data-binary 'SELECT version()'))"
    exit 0
  fi
  sleep 1
done
echo "$name did not become ready" >&2
docker logs --tail 30 "$name" >&2
exit 1
