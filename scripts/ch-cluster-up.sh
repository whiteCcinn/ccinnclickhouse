#!/bin/bash
# Two replicas of one shard with an embedded Keeper on node1, plus a chproxy in front of both:
#   ccinnch-it-node1 → 127.0.0.1:18111, ccinnch-it-node2 → 127.0.0.1:18112, ccinnch-it-proxy → 127.0.0.1:18110
# scripts/ch-cluster-up.sh [version]   (default 24.8)
set -euo pipefail
version=${1:-24.8}
here=$(cd "$(dirname "$0")" && pwd)
image=${CCINNCH_IMAGE:-clickhouse/clickhouse-server:$version}
network=ccinnch-it-net
docker network inspect "$network" >/dev/null 2>&1 || docker network create "$network" >/dev/null
for n in 1 2; do
  name="ccinnch-it-node$n"
  docker rm -f "$name" >/dev/null 2>&1 || true
  extra=()
  [ "$n" = 1 ] && extra=(-v "$here/docker/cluster/keeper.xml:/etc/clickhouse-server/config.d/keeper.xml:ro")
  docker run -d --name "$name" --hostname "$name" --network "$network" --memory 768m --memory-swap 768m \
    -p "127.0.0.1:1811$n:8123" -e CLICKHOUSE_SKIP_USER_SETUP=1 \
    -v "$here/docker/config.d/ccinn-lowmem.xml:/etc/clickhouse-server/config.d/ccinn-lowmem.xml:ro" \
    -v "$here/docker/users.d/ccinn-users.xml:/etc/clickhouse-server/users.d/ccinn-users.xml:ro" \
    -v "$here/docker/cluster/cluster.xml:/etc/clickhouse-server/config.d/cluster.xml:ro" \
    -v "$here/docker/cluster/macros-node$n.xml:/etc/clickhouse-server/config.d/macros.xml:ro" \
    "${extra[@]}" "$image" >/dev/null
done
docker rm -f ccinnch-it-proxy >/dev/null 2>&1 || true
docker run -d --name ccinnch-it-proxy --network "$network" --memory 128m -p 127.0.0.1:18110:9090 \
  -v "$here/docker/cluster/chproxy.yml:/config.yml:ro" contentsquareplatform/chproxy:v1.30.0 -config /config.yml >/dev/null
for port in 18111 18112; do
  for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$port/ping" >/dev/null && break; sleep 1; done
done
for _ in $(seq 1 30); do
  curl -s -u ccinn:ccinn-pass http://127.0.0.1:18111/ --data-binary "SELECT count() FROM system.zookeeper WHERE path = '/'" 2>/dev/null | grep -q '^[0-9]' && break
  sleep 1
done
echo "cluster ready: node1 http://127.0.0.1:18111, node2 http://127.0.0.1:18112, chproxy http://127.0.0.1:18110"
