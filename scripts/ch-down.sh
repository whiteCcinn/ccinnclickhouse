#!/bin/bash
# Removes every CcinnClickHouse test container (ccinnch-it-*) and the test network. Touches nothing else.
set -uo pipefail
containers=$(docker ps -a --format '{{.Names}}' | grep '^ccinnch-it-' || true)
[ -n "$containers" ] && docker rm -f $containers >/dev/null
docker network rm ccinnch-it-net >/dev/null 2>&1 || true
echo "removed: $(echo ${containers:-nothing})"
