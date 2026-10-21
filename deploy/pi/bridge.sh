#!/bin/sh
# bridge.sh up|down|restart|logs|status|build [camera]  — runs the compose once per cameras/*.env
set -eu
cd "$(dirname "$0")"
cmd="${1:-status}"; only="${2:-}"
cams() { for f in cameras/*.env; do n=$(basename "$f" .env); case "$n" in example-*) continue;; esac; [ -z "$only" ] || [ "$n" = "$only" ] || continue; echo "$n"; done; }
dc() { n="$1"; shift; COMPOSE_PROJECT_NAME="$n" ENV_FILE="cameras/$n.env" docker compose --env-file "cameras/$n.env" "$@"; }
for n in $(cams); do
  case "$cmd" in
    build)   dc "$n" build ;;
    up)      mkdir -p "/dev/shm/bridge-$n"; dc "$n" up -d --build ;;
    down)    dc "$n" down ;;
    restart) dc "$n" restart ;;
    logs)    dc "$n" logs -f --tail 100 proxy sidecar ;;
    status)  echo "== $n"; dc "$n" ps --format 'table {{.Name}}\t{{.Status}}' ;;
    *) echo "usage: $0 up|down|restart|logs|status|build [camera]"; exit 1 ;;
  esac
done
